//
//  FVAllocator.m
//  FileView
//
//  Created by Adam Maxwell on 08/01/08.
/*
 This software is Copyright (c) 2008
 Adam Maxwell. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:
 
 - Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 - Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in
 the documentation and/or other materials provided with the
 distribution.
 
 - Neither the name of Adam Maxwell nor the names of any
 contributors may be used to endorse or promote products derived
 from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "FVAllocator.h"
#import "FVObject.h"
#import "FVUtilities.h"

#import <libkern/OSAtomic.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <mach/vm_map.h>

typedef struct _fv_allocation_t {
    void       *base;      /* base of entire allocation     */
    size_t      allocSize; /* length of entire allocation   */
    void       *ptr;       /* writable region of allocation */
    size_t      ptrSize;   /* writable length of ptr        */
    const void *zone;      /* malloc_zone_t                 */
    const void *guard;     /* pointer to a check variable   */
} fv_allocation_t;

// used as guard field in allocation struct; do not rely on the value
static const char *_guard = "FVAllocatorGuard";

// single instance of this allocator
static CFAllocatorRef     _allocator = NULL;
static malloc_zone_t     *_allocator_zone = NULL;

// array of buffers that are currently free (have been deallocated)
static CFMutableArrayRef  _freeBuffers = NULL;
static OSSpinLock         _freeBufferLock = OS_SPINLOCK_INIT;

// set of pointers to all blocks allocated in this zone with vm_allocate
static CFMutableSetRef    _vmAllocations = NULL;
static OSSpinLock         _vmAllocationLock = OS_SPINLOCK_INIT;

// small allocations (below this size) will use malloc
#define FV_VM_THRESHOLD 16384UL
// clean up the pool at 100 MB of freed memory
#define FV_REAP_THRESHOLD 104857600UL

#if DEBUG
#define FV_REAP_TIMEINTERVAL 60
#else
#define FV_REAP_TIMEINTERVAL 300
#endif

static volatile uint32_t _cacheHits = 0;
static volatile uint32_t _cacheMisses = 0;
static volatile uint32_t _reallocCount = 0;

static CFComparisonResult __FVAllocationSizeComparator(const void *val1, const void *val2, void *context)
{
    const size_t size1 = ((fv_allocation_t *)val1)->ptrSize;
    const size_t size2 = ((fv_allocation_t *)val2)->ptrSize;
    if (size1 > size2)
        return kCFCompareGreaterThan;
    else if (size1 < size2)
        return kCFCompareLessThan;
    else
        return kCFCompareEqualTo;
}

static CFStringRef __FVAllocationCopyDescription(const void *value)
{
    const fv_allocation_t *alloc = value;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<0x%x>,\t size = %d"), alloc->ptr, alloc->ptrSize);
}

static Boolean __FVAllocationEqual(const void *val1, const void *val2)
{
    return (val1 == val2);
}

// !!! hash by size; need to check this to make sure it uses buckets effectively
static CFHashCode __FVAllocationHash(const void *value)
{
    const fv_allocation_t *alloc = value;
    return alloc->allocSize;
}

// returns kCFNotFound if no buffer of sufficient size exists
static CFIndex __FVAllocatorGetIndexOfAllocationGreaterThan(const CFIndex allocSize)
{
    NSCParameterAssert(OSSpinLockTry(&_freeBufferLock) == false);
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    // need a temporary struct for comparison; only the ptrSize field is needed
    const fv_allocation_t alloc = { NULL, 0, NULL, allocSize, NULL, _guard };
    
    // !!! This will potentially return a 256K buffer when a 48 byte buffer was requested, which will be pretty inefficient.  Should possibly just exclude anything < 16K from the cache, but we still shouldn't return 256K when 20K is required...need a heuristic for this?
#warning fixme
    CFIndex idx = CFArrayBSearchValues(_freeBuffers, range, &alloc, __FVAllocationSizeComparator, NULL);
    if (idx >= range.length)
        idx = kCFNotFound;
    return idx;
}

// always insert at the correct index, so we maintain heap order
static CFIndex __FVAllocatorGetInsertionIndexForAllocation(const fv_allocation_t *alloc)
{
    NSCParameterAssert(OSSpinLockTry(&_freeBufferLock) == false);
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    CFIndex anIndex = CFArrayBSearchValues(_freeBuffers, range, alloc, __FVAllocationSizeComparator, NULL);
    if (anIndex >= range.length)
        anIndex = range.length;
    return anIndex;
}

