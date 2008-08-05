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

typedef struct _fv_alloc_info_t {
    size_t      ptrSize;
    size_t      allocSize;
    void       *ptr;
    void       *base;
    const void *guard;
} fv_alloc_info_t;

static const char *_guard = "FVAllocatorGuard";

// single instance of this allocator
static CFAllocatorRef     _allocator = NULL;

// array of buffers that are currently free (have been deallocated)
static CFMutableArrayRef  _freeBuffers = NULL;
static OSSpinLock         _freeBufferLock = OS_SPINLOCK_INIT;

// small allocations (below this size) will use malloc
#define FV_VM_THRESHOLD 16384UL
// clean up the pool at 50 MB of freed memory
#define FV_REAP_THRESHOLD 52428800UL

#if DEBUG
#define FV_REAP_TIMEINTERVAL 60
#else
#define FV_REAP_TIMEINTERVAL 300
#endif

static volatile uint32_t _cacheHits = 0;
static volatile uint32_t _cacheMisses = 0;

static CFComparisonResult __FVAllocInfoComparator(const void *val1, const void *val2, void *context)
{
    const size_t size1 = ((fv_alloc_info_t *)val1)->ptrSize;
    const size_t size2 = ((fv_alloc_info_t *)val2)->ptrSize;
    if (size1 > size2)
        return kCFCompareGreaterThan;
    else if (size1 < size2)
        return kCFCompareLessThan;
    else
        return kCFCompareEqualTo;
}

static CFStringRef __FVAllocInfoCopyDescription(const void *value)
{
    const fv_alloc_info_t *info = value;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<0x%x>,\t size = %d"), info->ptr, info->ptrSize);
}

// returns kCFNotFound if no buffer of sufficient size exists
static CFIndex __FVAllocatorGetIndexOfAllocationGreaterThan(const CFIndex allocSize)
{
    NSCParameterAssert(OSSpinLockTry(&_freeBufferLock) == false);
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    // need a temporary struct for comparison
    const fv_alloc_info_t tempInfo = { allocSize, 0, NULL, NULL, NULL };
    CFIndex idx = CFArrayBSearchValues(_freeBuffers, range, &tempInfo, __FVAllocInfoComparator, NULL);
    if (idx >= range.length)
        idx = kCFNotFound;
    return idx;
}

// always insert at the correct index, so we maintain heap order
static CFIndex __FVAllocatorGetInsertionIndexForAllocation(const fv_alloc_info_t *allocInfo)
{
    NSCParameterAssert(OSSpinLockTry(&_freeBufferLock) == false);
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    CFIndex anIndex = CFArrayBSearchValues(_freeBuffers, range, allocInfo, __FVAllocInfoComparator, NULL);
    if (anIndex >= range.length)
        anIndex = range.length;
    return anIndex;
}

// alloc_info_t struct always immediately precedes the data pointer
static inline const fv_alloc_info_t *__FVGetAllocInfoFromPointer(const void *ptr)
{
    const fv_alloc_info_t *allocInfo = ptr - sizeof(fv_alloc_info_t);
    // simple check to ensure that this is one of our pointers
    if (__builtin_expect(_guard != allocInfo->guard, 0)) {
        FVLog(@"FVAllocator: invalid allocation pointer <0x%p> passed to %s", ptr, __PRETTY_FUNCTION__);
        HALT;
    }
    return allocInfo;
}

// CFArrayApplierFunction; ptr argument must point to an alloc_info_t
static void __FVDeallocateFromSystem(const void *ptr, void *unused)
{
    const fv_alloc_info_t *allocInfo = ptr;
    if (__builtin_expect(_guard != allocInfo->guard, 0)) {
        FVLog(@"FVAllocator: invalid allocation pointer <0x%p> passed to %s", ptr, __PRETTY_FUNCTION__);
        HALT;
    }
    if (allocInfo->allocSize != sizeof(fv_alloc_info_t) + allocInfo->ptrSize) {
        NSCParameterAssert(allocInfo->allocSize >= FV_VM_THRESHOLD);
        vm_size_t len = allocInfo->allocSize;
        kern_return_t ret = vm_deallocate(mach_task_self(), (vm_address_t)allocInfo->base, len);
        if (0 != ret) FVLog(@"*** ERROR *** vm_deallocate failed at address 0x%p", allocInfo);        
    }
    else {
        malloc_zone_free(malloc_zone_from_ptr(allocInfo->base), allocInfo->base);
    }
}

/*
   Layout of memory allocated by __FVAllocateFromVMSystem().  The padding at the beginning is for page alignment.
 
                               |<-- page boundary
                               |<---------- ptrSize ---------->|
                               |<--ptr
   | padding | fv_alloc_info_t | data data data data data data |
             |<-- pointer returned by __FVAllocateFromSystem()
   |<--base                   
   |<------------------------ allocSize ---------------------->|
 
 */

