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

typedef struct _fv_zone_t {
    malloc_zone_t     _basic_zone;
    CFMutableArrayRef _freeBuffers;
    OSSpinLock        _freeBufferLock;
    CFMutableSetRef   _allocations;
    OSSpinLock        _allocationLock;
    CFRunLoopTimerRef _timer;
} fv_zone_t;

typedef struct _fv_allocation_t {
    void            *base;      /* base of entire allocation     */
    size_t           allocSize; /* length of entire allocation   */
    void            *ptr;       /* writable region of allocation */
    size_t           ptrSize;   /* writable length of ptr        */
    const fv_zone_t *zone;      /* fv_zone_t                     */
    const void      *guard;     /* pointer to a check variable   */
} fv_allocation_t;

// used as guard field in allocation struct; do not rely on the value
static const char *_malloc_guard;  /* indicates underlying allocator is malloc_default_zone() */
static const char *_vm_guard;      /* indicates vm_allocate was used for this block           */

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
static CFIndex __FVAllocatorGetIndexOfAllocationGreaterThan(const CFIndex requestedSize, fv_zone_t *zone)
{
    NSCParameterAssert(OSSpinLockTry(&zone->_freeBufferLock) == false);
    CFRange range = CFRangeMake(0, CFArrayGetCount(zone->_freeBuffers));
    // need a temporary struct for comparison; only the ptrSize field is needed
    const fv_allocation_t alloc = { NULL, 0, NULL, requestedSize, NULL, NULL };

    CFIndex idx = CFArrayBSearchValues(zone->_freeBuffers, range, &alloc, __FVAllocationSizeComparator, NULL);
    if (idx >= range.length) {
        idx = kCFNotFound;
    }
    else {
        const fv_allocation_t *foundAlloc = CFArrayGetValueAtIndex(zone->_freeBuffers, idx);
        size_t foundSize = foundAlloc->ptrSize;
        if ((float)(foundSize - requestedSize) / requestedSize > 1) {
            idx = kCFNotFound;
            // FVLog(@"requested %d, found %d; error = %.2f", requestedSize, foundSize, (float)(foundSize - requestedSize) / requestedSize);
        }
    }
    return idx;
}

// always insert at the correct index, so we maintain heap order
static CFIndex __FVAllocatorGetInsertionIndexForAllocation(const fv_allocation_t *alloc, fv_zone_t *zone)
{
    NSCParameterAssert(OSSpinLockTry(&zone->_freeBufferLock) == false);
    if (alloc->zone != zone) {
        fv_zone_t *z = (fv_zone_t *)alloc->zone;
        malloc_printf("add to free list in wrong zone: %s should be %s\n", malloc_get_zone_name(&z->_basic_zone), malloc_get_zone_name(&zone->_basic_zone));
        HALT;
    }
    CFRange range = CFRangeMake(0, CFArrayGetCount(zone->_freeBuffers));
    CFIndex anIndex = CFArrayBSearchValues(zone->_freeBuffers, range, alloc, __FVAllocationSizeComparator, NULL);
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
    if (NULL != alloc && alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard)
        alloc = NULL;
    return alloc;
}

static inline bool __FVAllocatorUseVMForSize(size_t size) { return size >= FV_VM_THRESHOLD; }

/*
 CFSetApplierFunction; ptr argument must point to an fv_allocation_t allocated in this zone.  Caller is responsible for locking the collection and for mutating the _allocations set to keep it consistent.
 */
static inline void __FVAllocationDestroy(const void *ptr, void *unused)
{
    const fv_allocation_t *alloc = ptr;
    if (__builtin_expect((alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard), 0)) {
        malloc_printf("%s: invalid allocation pointer %p\n", __PRETTY_FUNCTION__, ptr);
        malloc_printf("Break on malloc_printf to debug.\n");
        HALT;
    }
    
    // _vm_guard indicates it should be freed with vm_deallocate
    if (__builtin_expect(&_vm_guard == alloc->guard, 1)) {
        NSCParameterAssert(__FVAllocatorUseVMForSize(alloc->allocSize));
        vm_size_t len = alloc->allocSize;
        kern_return_t ret = vm_deallocate(mach_task_self(), (vm_address_t)alloc->base, len);
        if (__builtin_expect(0 != ret, 0)) {
            malloc_printf("vm_deallocate failed to deallocate object %p", alloc);        
            malloc_printf("Break on malloc_printf to debug.\n");
        }
    }
    else {
        malloc_zone_free(malloc_default_zone(), alloc->base);
    }
}