// fv_allocation_t struct always immediately precedes the data pointer
// returns NULL if the pointer was not allocated in this zone
static inline const fv_allocation_t *__FVGetAllocationFromPointer(const void *ptr)
{
    const fv_allocation_t *alloc = NULL == ptr ? NULL : ptr - sizeof(fv_allocation_t);
    // simple check to ensure that this is one of our pointers
    if (__builtin_expect(_guard != alloc->guard, 0))
        alloc = NULL;
    return alloc;
}

static inline bool __FVAllocatorUseVMForSize(size_t size) { return size >= FV_VM_THRESHOLD; }

// CFArrayApplierFunction; ptr argument must point to an fv_allocation_t
static void __FVAllocationFree(const void *ptr, void *unused)
{
    const fv_allocation_t *alloc = ptr;
    if (__builtin_expect(_guard != alloc->guard, 0)) {
        FVLog(@"FVAllocator: invalid allocation pointer <0x%p> passed to %s", ptr, __PRETTY_FUNCTION__);
        HALT;
    }
    // _allocator_zone indicates is should be freed with vm_deallocate
    if (alloc->zone == _allocator_zone) {
        NSCParameterAssert(__FVAllocatorUseVMForSize(alloc->allocSize));
        OSSpinLockLock(&_vmAllocationLock);
        NSCParameterAssert(CFSetContainsValue(_vmAllocations, alloc) == TRUE);
        CFSetRemoveValue(_vmAllocations, alloc);
        OSSpinLockUnlock(&_vmAllocationLock);
        vm_size_t len = alloc->allocSize;
        kern_return_t ret = vm_deallocate(mach_task_self(), (vm_address_t)alloc->base, len);
        if (0 != ret) FVLog(@"*** ERROR *** vm_deallocate failed at address 0x%p", alloc);        
    }
    else {
        malloc_zone_free((malloc_zone_t *)alloc->zone, alloc->base);
    }
}

/*
   Layout of memory allocated by __FVAllocateFromVMSystem().  The padding at the beginning is for page alignment.
 
                               |<-- page boundary
                               |<---------- ptrSize ---------->|
                               |<--ptr
   | padding | fv_allocation_t | data data data data data data |
             |<-- pointer returned by __FVAllocateFromSystem()
   |<--base                   
   |<------------------------ allocSize ---------------------->|
 
 */

static fv_allocation_t *__FVAllocationFromVMSystem(const size_t requestedSize)
{
    // base address of the allocation, including fv_allocation_t
    void *memory;
    fv_allocation_t *alloc = NULL;
    
    // allocate at least requestedSize + fv_allocation_t
    size_t actualSize = requestedSize + sizeof(fv_allocation_t) + vm_page_size;
    
    // !!! Improve this.  Testing indicates that there are lots of allocations in these ranges, so we end up with lots of one-off sizes that aren't very reusable.  Might be able to bin allocations below ~1 MB and use a hash table for lookups, then resort to the array/bsearch for larger values?
    if (actualSize < 102400) 
        actualSize = actualSize;
    else if (actualSize < 143360)
        actualSize = round_page(143360);
    else if (actualSize < 204800)
        actualSize = round_page(204800);
    else if (actualSize < 262144)
        actualSize = round_page(262144);
    else if (actualSize < 307200)
        actualSize = round_page(307200);
    else if (actualSize < 512000)
        actualSize = round_page(512000);
    else if (actualSize < 614400)
        actualSize = round_page(614400);

    // allocations going through this allocator should generally larger than 4K
    kern_return_t ret;
    ret = vm_allocate(mach_task_self(), (vm_address_t *)&memory, actualSize, VM_FLAGS_ANYWHERE);
    if (0 != ret) memory = NULL;
    
    // set up the data structure
    if (__builtin_expect(NULL != memory, 1)) {
        // align ptr to a page boundary
        void *ptr = (void *)round_page((uintptr_t)(memory + sizeof(fv_allocation_t)));
        // alloc struct immediately precedes ptr so we can find it again
        alloc = ptr - sizeof(fv_allocation_t);
        alloc->ptr = ptr;
        // ptrSize field is the size of ptr, not including the header or padding; used for array sorting
        alloc->ptrSize = memory + actualSize - alloc->ptr;
        // record the base address and size for deallocation purposes
        alloc->base = memory;
        alloc->allocSize = actualSize;
        alloc->zone = _allocator_zone;
        alloc->guard = _guard;
        NSCParameterAssert(alloc->ptrSize >= requestedSize);
        
        OSSpinLockLock(&_vmAllocationLock);
        NSCParameterAssert(CFSetContainsValue(_vmAllocations, alloc) == FALSE);
        CFSetAddValue(_vmAllocations, alloc);
        OSSpinLockUnlock(&_vmAllocationLock);
    }
    return alloc;
}