static fv_alloc_info_t *__FVAllocateFromVMSystem(const size_t requestedSize)
{
    // base address of the allocation, including fv_alloc_info_t
    void *memory;
    fv_alloc_info_t *allocInfo = NULL;
    
    // allocate at least requestedSize + fv_alloc_info_t
    const size_t actualSize = requestedSize + sizeof(fv_alloc_info_t) + vm_page_size;
    
    // allocations going through this allocator should generally larger than 4K
    kern_return_t ret;
    ret = vm_allocate(mach_task_self(), (vm_address_t *)&memory, actualSize, VM_FLAGS_ANYWHERE);
    if (0 != ret) memory = NULL;
    
    // set up the data structure
    if (__builtin_expect(NULL != memory, 1)) {
        // align ptr to a page boundary
        void *ptr = (void *)round_page((uintptr_t)(memory + sizeof(fv_alloc_info_t)));
        // allocInfo struct immediately precedes ptr so we can find it again
        allocInfo = ptr - sizeof(fv_alloc_info_t);
        allocInfo->ptr = ptr;
        // ptrSize field is the size of ptr, not including the header or padding; used for array sorting
        allocInfo->ptrSize = memory + actualSize - allocInfo->ptr;
        // record the base address and size for deallocation purposes
        allocInfo->base = memory;
        allocInfo->allocSize = actualSize;
        allocInfo->guard = _guard;
        NSCParameterAssert(allocInfo->ptrSize >= requestedSize);
    }
    return allocInfo;
}

// memory is not page-aligned so there's no padding between the start of the allocated block and the returned fv_alloc_info_t pointer
static fv_alloc_info_t *__FVAllocateFromMalloc(const size_t requestedSize)
{
    // base address of the allocation, including fv_alloc_info_t
    void *memory;
    fv_alloc_info_t *allocInfo = NULL;
    
    // allocate at least requestedSize + fv_alloc_info_t
    const size_t actualSize = requestedSize + sizeof(fv_alloc_info_t);
    
    // allocations going through this allocator should generally larger than 4K
    memory = malloc_zone_malloc(malloc_default_zone(), actualSize);
    
    // set up the data structure
    if (__builtin_expect(NULL != memory, 1)) {
        // allocInfo struct immediately precedes ptr so we can find it again
        allocInfo = memory;
        allocInfo->ptr = memory + sizeof(fv_alloc_info_t);
        // ptrSize field is the size of ptr, not including the header; used for array sorting
        allocInfo->ptrSize = requestedSize;
        // record the base address and size for deallocation purposes
        allocInfo->base = memory;
        allocInfo->allocSize = actualSize;
        allocInfo->guard = _guard;
        NSCParameterAssert(allocInfo->ptrSize >= requestedSize);
    }
    return allocInfo;
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
    
    // !!! unlock on each if branch
    OSSpinLockLock(&_freeBufferLock);
    CFIndex idx = __FVAllocatorGetIndexOfAllocationGreaterThan(allocSize);
    const fv_alloc_info_t *allocInfo;
    
    // optimistically assume that the cache is effective; for our usage (lots of similarly-sized images), this is correct
    if (__builtin_expect(kCFNotFound == idx, 0)) {
        OSAtomicIncrement32((int32_t *)&_cacheMisses);
        // nothing found; unlock immediately and allocate a new chunk of memory
        OSSpinLockUnlock(&_freeBufferLock);
        allocInfo = (size_t)allocSize >= FV_VM_THRESHOLD ? __FVAllocateFromVMSystem(allocSize) : __FVAllocateFromMalloc(allocSize);
    }
    else {
        OSAtomicIncrement32((int32_t *)&_cacheHits);
        allocInfo = CFArrayGetValueAtIndex(_freeBuffers, idx);
        CFArrayRemoveValueAtIndex(_freeBuffers, idx);
        OSSpinLockUnlock(&_freeBufferLock);
        if (__builtin_expect((size_t)allocSize > allocInfo->ptrSize, 0)) {
            FVLog(@"FVAllocator: incorrect size %lu (%d expected) in %s", allocInfo->ptrSize, allocSize, __PRETTY_FUNCTION__);
            HALT;
        }
    }
    return allocInfo ? allocInfo->ptr : NULL;
}