/* 
 CFArrayApplierFunction; ptr argument must point to an fv_allocation_t allocated in this zone.  Caller is responsible for locking the collection.  
 
 !!! Warning: this mutates the _allocations set, so it cannot be used as a CFSetApplierFunction to free all allocations in that set.
 */
static void __FVAllocationFree(const void *ptr, void *context)
{
    fv_zone_t *zone = context;
    OSSpinLockLock(&zone->_allocationLock);
    NSCParameterAssert(CFSetContainsValue(zone->_allocations, ptr) == TRUE);
    CFSetRemoveValue(zone->_allocations, ptr);
    OSSpinLockUnlock(&zone->_allocationLock);
    
    __FVAllocationDestroy(ptr, NULL);
}

// does not include fv_allocation_t header size
static inline size_t __FVAllocatorRoundSize(const size_t requestedSize, bool *useVM)
{
    NSCParameterAssert(NULL != useVM);
    // allocate at least requestedSize
    size_t actualSize = requestedSize;
    *useVM = __FVAllocatorUseVMForSize(actualSize);
    if (true == *useVM) {
                
        if (actualSize < 102400) 
            actualSize = round_page(actualSize);
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
        else 
            actualSize = round_page(actualSize);
        
    }
    else if (actualSize < 128) {
        actualSize = 128;
    }
    if (__builtin_expect(requestedSize > actualSize, 0)) {
        malloc_printf("%s: invalid size %y after rounding %y to page boundary\n", __PRETTY_FUNCTION__, actualSize, requestedSize);
        malloc_printf("Break on malloc_printf to debug.\n");
        HALT;
    }
    return actualSize;
}

// Record the allocation for zone destruction.
static inline void __FVRecordAllocation(const fv_allocation_t *alloc, fv_zone_t *zone)
{
    OSSpinLockLock(&zone->_allocationLock);
    NSCParameterAssert(CFSetContainsValue(zone->_allocations, alloc) == FALSE);
    CFSetAddValue(zone->_allocations, alloc);
    OSSpinLockUnlock(&zone->_allocationLock);
}

/*
   Layout of memory allocated by __FVAllocateFromVMSystem().  The padding at the beginning is for page alignment.  Caller is responsible for passing the result of __FVAllocatorRoundSize() to this function.
 
                               |<-- page boundary
                               |<---------- ptrSize ---------->|
                               |<--ptr
   | padding | fv_allocation_t | data data data data data data |
             |<-- pointer returned by __FVAllocateFromSystem()
   |<--base                   
   |<------------------------ allocSize ---------------------->|
 
 */

static fv_allocation_t *__FVAllocationFromVMSystem(const size_t requestedSize, fv_zone_t *zone)
{
    // base address of the allocation, including fv_allocation_t
    void *memory;
    fv_allocation_t *alloc = NULL;
    
    // use this space for the header
    size_t actualSize = requestedSize + vm_page_size;
    NSCParameterAssert(round_page(actualSize) == actualSize);

    // allocations going through this allocator will always be larger than 4K
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
        alloc->zone = zone;
        alloc->guard = &_vm_guard;
        NSCParameterAssert(alloc->ptrSize >= requestedSize);
        __FVRecordAllocation(alloc, zone);
    }
    return alloc;
}

// memory is not page-aligned so there's no padding between the start of the allocated block and the returned fv_allocation_t pointer
static fv_allocation_t *__FVAllocationFromMalloc(const size_t requestedSize, fv_zone_t *zone)
{
    // base address of the allocation, including fv_allocation_t
    void *memory;
    fv_allocation_t *alloc = NULL;

    // use the default malloc zone, which is really fast for small allocations
    malloc_zone_t *underlyingZone = malloc_default_zone();
    size_t actualSize = requestedSize + sizeof(fv_allocation_t);
    memory = malloc_zone_malloc(underlyingZone, actualSize);
    
    // set up the data structure
    if (__builtin_expect(NULL != memory, 1)) {
        // alloc struct immediately precedes ptr so we can find it again
        alloc = memory;
        alloc->ptr = memory + sizeof(fv_allocation_t);
        // ptrSize field is the size of ptr, not including the header; used for array sorting
        alloc->ptrSize = memory + actualSize - alloc->ptr;
        NSCParameterAssert(alloc->ptrSize == actualSize - sizeof(fv_allocation_t));
        // record the base address and size for deallocation purposes
        alloc->base = memory;
        alloc->allocSize = actualSize;
        alloc->guard = &_malloc_guard;
        alloc->zone = zone;
        NSCParameterAssert(alloc->ptrSize >= requestedSize);
        __FVRecordAllocation(alloc, zone);
    }
    return alloc;
}