// memory is not page-aligned so there's no padding between the start of the allocated block and the returned fv_allocation_t pointer
static fv_allocation_t *__FVAllocationFromMalloc(const size_t requestedSize)
{
    // base address of the allocation, including fv_allocation_t
    void *memory;
    fv_allocation_t *alloc = NULL;
    
    // allocate at least requestedSize + fv_allocation_t
    const size_t actualSize = requestedSize + sizeof(fv_allocation_t);

    // use the default malloc zone, which is really fast for small allocations
    memory = malloc_zone_malloc(malloc_default_zone(), actualSize);
    
    // set up the data structure
    if (__builtin_expect(NULL != memory, 1)) {
        // alloc struct immediately precedes ptr so we can find it again
        alloc = memory;
        alloc->ptr = memory + sizeof(fv_allocation_t);
        // ptrSize field is the size of ptr, not including the header; used for array sorting
        alloc->ptrSize = requestedSize;
        // record the base address and size for deallocation purposes
        alloc->base = memory;
        alloc->allocSize = actualSize;
        alloc->guard = _guard;
        alloc->zone = malloc_default_zone();
        NSCParameterAssert(alloc->ptrSize >= requestedSize);
    }
    return alloc;
}

#pragma mark CFAllocatorContext functions

static CFStringRef __FVAllocatorCopyDescription(const void *info)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("FVAllocator <%p>"), _allocator);
}

// return an available buffer of sufficient size or create a new one
static void * __FVAllocate(CFIndex allocSize, CFOptionFlags hint, void *info)
{
    if (__builtin_expect(allocSize <= 0, 0))
        return NULL;
    
    return malloc_zone_malloc(_allocator_zone, allocSize);
}

static void __FVDeallocate(void *ptr, void *info)
{
    malloc_zone_free(_allocator_zone, ptr);
}

static void * __FVReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    // as per documentation for CFAllocatorContext
    if (__builtin_expect((NULL == ptr || newSize <= 0), 0))
        return NULL;
    
    return malloc_zone_realloc(_allocator_zone, ptr, newSize);
}

static CFIndex __FVPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    return _allocator_zone->introspect->good_size(_allocator_zone, size);
}

#pragma mark API and setup

#define FV_STACK_MAX 512

static size_t __FVTotalAllocationsLocked()
{
    NSCParameterAssert(OSSpinLockTry(&_freeBufferLock) == false);
    const fv_allocation_t *stackBuf[FV_STACK_MAX];
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    const fv_allocation_t **ptrs = range.length > FV_STACK_MAX ? malloc_zone_malloc(malloc_default_zone(), range.length) : stackBuf;
    CFArrayGetValues(_freeBuffers, range, (const void **)ptrs);
    size_t totalMemory = 0;
    for (CFIndex i = 0; i < range.length; i++)
        totalMemory += ptrs[i]->allocSize;
    
    if (stackBuf != ptrs) malloc_zone_free(malloc_default_zone(), ptrs);    
    return totalMemory;
}

static void __FVAllocatorReap(CFRunLoopTimerRef t, void *info)
{
#if DEBUG
    FVAllocatorShowStats();
#endif
    // if we can't lock immediately, wait for another opportunity
    if (OSSpinLockTry(&_freeBufferLock)) {
        if (__FVTotalAllocationsLocked() > FV_REAP_THRESHOLD) {
            CFArrayApplyFunction(_freeBuffers, CFRangeMake(0, CFArrayGetCount(_freeBuffers)), __FVAllocationFree, NULL);
            CFArrayRemoveAllValues(_freeBuffers);
        }
        OSSpinLockUnlock(&_freeBufferLock);
    }
}

#pragma mark Zone implementation