static void __FVDeallocate(void *ptr, void *info)
{
    const fv_alloc_info_t *allocInfo = __FVGetAllocInfoFromPointer(ptr);
    // add to free list
    OSSpinLockLock(&_freeBufferLock);
    CFIndex idx = __FVAllocatorGetInsertionIndexForAllocation(allocInfo);
    CFArrayInsertValueAtIndex(_freeBuffers, idx, allocInfo);
    OSSpinLockUnlock(&_freeBufferLock);
}

static void * __FVReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    // as per documentation for CFAllocatorContext
    if (__builtin_expect((NULL == ptr || newSize <= 0), 0))
        return NULL;
    
    // get a new buffer, copy contents, return original ptr to the pool
    void *newPtr = __FVAllocate(newSize, hint, info);
    if (__builtin_expect(NULL == newPtr, 0))
        return NULL;
    
    const fv_alloc_info_t *allocInfo = __FVGetAllocInfoFromPointer(ptr);
    memcpy(newPtr, ptr, allocInfo->ptrSize);
    __FVDeallocate(ptr, info);
    return newPtr;
}

static CFIndex __FVPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    size_t allocSize = size;
    return allocSize >= FV_VM_THRESHOLD ? allocSize + sizeof(fv_alloc_info_t) + vm_page_size : allocSize + sizeof(fv_alloc_info_t);
}

#pragma mark API and setup

#define FV_STACK_MAX 512

static size_t __FVTotalAllocationsLocked()
{
    NSCParameterAssert(OSSpinLockTry(&_freeBufferLock) == false);
    const fv_alloc_info_t *stackBuf[FV_STACK_MAX];
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    const fv_alloc_info_t **ptrs = range.length > FV_STACK_MAX ? malloc_zone_malloc(malloc_default_zone(), range.length) : stackBuf;
    CFArrayGetValues(_freeBuffers, range, (const void **)ptrs);
    size_t totalMemory = 0;
    for (CFIndex i = 0; i < range.length; i++)
        totalMemory += ptrs[i]->ptrSize;
    
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
            CFArrayApplyFunction(_freeBuffers, CFRangeMake(0, CFArrayGetCount(_freeBuffers)), __FVDeallocateFromSystem, NULL);
            CFArrayRemoveAllValues(_freeBuffers);
        }
        OSSpinLockUnlock(&_freeBufferLock);
    }
}

static malloc_zone_t *_allocator_zone = NULL;

static size_t __FVAllocatorZoneSize(malloc_zone_t *zone, const void *ptr)
{
    return 0;
}

static void *__FVAllocatorZoneMalloc(malloc_zone_t *zone, size_t size)
{
    return NULL;
    
}

static void *__FVAllocatorZoneCalloc(malloc_zone_t *zone, size_t num_items, size_t size)
{
    return NULL;
    
}

static void *__FVAllocatorZoneValloc(malloc_zone_t *zone, size_t size)
{
    return NULL;
    
}

static void __FVAllocatorZoneFree(malloc_zone_t *zone, void *ptr)
{
    
}

static void *__FVAllocatorZoneRealloc(malloc_zone_t *zone, void *ptr, size_t size)
{
    return NULL;
}

static void __FVAllocatorZoneDestroy(malloc_zone_t *zone)
{
    
}

static kern_return_t __FVAllocatorZoneIntrospectNoOp(void) {
    return 0;
}

static boolean_t __FVAllocatorZoneIntrospectTrue(void) {
    return 1;
}

static size_t __FVAllocatorCustomGoodSize(malloc_zone_t *zone, size_t size)
{
    return size;
}

static struct malloc_introspection_t __FVAllocatorZoneIntrospect = {
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorCustomGoodSize,
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
    
    const CFArrayCallBacks cb = { 0, NULL, NULL, __FVAllocInfoCopyDescription, NULL };
    _freeBuffers = CFArrayCreateMutable(NULL, 0, &cb);
    
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
    const fv_alloc_info_t *stackBuf[FV_STACK_MAX];
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    const fv_alloc_info_t **ptrs = range.length > FV_STACK_MAX ? malloc_zone_malloc(malloc_default_zone(), range.length) : stackBuf;
    CFArrayGetValues(_freeBuffers, range, (const void **)ptrs);
    OSSpinLockUnlock(&_freeBufferLock);
    size_t totalMemory = 0;
    NSCountedSet *duplicateAllocations = [NSCountedSet new];
    for (CFIndex i = 0; i < range.length; i++) {
        totalMemory += ptrs[i]->ptrSize;
        [duplicateAllocations addObject:[NSNumber numberWithInt:ptrs[i]->ptrSize]];
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
    FVLog(@"%@: %lu hits and %lu misses for a cache failure rate of %.2f%%", date, _cacheHits, _cacheMisses, missRate);
    FVLog(@"%@: total memory used: %.2f Mbytes", date, (double)totalMemory / 1024 / 1024);      
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