#pragma mark Zone implementation

static size_t __FVAllocatorZoneSize(fv_zone_t *zone, const void *ptr)
{
    const fv_allocation_t *alloc = __FVGetAllocationFromPointer(ptr);
    size_t size = 0;
    // Simple check to ensure that this is one of our pointers; which size to return, though?  Need to return size for values allocated in this zone with malloc, even though malloc_default_zone() is the underlying zone, or else they won't be freed.
    if (alloc && (alloc->guard == &_vm_guard || alloc->guard == &_malloc_guard))
        size = alloc->ptrSize;
    return size;
}

static void *__FVAllocatorZoneMalloc(fv_zone_t *zone, size_t size)
{
    const size_t origSize = size;
    bool useVM;
    // look for the possibly-rounded-up size, or the tolerance might cause us to create a new block
    size = __FVAllocatorRoundSize(size, &useVM);
    
    // !!! unlock on each if branch
    OSSpinLockLock(&zone->_freeBufferLock);
    CFIndex idx = __FVAllocatorGetIndexOfAllocationGreaterThan(size, zone);
    const fv_allocation_t *alloc;
    
    // optimistically assume that the cache is effective; for our usage (lots of similarly-sized images), this is correct
    if (__builtin_expect(kCFNotFound == idx, 0)) {
        OSAtomicIncrement32((int32_t *)&_cacheMisses);
        // nothing found; unlock immediately and allocate a new chunk of memory
        OSSpinLockUnlock(&zone->_freeBufferLock);
        alloc = useVM ? __FVAllocationFromVMSystem(size, zone) : __FVAllocationFromMalloc(size, zone);
    }
    else {
        OSAtomicIncrement32((int32_t *)&_cacheHits);
        alloc = CFArrayGetValueAtIndex(zone->_freeBuffers, idx);
        CFArrayRemoveValueAtIndex(zone->_freeBuffers, idx);
        OSSpinLockUnlock(&zone->_freeBufferLock);
        if (__builtin_expect(origSize > alloc->ptrSize, 0)) {
            malloc_printf("incorrect size %y (%y expected) in %s\n", alloc->ptrSize, origSize, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
    }
    return alloc ? alloc->ptr : NULL;    
}

static void *__FVAllocatorZoneCalloc(fv_zone_t *zone, size_t num_items, size_t size)
{
    void *memory = __FVAllocatorZoneMalloc(zone, num_items * size);
    memset(memory, 0, num_items * size);
    return memory;
}

// implementation for non-VM case was modified after the implementation in CFBase.c
static void *__FVAllocatorZoneValloc(fv_zone_t *zone, size_t size)
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

static void __FVAllocatorZoneFree(fv_zone_t *zone, void *ptr)
{
    // ignore NULL
    if (__builtin_expect(NULL != ptr, 1)) {    
        const fv_allocation_t *alloc = __FVGetAllocationFromPointer(ptr);
        // error on an invalid pointer
        if (__builtin_expect(NULL == alloc, 0)) {
            malloc_printf("%s: pointer %p not malloced in zone %s\n", __PRETTY_FUNCTION__, ptr, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
        // add to free list
        OSSpinLockLock(&zone->_freeBufferLock);
        // check to ensure that it's not already in the free list
        CFIndex idx = CFArrayGetFirstIndexOfValue(zone->_freeBuffers, CFRangeMake(0, CFArrayGetCount(zone->_freeBuffers)), alloc);
        if (__builtin_expect(kCFNotFound == idx, 1)) {
            idx = __FVAllocatorGetInsertionIndexForAllocation(alloc, zone);
            CFArrayInsertValueAtIndex(zone->_freeBuffers, idx, alloc);
        }
        else {
            malloc_printf("double free() of pointer %p\n in zone %s\n", ptr, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
        }
        OSSpinLockUnlock(&zone->_freeBufferLock);    
    }
}

static void *__FVAllocatorZoneRealloc(fv_zone_t *zone, void *ptr, size_t size)
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
            malloc_printf("%s: pointer %p not malloced in zone %s\n", __PRETTY_FUNCTION__, ptr, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
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

// this may not be perfectly (thread) safe, but the caller is responsible for whatever happens...
static void __FVAllocatorZoneDestroy(fv_zone_t *zone)
{
    CFRunLoopTimerRef t = zone->_timer;
    zone->_timer = NULL;
    OSMemoryBarrier();
    CFRunLoopTimerInvalidate(t);
    
    // remove all the free buffers
    OSSpinLockLock(&zone->_freeBufferLock);
    CFArrayRemoveAllValues(zone->_freeBuffers);
    OSSpinLockUnlock(&zone->_freeBufferLock);    

    // now deallocate all buffers allocated using this zone, regardless of underlying call
    OSSpinLockLock(&zone->_allocationLock);
    CFSetApplyFunction(zone->_allocations, __FVAllocationDestroy, NULL);
    CFSetRemoveAllValues(zone->_allocations);
    OSSpinLockUnlock(&zone->_allocationLock);
    
    // free the zone itself (must have been allocated with malloc!)
    malloc_zone_free(malloc_zone_from_ptr(zone), zone);
}

// All of the introspection stuff was copied from CFBase.c
static kern_return_t __FVAllocatorZoneIntrospectNoOp(void) {
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    return 0;
}

static boolean_t __FVAllocatorZoneIntrospectTrue(void) {
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    return 1;
}

static size_t __FVAllocatorZoneGoodSize(fv_zone_t *zone, size_t size)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    bool ignored;
    return __FVAllocatorRoundSize(size, &ignored);
}

static void __FVAllocatorSumAllocations(const void *value, void *context)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    size_t *size = context;
    const fv_allocation_t *alloc = value;
    *size += alloc->ptrSize;
}

static size_t __FVAllocatorTotalSize(fv_zone_t *zone)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    size_t sizeTotal;
    OSSpinLockLock(&zone->_allocationLock);
    CFSetApplyFunction(zone->_allocations, __FVAllocatorSumAllocations, &sizeTotal);
    OSSpinLockUnlock(&zone->_allocationLock);
    return sizeTotal;
}

static size_t __FVAllocatorGetSizeInUse(fv_zone_t *zone)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    size_t sizeTotal, sizeFree;
    OSSpinLockLock(&zone->_allocationLock);
    OSSpinLockLock(&zone->_freeBufferLock);
    CFSetApplyFunction(zone->_allocations, __FVAllocatorSumAllocations, &sizeTotal);
    CFArrayApplyFunction(zone->_freeBuffers, CFRangeMake(0, CFArrayGetCount(zone->_freeBuffers)), __FVAllocatorSumAllocations, &sizeFree);
    OSSpinLockUnlock(&zone->_allocationLock);
    OSSpinLockUnlock(&zone->_freeBufferLock);
    if (sizeTotal < sizeFree) {
        malloc_printf("inconsistent allocation record; free list exceeds allocation count\n");
        HALT;
    }
    return (sizeTotal - sizeFree);
}

static void __FVAllocatorZoneStatistics(fv_zone_t *zone, malloc_statistics_t *stats)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    stats->blocks_in_use = CFSetGetCount(zone->_allocations) - CFArrayGetCount(zone->_freeBuffers);
    stats->size_in_use = __FVAllocatorGetSizeInUse(zone);
    stats->max_size_in_use = __FVAllocatorTotalSize(zone);
    stats->size_allocated = stats->max_size_in_use;
}

static void __FVAllocatorForceLock(fv_zone_t *zone)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    OSSpinLockLock(&zone->_allocationLock);
    OSSpinLockLock(&zone->_freeBufferLock);
}