static size_t __FVAllocatorZoneSize(malloc_zone_t *zone, const void *ptr)
{
    const fv_allocation_t *alloc = __FVGetAllocationFromPointer(ptr);
    size_t size = 0;
    // Simple check to ensure that this is one of our pointers; which size to return, though?  Need to return size for values allocated in this zone with malloc, even though malloc_default_zone() is the underlying zone, or else they won't be freed.
    if (alloc && _guard == alloc->guard)
        size = alloc->ptrSize;
    return size;
}

static void *__FVAllocatorZoneMalloc(malloc_zone_t *zone, size_t size)
{
    // !!! unlock on each if branch
    OSSpinLockLock(&_freeBufferLock);
    CFIndex idx = __FVAllocatorGetIndexOfAllocationGreaterThan(size);
    const fv_allocation_t *alloc;
    
    // optimistically assume that the cache is effective; for our usage (lots of similarly-sized images), this is correct
    if (__builtin_expect(kCFNotFound == idx, 0)) {
        OSAtomicIncrement32((int32_t *)&_cacheMisses);
        // nothing found; unlock immediately and allocate a new chunk of memory
        OSSpinLockUnlock(&_freeBufferLock);
        alloc = __FVAllocatorUseVMForSize(size) ? __FVAllocationFromVMSystem(size) : __FVAllocationFromMalloc(size);
    }
    else {
        OSAtomicIncrement32((int32_t *)&_cacheHits);
        alloc = CFArrayGetValueAtIndex(_freeBuffers, idx);
        CFArrayRemoveValueAtIndex(_freeBuffers, idx);
        OSSpinLockUnlock(&_freeBufferLock);
        if (__builtin_expect(size > alloc->ptrSize, 0)) {
            FVLog(@"FVAllocator: incorrect size %lu (%d expected) in %s", alloc->ptrSize, size, __PRETTY_FUNCTION__);
            HALT;
        }
    }
    return alloc ? alloc->ptr : NULL;    
}

static void *__FVAllocatorZoneCalloc(malloc_zone_t *zone, size_t num_items, size_t size)
{
    void *memory = __FVAllocatorZoneMalloc(zone, num_items * size);
    memset(memory, 0, num_items * size);
    return memory;
}

// implementation for non-VM case was modified after the implementation in CFBase.c
static void *__FVAllocatorZoneValloc(malloc_zone_t *zone, size_t size)
{
    // this will already be page-aligned if we're using vm
    const bool useVM = __FVAllocatorUseVMForSize(size);
    if (false == useVM) size += vm_page_size;
    void *memory = __FVAllocatorZoneMalloc(zone, size);
    memset(memory, 0, size);
    // this should have no effect if we used vm to allocate
    void *ret = (void *)round_page((uintptr_t)memory);
    if (useVM) { NSCParameterAssert(memory == ret); }
    return ret;
}

static void __FVAllocatorZoneFree(malloc_zone_t *zone, void *ptr)
{
    // ignore NULL
    if (__builtin_expect(NULL != ptr, 1)) {    
        const fv_allocation_t *alloc = __FVGetAllocationFromPointer(ptr);
        // error on an invalid pointer
        if (__builtin_expect(NULL == alloc, 0)) {
            FVLog(@"FVAllocator: pointer <0x%p> passed to %s not malloced in this zone", ptr, __PRETTY_FUNCTION__);
            HALT;
        }
        // add to free list
        OSSpinLockLock(&_freeBufferLock);
        CFIndex idx = __FVAllocatorGetInsertionIndexForAllocation(alloc);
        CFArrayInsertValueAtIndex(_freeBuffers, idx, alloc);
        OSSpinLockUnlock(&_freeBufferLock);    
    }
}

static void *__FVAllocatorZoneRealloc(malloc_zone_t *zone, void *ptr, size_t size)
{
    OSAtomicIncrement32((int32_t *)&_reallocCount);
    
    // get a new buffer, copy contents, return original ptr to the pool
    void *newPtr = __FVAllocatorZoneMalloc(zone, size);
    if (__builtin_expect(NULL == newPtr, 0))
        return NULL;
    
    // okay to call realloc with a NULL pointer, but should not be the typical usage
    if (__builtin_expect(NULL != ptr, 1)) {    
        const fv_allocation_t *alloc = __FVGetAllocationFromPointer(ptr);
        // error on an invalid pointer
        if (__builtin_expect(NULL == alloc, 0)) {
            FVLog(@"FVAllocator: pointer <0x%p> passed to %s not malloced in this zone", ptr, __PRETTY_FUNCTION__);
            HALT;
        }
        memcpy(newPtr, ptr, alloc->ptrSize);
        __FVAllocatorZoneFree(zone, ptr);
    }
    return newPtr;
}

