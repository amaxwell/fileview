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
static malloc_zone_t     *_allocatorZone = NULL;

// array of buffers that are currently free (have been deallocated)
static CFMutableArrayRef  _freeBuffers = NULL;
static OSSpinLock         _freeBufferLock = OS_SPINLOCK_INIT;

// set of pointers to all blocks allocated in this zone with vm_allocate
static CFMutableSetRef    _vmAllocations = NULL;
static OSSpinLock         _vmAllocationLock = OS_SPINLOCK_INIT;

// small allocations (below 15K) use malloc_default_zone()
#define FV_VM_THRESHOLD 15360UL
// clean up the pool at 100 MB of freed memory
#define FV_REAP_THRESHOLD 104857600UL

#define USE_SYSTEM_ZONE 0

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
static CFIndex __FVAllocatorGetIndexOfAllocationGreaterThan(const CFIndex requestedSize)
{
    NSCParameterAssert(OSSpinLockTry(&_freeBufferLock) == false);
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    // need a temporary struct for comparison; only the ptrSize field is needed
    const fv_allocation_t alloc = { NULL, 0, NULL, requestedSize, NULL, _guard };

    CFIndex idx = CFArrayBSearchValues(_freeBuffers, range, &alloc, __FVAllocationSizeComparator, NULL);
    if (idx >= range.length) {
        idx = kCFNotFound;
    }
    else {
        const fv_allocation_t *foundAlloc = CFArrayGetValueAtIndex(_freeBuffers, idx);
        size_t foundSize = foundAlloc->allocSize;
        if ((float)(foundSize - requestedSize) / requestedSize > 1) {
            idx = kCFNotFound;
            // FVLog(@"requested %d, found %d; error = %.2f", requestedSize, foundSize, (float)(foundSize - requestedSize) / requestedSize);
        }
    }
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
static inline fv_allocation_t *__FVGetAllocationFromPointer(const void *ptr)
{
    fv_allocation_t *alloc = ((uintptr_t)ptr < sizeof(fv_allocation_t)) ? NULL : (void *)ptr - sizeof(fv_allocation_t);
    // simple check to ensure that this is one of our pointers
    if (NULL != alloc && __builtin_expect(alloc->guard != _guard, 0))
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
    // _allocatorZone indicates is should be freed with vm_deallocate
    if (alloc->zone == _allocatorZone) {
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
    if (KERN_SUCCESS != ret) memory = NULL;
    
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
        alloc->zone = _allocatorZone;
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
    
    return malloc_zone_malloc(_allocatorZone, allocSize);
}

static void __FVDeallocate(void *ptr, void *info)
{
    malloc_zone_free(_allocatorZone, ptr);
}

static void * __FVReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    // as per documentation for CFAllocatorContext
    if (__builtin_expect((NULL == ptr || newSize <= 0), 0))
        return NULL;
    
    return malloc_zone_realloc(_allocatorZone, ptr, newSize);
}

static CFIndex __FVPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    return _allocatorZone->introspect->good_size(_allocatorZone, size);
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
    void *newPtr;
    
    // okay to call realloc with a NULL pointer, but should not be the typical usage
    if (__builtin_expect(NULL != ptr, 1)) {    
        
        // bizarre, but documented behavior of realloc(3)
        if (__builtin_expect(0 == size, 0)) {
            __FVAllocatorZoneFree(zone, ptr);
            return __FVAllocatorZoneMalloc(zone, size);
        }
        
        fv_allocation_t *alloc = __FVGetAllocationFromPointer(ptr);
        // error on an invalid pointer
        if (__builtin_expect(NULL == alloc, 0)) {
            FVLog(@"FVAllocator: pointer <0x%p> passed to %s not malloced in this zone", ptr, __PRETTY_FUNCTION__);
            HALT;
            return NULL; /* not reached; keep clang happy */
        }
        
        kern_return_t ret = KERN_FAILURE;

        if (__FVAllocatorUseVMForSize(alloc->allocSize) && __FVAllocatorUseVMForSize(size)) {
            // pointer to the current end of this region
            vm_address_t addr = (vm_address_t)alloc->base + alloc->allocSize;
            // attempt to allocate at a specific address and extend the existing region
            ret = vm_allocate(mach_task_self(), &addr, round_page(size) - alloc->allocSize, VM_FLAGS_FIXED);
            // if this succeeds, increase sizes
            if (KERN_SUCCESS == ret) {
                alloc->allocSize += round_page(size);
                alloc->ptrSize += round_page(size);
            }
        }
        
        // if this wasn't a vm region or the region couldn't be extended, allocate a new block
        if (KERN_SUCCESS != ret) {
            newPtr = __FVAllocatorZoneMalloc(zone, size);
            memcpy(newPtr, ptr, alloc->ptrSize);
            __FVAllocatorZoneFree(zone, ptr);
        }
        
    }
    else {
        // original pointer was NULL, so just malloc a new block
        newPtr = __FVAllocatorZoneMalloc(zone, size);
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

#pragma mark Setup and cleanup

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
#if DEBUG && !defined(IMAGE_SHEAR)
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

__attribute__ ((constructor))
static void __initialize_allocator()
{  
    _allocatorZone = malloc_zone_malloc(malloc_default_zone(), sizeof(malloc_zone_t));
    _allocatorZone->size = __FVAllocatorZoneSize;
    _allocatorZone->malloc = __FVAllocatorZoneMalloc;
    _allocatorZone->calloc = __FVAllocatorZoneCalloc;
    _allocatorZone->valloc = __FVAllocatorZoneValloc;
    _allocatorZone->free = __FVAllocatorZoneFree;
    _allocatorZone->realloc = __FVAllocatorZoneRealloc;
    _allocatorZone->destroy = __FVAllocatorZoneDestroy;
    _allocatorZone->zone_name = "FVAllocatorZone";
    _allocatorZone->batch_malloc = NULL;
    _allocatorZone->batch_free = NULL;
    _allocatorZone->introspect = &__FVAllocatorZoneIntrospect;
    _allocatorZone->version = 0;
    
    // register so the system handles lookups correctly, or malloc_zone_from_ptr() breaks (along with free())
    malloc_zone_register(_allocatorZone);
    
    const CFArrayCallBacks acb = { 0, NULL, NULL, __FVAllocationCopyDescription, __FVAllocationEqual };
    _freeBuffers = CFArrayCreateMutable(NULL, 0, &acb);
    
    const CFSetCallBacks scb = { 0, NULL, NULL, __FVAllocationCopyDescription, __FVAllocationEqual, __FVAllocationHash };
    _vmAllocations = CFSetCreateMutable(NULL, 0, &scb);
    
    // round to the nearest FV_REAP_TIMEINTERVAL, so fire time is easier to predict by the clock
    CFAbsoluteTime fireTime = trunc((CFAbsoluteTimeGetCurrent() + FV_REAP_TIMEINTERVAL)/ FV_REAP_TIMEINTERVAL) * FV_REAP_TIMEINTERVAL;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, fireTime, FV_REAP_TIMEINTERVAL, 0, 0, __FVAllocatorReap, NULL);
    
    // add this to the main thread's runloop, which will always exist
#if (!USE_SYSTEM_ZONE)
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
#endif
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

#if DEBUG && !defined(IMAGE_SHEAR) && (!USE_SYSTEM_ZONE)
__attribute__ ((destructor))
static void __log_stats()
{
    // !!! artifically high since a bunch of stuff is freed right before this gets called
    FVAllocatorShowStats();
}
#endif

#pragma mark -

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

#pragma mark API

void FVAllocatorShowStats()
{
    // use the default zone explicitly; avoid callout to our custom zone(s)
    NSZone *zone = NSDefaultMallocZone();
    NSAutoreleasePool *pool = [[NSAutoreleasePool allocWithZone:zone] init];
    OSSpinLockLock(&_freeBufferLock);
    // record the actual time of this measurement
    CFAbsoluteTime snapshotTime = CFAbsoluteTimeGetCurrent();
    const fv_allocation_t *stackBuf[FV_STACK_MAX] = { NULL };
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    const fv_allocation_t **ptrs = range.length > FV_STACK_MAX ? NSZoneCalloc(zone, range.length, sizeof(fv_allocation_t *)) : stackBuf;
    CFArrayGetValues(_freeBuffers, range, (const void **)ptrs);
    size_t totalMemory = 0;
    NSCountedSet *duplicateAllocations = [[NSCountedSet allocWithZone:zone] init];
    NSNumber *value;
    for (CFIndex i = 0; i < range.length; i++) {
        if (__builtin_expect(_guard != ptrs[i]->guard, 0)) {
            FVLog(@"FVAllocator: invalid allocation pointer <0x%p> passed to %s", ptrs[i], __PRETTY_FUNCTION__);
            HALT;
        }
        totalMemory += ptrs[i]->allocSize;
        value = [[NSNumber allocWithZone:zone] initWithInt:ptrs[i]->allocSize];
        [duplicateAllocations addObject:value];
        [value release];
    }
    // held the lock to ensure that it's safe to dereference the allocations
    OSSpinLockUnlock(&_freeBufferLock);
    if (stackBuf != ptrs) NSZoneFree(zone, ptrs);
    NSEnumerator *dupeEnum = [duplicateAllocations objectEnumerator];
    NSMutableArray *sortedDuplicates = [[NSMutableArray allocWithZone:zone] init];
    const double totalMemoryMbytes = (double)totalMemory / 1024 / 1024;
    while (value = [dupeEnum nextObject]) {
        _FVAllocatorStat *stat = [[_FVAllocatorStat allocWithZone:zone] init];
        stat->_allocationSize = [value intValue];
        stat->_allocationCount = [duplicateAllocations countForObject:value];
        stat->_totalMbytes = (double)stat->_allocationSize * stat->_allocationCount / 1024 / 1024;
        stat->_percentOfTotal = (double)stat->_totalMbytes / totalMemoryMbytes * 100;
        [sortedDuplicates addObject:stat];
        [stat release];
    }
    NSSortDescriptor *sort = [[NSSortDescriptor allocWithZone:zone] initWithKey:@"self" ascending:YES selector:@selector(percentCompare:)];
    NSArray *sortDescriptors = [[NSArray allocWithZone:zone] initWithObjects:&sort count:1];
    [sortedDuplicates sortUsingDescriptors:sortDescriptors];
    [sortDescriptors release];
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
    // use a custom formatter to avoid displaying time zone
    CFAllocatorRef alloc = CFAllocatorGetDefault();
    CFDateRef date = CFDateCreate(alloc, snapshotTime);
    static CFDateFormatterRef formatter = NULL;
    if (NULL == formatter) {
        formatter = CFDateFormatterCreate(alloc, NULL, kCFDateFormatterShortStyle, kCFDateFormatterShortStyle);
        CFDateFormatterSetFormat(formatter, CFSTR("yyyy-MM-dd HH:mm:ss"));
    }
    CFStringRef dateDescription = CFDateFormatterCreateStringWithDate(alloc, formatter, date);
    if (NULL != date) CFRelease(date);
    FVLog(@"%@: %d hits and %d misses for a cache failure rate of %.2f%%", dateDescription, _cacheHits, _cacheMisses, missRate);
    FVLog(@"%@: total memory used: %.2f Mbytes, %d reallocations", dateDescription, (double)totalMemory / 1024 / 1024, _reallocCount);
    if (NULL != dateDescription) CFRelease(dateDescription);
    [pool release];
}

CFAllocatorRef FVAllocatorGetDefault() 
{ 
#if USE_SYSTEM_ZONE
    return CFAllocatorGetDefault();
#else
    return _allocator; 
#endif
}

NSZone *FVDefaultZone()
{
#if USE_SYSTEM_ZONE
    return NSDefaultMallocZone();
#else
    // NSZone is the same as malloc_zone_t: http://lists.apple.com/archives/objc-language/2008/Feb/msg00033.html
    return (NSZone *)_allocatorZone;
#endif
}