static void __FVAllocatorForceUnlock(fv_zone_t *zone)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    OSSpinLockUnlock(&zone->_freeBufferLock);
    OSSpinLockUnlock(&zone->_allocationLock);
}

#if 0

static kern_return_t __FVAllocatorZoneDefaultReader(task_t task, vm_address_t address, vm_size_t size, void **ptr)
{
    *ptr = __FVGetAllocationFromPointer((const void *)address);
    return 0;
}

/* enumerates all the malloc pointers in use */
static kern_return_t __FVAllocatorEnumerator(task_t task, void *context, unsigned type_mask, vm_address_t zone_address, memory_reader_t reader, vm_range_recorder_t recorder)
{
    szone_t		*szone;
    kern_return_t	err;
    
    if (!reader) reader = __FVAllocatorZoneDefaultReader;
    err = reader(task, zone_address, sizeof(szone_t), (void **)&szone);
    if (err) return err;

    huge_entry_t	*entries;
    
    /* given a task, "reads" the memory at the given address and size
     local_memory: set to a contiguous chunk of memory; validity of local_memory is assumed to be limited (until next call) */
    err = reader(task, huge_entries_address, sizeof(huge_entry_t) * num_entries, (void **)&entries);
    if (err)
        return err;
    
    /* given a task and context, "records" the specified addresses */
    if (num_entries)
        recorder(task, context, MALLOC_PTR_IN_USE_RANGE_TYPE | MALLOC_PTR_REGION_RANGE_TYPE, entries, num_entries);

    return err;
}