static void __FVAllocatorZoneDestroy(malloc_zone_t *zone)
{
    // remove all the free buffers
    OSSpinLockLock(&_freeBufferLock);
    CFArrayRemoveAllValues(_freeBuffers);
    OSSpinLockUnlock(&_freeBufferLock);    

    // now deallocate all buffers
    OSSpinLockLock(&_vmAllocationLock);
    CFSetApplyFunction(_vmAllocations, __FVAllocationFree, NULL);
    CFSetRemoveAllValues(_vmAllocations);
    OSSpinLockUnlock(&_vmAllocationLock);
    
    // free the zone itself
    malloc_zone_free(malloc_default_zone(), zone);
}

// All of the introspection stuff was copied from CFBase.c
static kern_return_t __FVAllocatorZoneIntrospectNoOp(void) {
    return 0;
}

static boolean_t __FVAllocatorZoneIntrospectTrue(void) {
    return 1;
}

static size_t __FVAllocatorZoneGoodSize(malloc_zone_t *zone, size_t size)
{
    return __FVAllocatorUseVMForSize(size) ? size + sizeof(fv_allocation_t) + vm_page_size : size + sizeof(fv_allocation_t);
}

static struct malloc_introspection_t __FVAllocatorZoneIntrospect = {
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorZoneGoodSize,
    (void *)__FVAllocatorZoneIntrospectTrue,
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorZoneIntrospectNoOp
};

__attribute__ ((constructor))
static void __initialize_allocator()
{  
    _allocator_zone = malloc_zone_malloc(malloc_default_zone(), sizeof(malloc_zone_t));
    _allocator_zone->size = __FVAllocatorZoneSize;
    _allocator_zone->malloc = __FVAllocatorZoneMalloc;
    _allocator_zone->calloc = __FVAllocatorZoneCalloc;
    _allocator_zone->valloc = __FVAllocatorZoneValloc;
    _allocator_zone->free = __FVAllocatorZoneFree;
    _allocator_zone->realloc = __FVAllocatorZoneRealloc;
    _allocator_zone->destroy = __FVAllocatorZoneDestroy;
    _allocator_zone->zone_name = "FVAllocatorZone";
    _allocator_zone->batch_malloc = NULL;
    _allocator_zone->batch_free = NULL;
    _allocator_zone->introspect = &__FVAllocatorZoneIntrospect;
    _allocator_zone->version = 0;
    
    // register so the system handles lookups correctly, or malloc_zone_from_ptr() breaks (along with free())
    malloc_zone_register(_allocator_zone);
    
    const CFArrayCallBacks acb = { 0, NULL, NULL, __FVAllocationCopyDescription, __FVAllocationEqual };
    _freeBuffers = CFArrayCreateMutable(NULL, 0, &acb);
    
    const CFSetCallBacks scb = { 0, NULL, NULL, __FVAllocationCopyDescription, __FVAllocationEqual, __FVAllocationHash };
    _vmAllocations = CFSetCreateMutable(NULL, 0, &scb);
    
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent()+FV_REAP_TIMEINTERVAL, FV_REAP_TIMEINTERVAL, 0, 0, __FVAllocatorReap, NULL);
    // add this to the main thread's runloop, which will always exist
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRelease(timer);
    
    CFAllocatorContext context = { 
        0, 
        NULL, 
        NULL, 
        NULL, 
        __FVAllocatorCopyDescription, 
        __FVAllocate, 
        __FVReallocate, 
        __FVDeallocate, 
        __FVPreferredSize 
    };
    _allocator = CFAllocatorCreate(CFAllocatorGetDefault(), &context);
}

CFAllocatorRef FVAllocatorGetDefault() 
{ 
    return _allocator; 
}

NSZone *FVDefaultZone()
{
    // NSZone is the same as malloc_zone_t: http://lists.apple.com/archives/objc-language/2008/Feb/msg00033.html
    return (NSZone *)_allocator_zone;
}

#pragma mark Statistics