#define MAX_RECORDER_BUFFER	256
static kern_return_t __FVAllocatorEnumerator(task_t task, void *context, unsigned type_mask, vm_address_t zone_address, memory_reader_t reader, vm_range_recorder_t recorder)
{
    size_t num_regions = szone->num_small_regions_allocated;
    void *last_small_free = szone->last_small_free; 
    size_t	index;
    region_t	*regions;
    vm_range_t		buffer[MAX_RECORDER_BUFFER];
    unsigned		count = 0;
    kern_return_t	err;
    region_t	region;
    vm_range_t		range;
    vm_range_t		admin_range;
    vm_range_t		ptr_range;
    unsigned char	*mapped_region;
    msize_t		*block_header;
    unsigned		block_index;
    unsigned		block_limit;
    msize_t		msize_and_free;
    msize_t		msize;
    vm_address_t last_small_free_ptr = 0;
    msize_t last_small_free_msize = 0;
    
    if (last_small_free) {
        last_small_free_ptr = (uintptr_t)last_small_free & ~(SMALL_QUANTUM - 1);
        last_small_free_msize = (uintptr_t)last_small_free & (SMALL_QUANTUM - 1);
    }
    
    err = reader(task, (vm_address_t)szone->small_regions, sizeof(region_t) * num_regions, (void **)&regions);
    if (err) return err;
    for (index = 0; index < num_regions; ++index) {
        region = regions[index];
        if (region) {
            range.address = (vm_address_t)SMALL_REGION_ADDRESS(region);
            range.size = SMALL_REGION_SIZE;
            if (type_mask & MALLOC_ADMIN_REGION_RANGE_TYPE) {
                admin_range.address = range.address + SMALL_HEADER_START;
                admin_range.size = SMALL_ARRAY_SIZE;
                recorder(task, context, MALLOC_ADMIN_REGION_RANGE_TYPE, &admin_range, 1);
            }
            if (type_mask & (MALLOC_PTR_REGION_RANGE_TYPE | MALLOC_ADMIN_REGION_RANGE_TYPE)) {
                ptr_range.address = range.address;
                ptr_range.size = NUM_SMALL_BLOCKS * SMALL_QUANTUM;
                recorder(task, context, MALLOC_PTR_REGION_RANGE_TYPE, &ptr_range, 1);
            }
            if (type_mask & MALLOC_PTR_IN_USE_RANGE_TYPE) {
                err = reader(task, range.address, range.size, (void **)&mapped_region);
                if (err) return err;
                block_header = (msize_t *)(mapped_region + SMALL_HEADER_START);
                block_index = 0;
                block_limit = NUM_SMALL_BLOCKS;
                if (region == szone->last_small_region)
                    block_limit -= SMALL_MSIZE_FOR_BYTES(szone->small_bytes_free_at_end);
                while (block_index < block_limit) {
                    msize_and_free = block_header[block_index];
                    msize = msize_and_free & ~ SMALL_IS_FREE;
                    if (! (msize_and_free & SMALL_IS_FREE) &&
                        range.address + SMALL_BYTES_FOR_MSIZE(block_index) != last_small_free_ptr) {
                        // Block in use
                        buffer[count].address = range.address + SMALL_BYTES_FOR_MSIZE(block_index);
                        buffer[count].size = SMALL_BYTES_FOR_MSIZE(msize);
                        count++;
                        if (count >= MAX_RECORDER_BUFFER) {
                            recorder(task, context, MALLOC_PTR_IN_USE_RANGE_TYPE, buffer, count);
                            count = 0;
                        }
                    }
                    block_index += msize;
                }
            }
        }
    }
    if (count) {
        recorder(task, context, MALLOC_PTR_IN_USE_RANGE_TYPE, buffer, count);
    }
    return 0;
}
#endif

static const struct malloc_introspection_t __FVAllocatorZoneIntrospect = {
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorZoneGoodSize,
    (void *)__FVAllocatorZoneIntrospectTrue,
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorZoneIntrospectNoOp,
    (void *)__FVAllocatorForceLock,
    (void *)__FVAllocatorForceUnlock,
    (void *)__FVAllocatorZoneStatistics
};

#define FV_STACK_MAX 512

static size_t __FVTotalAllocationsLocked(fv_zone_t *zone)
{
    NSCParameterAssert(OSSpinLockTry(&zone->_freeBufferLock) == false);
    const fv_allocation_t *stackBuf[FV_STACK_MAX];
    CFRange range = CFRangeMake(0, CFArrayGetCount(zone->_freeBuffers));
    const fv_allocation_t **ptrs = range.length > FV_STACK_MAX ? malloc_zone_malloc(malloc_default_zone(), range.length) : stackBuf;
    CFArrayGetValues(zone->_freeBuffers, range, (const void **)ptrs);
    size_t totalMemory = 0;
    // FIXME: consistent size usage
    for (CFIndex i = 0; i < range.length; i++)
        totalMemory += ptrs[i]->allocSize;
    
    if (stackBuf != ptrs) malloc_zone_free(malloc_default_zone(), ptrs);    
    return totalMemory;
}

static void __FVAllocatorReap(CFRunLoopTimerRef t, void *info)
{
    fv_zone_t *zone = info;
#if 0 && DEBUG && !defined(IMAGE_SHEAR)
    FVAllocatorShowStats(zone);
#endif
    // if we can't lock immediately, wait for another opportunity
    if (OSSpinLockTry(&zone->_freeBufferLock)) {
        if (__FVTotalAllocationsLocked(zone) > FV_REAP_THRESHOLD) {
            CFArrayApplyFunction(zone->_freeBuffers, CFRangeMake(0, CFArrayGetCount(zone->_freeBuffers)), __FVAllocationFree, zone);
            CFArrayRemoveAllValues(zone->_freeBuffers);
        }
        OSSpinLockUnlock(&zone->_freeBufferLock);
    }
}

static malloc_zone_t *__FVCreateZone()
{
    fv_zone_t *zone = malloc_zone_malloc(malloc_default_zone(), sizeof(fv_zone_t));
    memset(zone, 0, sizeof(fv_zone_t));
    zone->_basic_zone.size = (void *)__FVAllocatorZoneSize;
    zone->_basic_zone.malloc = (void *)__FVAllocatorZoneMalloc;
    zone->_basic_zone.calloc = (void *)__FVAllocatorZoneCalloc;
    zone->_basic_zone.valloc = (void *)__FVAllocatorZoneValloc;
    zone->_basic_zone.free = (void *)__FVAllocatorZoneFree;
    zone->_basic_zone.realloc = (void *)__FVAllocatorZoneRealloc;
    zone->_basic_zone.destroy = (void *)__FVAllocatorZoneDestroy;
    zone->_basic_zone.zone_name = NULL;
    zone->_basic_zone.batch_malloc = NULL;
    zone->_basic_zone.batch_free = NULL;
    zone->_basic_zone.introspect = (struct malloc_introspection_t *)&__FVAllocatorZoneIntrospect;
    zone->_basic_zone.version = 3;  /* from scalable_malloc.c in Libc-498.1.1 */
    
    // malloc_set_zone_name calls out to this zone, so we need the array/set to exist
    const CFArrayCallBacks acb = { 0, NULL, NULL, __FVAllocationCopyDescription, __FVAllocationEqual };
    zone->_freeBuffers = CFArrayCreateMutable(NULL, 0, &acb);
    
    const CFSetCallBacks scb = { 0, NULL, NULL, __FVAllocationCopyDescription, __FVAllocationEqual, __FVAllocationHash };
    zone->_allocations = CFSetCreateMutable(NULL, 0, &scb);    
    
    // register so the system handles lookups correctly, or malloc_zone_from_ptr() breaks (along with free())
    malloc_zone_register((malloc_zone_t *)zone);
    
    // create timer after zone is fully set up
    
    // round to the nearest FV_REAP_TIMEINTERVAL, so fire time is easier to predict by the clock
    CFAbsoluteTime fireTime = trunc((CFAbsoluteTimeGetCurrent() + FV_REAP_TIMEINTERVAL) / FV_REAP_TIMEINTERVAL) * FV_REAP_TIMEINTERVAL;
    fireTime += FV_REAP_TIMEINTERVAL;
    CFRunLoopTimerContext ctxt = { 0, zone, NULL, NULL, NULL };
    zone->_timer = CFRunLoopTimerCreate(NULL, fireTime, FV_REAP_TIMEINTERVAL, 0, 0, __FVAllocatorReap, &ctxt);
    // add this to the main thread's runloop, which will always exist
    CFRunLoopAddTimer(CFRunLoopGetMain(), zone->_timer, kCFRunLoopCommonModes);
    CFRelease(zone->_timer);
    
    return (malloc_zone_t *)zone;
}