@interface _FVAllocatorStat : FVObject
{
@public
    size_t _allocationSize;
    size_t _allocationCount;
    double _totalMbytes;
    double _percentOfTotal;
}
@end

@implementation _FVAllocatorStat

- (NSComparisonResult)allocationSizeCompare:(_FVAllocatorStat *)other
{
    if (other->_allocationSize > _allocationSize)
        return NSOrderedAscending;
    else if (other->_allocationSize < _allocationSize)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}

- (NSComparisonResult)totalMbyteCompare:(_FVAllocatorStat *)other
{
    if (other->_totalMbytes > _totalMbytes)
        return NSOrderedAscending;
    else if (other->_totalMbytes < _totalMbytes)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}

- (NSComparisonResult)percentCompare:(_FVAllocatorStat *)other
{
    if (other->_percentOfTotal > _percentOfTotal)
        return NSOrderedAscending;
    else if (other->_percentOfTotal < _percentOfTotal)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}

@end

void FVAllocatorShowStats()
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    OSSpinLockLock(&_freeBufferLock);
    const fv_allocation_t *stackBuf[FV_STACK_MAX];
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    const fv_allocation_t **ptrs = range.length > FV_STACK_MAX ? malloc_zone_malloc(malloc_default_zone(), range.length) : stackBuf;
    CFArrayGetValues(_freeBuffers, range, (const void **)ptrs);
    OSSpinLockUnlock(&_freeBufferLock);
    size_t totalMemory = 0;
    NSCountedSet *duplicateAllocations = [NSCountedSet new];
    for (CFIndex i = 0; i < range.length; i++) {
        totalMemory += ptrs[i]->allocSize;
        [duplicateAllocations addObject:[NSNumber numberWithInt:ptrs[i]->allocSize]];
    }
    if (stackBuf != ptrs) malloc_zone_free(malloc_default_zone(), ptrs);
    NSEnumerator *dupeEnum = [duplicateAllocations objectEnumerator];
    NSMutableArray *sortedDuplicates = [NSMutableArray new];
    NSNumber *value;
    const double totalMemoryMbytes = (double)totalMemory / 1024 / 1024;
    while (value = [dupeEnum nextObject]) {
        _FVAllocatorStat *stat = [_FVAllocatorStat new];
        stat->_allocationSize = [value intValue];
        stat->_allocationCount = [duplicateAllocations countForObject:value];
        stat->_totalMbytes = (double)stat->_allocationSize * stat->_allocationCount / 1024 / 1024;
        stat->_percentOfTotal = (double)stat->_totalMbytes / totalMemoryMbytes * 100;
        [sortedDuplicates addObject:stat];
        [stat release];
    }
    NSSortDescriptor *sort = [[NSSortDescriptor alloc] initWithKey:@"self" ascending:YES selector:@selector(percentCompare:)];
    [sortedDuplicates sortUsingDescriptors:[NSArray arrayWithObject:sort]];
    FVLog(@"------------------------------------");
    FVLog(@"   Size     Count  Total  Percentage");
    FVLog(@"   (b)       --    (Mb)      ----   ");
    for (NSUInteger i = 0; i < [sortedDuplicates count]; i++) {
        _FVAllocatorStat *stat = [sortedDuplicates objectAtIndex:i];
        FVLog(@"%8lu    %3lu   %5.2f    %5.2f %%", (long)stat->_allocationSize, (long)stat->_allocationCount, stat->_totalMbytes, stat->_percentOfTotal);
    }
    [duplicateAllocations release];
    [sortedDuplicates release];
    [sort release];
    // avoid divide-by-zero
    double cacheRequests = (_cacheHits + _cacheMisses);
    double missRate = cacheRequests > 0 ? (double)_cacheMisses / (_cacheHits + _cacheMisses) * 100 : 0;
    NSDate *date = [NSDate date];
    FVLog(@"%@: %d hits and %d misses for a cache failure rate of %.2f%%", date, _cacheHits, _cacheMisses, missRate);
    FVLog(@"%@: total memory used: %.2f Mbytes, %d reallocations", date, (double)totalMemory / 1024 / 1024, _reallocCount);      
    [pool release];
}

#if DEBUG
__attribute__ ((destructor))
static void __log_stats()
{
    // !!! artifically high since a bunch of stuff is freed right before this gets called
    FVAllocatorShowStats();
}
#endif