#pragma mark CFAllocatorContext functions

static CFStringRef __FVAllocatorCopyDescription(const void *info)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("FVAllocator <%p>"), info);
}

// return an available buffer of sufficient size or create a new one
static void * __FVAllocate(CFIndex allocSize, CFOptionFlags hint, void *info)
{
    if (__builtin_expect(allocSize <= 0, 0))
        return NULL;
    
    return malloc_zone_malloc(info, allocSize);
}

static void __FVDeallocate(void *ptr, void *info)
{
    malloc_zone_free(info, ptr);
}

static void * __FVReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    // as per documentation for CFAllocatorContext
    if (__builtin_expect((NULL == ptr || newSize <= 0), 0))
        return NULL;
    
    return malloc_zone_realloc(info, ptr, newSize);
}

static CFIndex __FVPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    malloc_zone_t *zone = info;
    return zone->introspect->good_size(zone, size);
}

#pragma mark Setup and cleanup

// single instance of this allocator
static CFAllocatorRef  _allocator = NULL;
static malloc_zone_t  *_allocatorZone = NULL;

__attribute__ ((constructor))
static void __initialize_allocator()
{    
    
    _allocatorZone = __FVCreateZone();
    malloc_set_zone_name(_allocatorZone, "FVAllocatorZone");
    
    CFAllocatorContext context = { 
        0, 
        _allocatorZone, 
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
    FVAllocatorShowStats((NSZone *)_allocatorZone);
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

void FVAllocatorShowStats(NSZone *z)
{
    fv_zone_t *fvzone = (fv_zone_t *)z;
    // use the default zone explicitly; avoid callout to our custom zone(s)
    NSZone *zone = NSDefaultMallocZone();
    NSAutoreleasePool *pool = [[NSAutoreleasePool allocWithZone:zone] init];
    OSSpinLockLock(&fvzone->_freeBufferLock);
    // record the actual time of this measurement
    CFAbsoluteTime snapshotTime = CFAbsoluteTimeGetCurrent();
    const fv_allocation_t *stackBuf[FV_STACK_MAX] = { NULL };
    CFRange range = CFRangeMake(0, CFArrayGetCount(fvzone->_freeBuffers));
    const fv_allocation_t **ptrs = range.length > FV_STACK_MAX ? NSZoneCalloc(zone, range.length, sizeof(fv_allocation_t *)) : stackBuf;
    CFArrayGetValues(fvzone->_freeBuffers, range, (const void **)ptrs);
    size_t totalMemory = 0;
    NSCountedSet *duplicateAllocations = [[NSCountedSet allocWithZone:zone] init];
    NSNumber *value;
    for (CFIndex i = 0; i < range.length; i++) {
        if (__builtin_expect((ptrs[i]->guard != &_vm_guard && ptrs[i]->guard != &_malloc_guard), 0)) {
            malloc_printf("%s: invalid allocation pointer %p\n", __PRETTY_FUNCTION__, ptrs[i]);
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
        // FIXME: consistent size usage
        totalMemory += ptrs[i]->allocSize;
        value = [[NSNumber allocWithZone:zone] initWithInt:ptrs[i]->ptrSize];
        [duplicateAllocations addObject:value];
        [value release];
    }
    // held the lock to ensure that it's safe to dereference the allocations
    OSSpinLockUnlock(&fvzone->_freeBufferLock);
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
