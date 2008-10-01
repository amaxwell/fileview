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
    OSSpinLock        _spinLock;
    CFMutableSetRef   _allocations;
    CFRunLoopTimerRef _timer;
    volatile uint32_t _cacheHits;
    volatile uint32_t _cacheMisses;
    volatile uint32_t _reallocCount;
} fv_zone_t;

typedef struct _fv_allocation_t {
    void            *base;      /* base of entire allocation     */
    size_t           allocSize; /* length of entire allocation   */
    void            *ptr;       /* writable region of allocation */
    size_t           ptrSize;   /* writable length of ptr        */
    const fv_zone_t *zone;      /* fv_zone_t                     */
    bool             free;      /* in use or in the free list    */
    const void      *guard;     /* pointer to a check variable   */
} fv_allocation_t;

#if DEBUG && !defined(IMAGE_SHEAR)
static void __FVAllocatorShowStats(fv_zone_t *fvzone);
#endif

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
    return CFStringCreateWithFormat(NULL, NULL, FVSTR("<0x%x>,\t size = %lu"), alloc->ptr, (unsigned long)alloc->ptrSize);
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
    NSCParameterAssert(OSSpinLockTry(&zone->_spinLock) == false);
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
    NSCParameterAssert(OSSpinLockTry(&zone->_spinLock) == false);
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
    NSCParameterAssert(CFSetContainsValue(zone->_allocations, ptr) == TRUE);
    NSCParameterAssert(OSSpinLockTry(&zone->_spinLock) == false);
    CFSetRemoveValue(zone->_allocations, ptr);
    
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
    OSSpinLockLock(&zone->_spinLock);
    NSCParameterAssert(CFSetContainsValue(zone->_allocations, alloc) == FALSE);
    CFSetAddValue(zone->_allocations, alloc);
    OSSpinLockUnlock(&zone->_spinLock);
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
    vm_address_t memory;
    fv_allocation_t *alloc = NULL;
    
    // use this space for the header
    size_t actualSize = requestedSize + vm_page_size;
    NSCParameterAssert(round_page(actualSize) == actualSize);

    // allocations going through this allocator will always be larger than 4K
    kern_return_t ret;
    ret = vm_allocate(mach_task_self(), &memory, actualSize, VM_FLAGS_ANYWHERE);
    if (KERN_SUCCESS != ret) memory = 0;
    
    // set up the data structure
    if (__builtin_expect(0 != memory, 1)) {
        // align ptr to a page boundary
        void *ptr = (void *)round_page((uintptr_t)(memory + sizeof(fv_allocation_t)));
        // alloc struct immediately precedes ptr so we can find it again
        alloc = ptr - sizeof(fv_allocation_t);
        alloc->ptr = ptr;
        // ptrSize field is the size of ptr, not including the header or padding; used for array sorting
        alloc->ptrSize = (void *)memory + actualSize - alloc->ptr;
        // record the base address and size for deallocation purposes
        alloc->base = (void *)memory;
        alloc->allocSize = actualSize;
        alloc->zone = zone;
        alloc->free = true;
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
        alloc->zone = zone;
        alloc->free = true;
        alloc->guard = &_malloc_guard;
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
    OSSpinLockLock(&zone->_spinLock);
    CFIndex idx = __FVAllocatorGetIndexOfAllocationGreaterThan(size, zone);
    fv_allocation_t *alloc;
    void *ret = NULL;
    
    // optimistically assume that the cache is effective; for our usage (lots of similarly-sized images), this is correct
    if (__builtin_expect(kCFNotFound == idx, 0)) {
        OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_cacheMisses);
        // nothing found; unlock immediately and allocate a new chunk of memory
        OSSpinLockUnlock(&zone->_spinLock);
        alloc = useVM ? __FVAllocationFromVMSystem(size, zone) : __FVAllocationFromMalloc(size, zone);
    }
    else {
        OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_cacheHits);
        alloc = (void *)CFArrayGetValueAtIndex(zone->_freeBuffers, idx);
        CFArrayRemoveValueAtIndex(zone->_freeBuffers, idx);
        OSSpinLockUnlock(&zone->_spinLock);
        if (__builtin_expect(origSize > alloc->ptrSize, 0)) {
            malloc_printf("incorrect size %y (%y expected) in %s\n", alloc->ptrSize, origSize, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
    }
    if (__builtin_expect(NULL != alloc, 1)) {
        alloc->free = false;
        ret = alloc->ptr;
    }
    return ret;    
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
        fv_allocation_t *alloc = __FVGetAllocationFromPointer(ptr);
        // error on an invalid pointer
        if (__builtin_expect(NULL == alloc, 0)) {
            malloc_printf("%s: pointer %p not malloced in zone %s\n", __PRETTY_FUNCTION__, ptr, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
        // add to free list
        OSSpinLockLock(&zone->_spinLock);
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
        alloc->free = true;
        OSSpinLockUnlock(&zone->_spinLock);    
    }
}

static void *__FVAllocatorZoneRealloc(fv_zone_t *zone, void *ptr, size_t size)
{
    OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_reallocCount);
        
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

        // See if it's already large enough, due to padding, or the caller requesting a smaller block (so we never resize downwards).
        if (alloc->ptrSize >= size) {
            newPtr = ptr;
        }
        else if (alloc->guard == &_vm_guard) {
            // pointer to the current end of this region
            vm_address_t addr = (vm_address_t)alloc->base + alloc->allocSize;
            // attempt to allocate at a specific address and extend the existing region
            ret = vm_allocate(mach_task_self(), &addr, round_page(size) - alloc->allocSize, VM_FLAGS_FIXED);
            // if this succeeds, increase sizes and assign newPtr to the original parameter
            if (KERN_SUCCESS == ret) {
                alloc->allocSize += round_page(size);
                alloc->ptrSize += round_page(size);
                newPtr = ptr;
            }
        }
        
        // if this wasn't a vm region or the vm region couldn't be extended, allocate a new block
        if (KERN_SUCCESS != ret) {
            // get a new buffer, copy contents, return original ptr to the pool; should try to use vm_copy here
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
    OSSpinLockLock(&zone->_spinLock);
    CFArrayRemoveAllValues(zone->_freeBuffers);

    // now deallocate all buffers allocated using this zone, regardless of underlying call
    CFSetApplyFunction(zone->_allocations, __FVAllocationDestroy, NULL);
    CFSetRemoveAllValues(zone->_allocations);
    OSSpinLockUnlock(&zone->_spinLock);
    
    // free the zone itself (must have been allocated with malloc!)
    malloc_zone_free(malloc_zone_from_ptr(zone), zone);
}

static void __FVAllocatorZonePrint(malloc_zone_t *zone, boolean_t verbose) {
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
}

static void __FVAllocatorZoneLog(malloc_zone_t *zone, void *address) {
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
}

static boolean_t __FVAllocatorZoneIntrospectTrue(malloc_zone_t *zone) {
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    return 1;
}

static size_t __FVAllocatorZoneGoodSize(malloc_zone_t *zone, size_t size)
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
    OSSpinLockLock(&zone->_spinLock);
    CFSetApplyFunction(zone->_allocations, __FVAllocatorSumAllocations, &sizeTotal);
    OSSpinLockUnlock(&zone->_spinLock);
    return sizeTotal;
}

static size_t __FVAllocatorGetSizeInUse(fv_zone_t *zone)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    size_t sizeTotal, sizeFree;
    OSSpinLockLock(&zone->_spinLock);
    CFSetApplyFunction(zone->_allocations, __FVAllocatorSumAllocations, &sizeTotal);
    CFArrayApplyFunction(zone->_freeBuffers, CFRangeMake(0, CFArrayGetCount(zone->_freeBuffers)), __FVAllocatorSumAllocations, &sizeFree);
    OSSpinLockUnlock(&zone->_spinLock);
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

// called when preparing for a fork() (see _malloc_fork_prepare() in malloc.c)
static void __FVAllocatorForceLock(fv_zone_t *zone)
{
    OSSpinLockLock(&zone->_spinLock);
}

// called in parent and child after fork() (see _malloc_fork_parent() and _malloc_fork_child() in malloc.c)
static void __FVAllocatorForceUnlock(fv_zone_t *zone)
{
    OSSpinLockUnlock(&zone->_spinLock);
}

typedef struct _applier_context {
    task_t              task;
    void               *context;
    unsigned            type_mask;
    fv_zone_t          *zone;
    kern_return_t     (*reader)(task_t, vm_address_t, vm_size_t, void **);
    void              (*recorder)(task_t, void *, unsigned type, vm_range_t *, unsigned);
    kern_return_t      *ret;
} applier_context;

static void __enumerator_applier(const void *value, void *context)
{
    applier_context *ctxt = context;
    const fv_allocation_t *alloc = value;
    
    // Is this needed?  Should I use local_memory instead of the alloc pointer?
    void *local_memory;
    kern_return_t err = ctxt->reader(ctxt->task, (vm_address_t)alloc, alloc->allocSize, (void **)&local_memory);
    if (err) {
        *ctxt->ret = err;
        return;
    }
    
    vm_range_t range;
    if (ctxt->type_mask & MALLOC_ADMIN_REGION_RANGE_TYPE) {
        range.address = (vm_address_t)alloc->base;
        range.size = alloc->allocSize - alloc->ptrSize;
        ctxt->recorder(ctxt->task, ctxt->context, MALLOC_ADMIN_REGION_RANGE_TYPE, &range, 1);
    }
    if (ctxt->type_mask & (MALLOC_PTR_REGION_RANGE_TYPE | MALLOC_ADMIN_REGION_RANGE_TYPE)) {
        range.address = (vm_address_t)alloc->base;
        range.size = alloc->allocSize;
        ctxt->recorder(ctxt->task, ctxt->context, MALLOC_PTR_REGION_RANGE_TYPE, &range, 1);
    }
    if (ctxt->type_mask & MALLOC_PTR_IN_USE_RANGE_TYPE && false == alloc->free) {
        range.address = (vm_address_t)alloc->ptr;
        range.size = alloc->ptrSize;
        ctxt->recorder(ctxt->task, ctxt->context, MALLOC_PTR_IN_USE_RANGE_TYPE, &range, 1);
    }
}

static kern_return_t 
__FVAllocatorEnumerator(task_t task, void *context, unsigned type_mask, vm_address_t zone_address, memory_reader_t reader, vm_range_recorder_t recorder)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    fv_zone_t *zone = (void *)zone_address;
    OSSpinLockLock(&zone->_spinLock);
    kern_return_t ret = 0;
    applier_context ctxt = { task, context, type_mask, zone, reader, recorder, &ret };
    CFSetApplyFunction(zone->_allocations, __enumerator_applier, &ctxt);
    OSSpinLockUnlock(&zone->_spinLock);
    return ret;
}

static const struct malloc_introspection_t __FVAllocatorZoneIntrospect = {
    __FVAllocatorEnumerator,
    __FVAllocatorZoneGoodSize,
    __FVAllocatorZoneIntrospectTrue,
    __FVAllocatorZonePrint,
    __FVAllocatorZoneLog,
    (void *)__FVAllocatorForceLock,
    (void *)__FVAllocatorForceUnlock,
    (void *)__FVAllocatorZoneStatistics
};

#define FV_STACK_MAX 512

static size_t __FVTotalAllocationsLocked(fv_zone_t *zone)
{
    NSCParameterAssert(OSSpinLockTry(&zone->_spinLock) == false);
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

#if 0
static kern_return_t
_szone_default_reader(task_t task, vm_address_t address, vm_size_t size, void **ptr)
{
    *ptr = (void *)address;
    return 0;
}
#endif

static void __FVAllocatorReap(CFRunLoopTimerRef t, void *info)
{
#if 0
    kern_return_t ret;
    vm_address_t *x;
    unsigned cnt;
    ret = malloc_get_all_zones(mach_task_self(), _szone_default_reader, &x, &cnt);
    if (ret) cnt = 0;
    for(unsigned i = 0; i < cnt; i++) {
        malloc_zone_t *z = (void *)x[i];
        fprintf(stderr, "zone %d name is %s\n", i, malloc_get_zone_name(z));
    }
    if (!cnt) fprintf(stderr, "unable to read zones\n");
#endif

    fv_zone_t *zone = info;
#if DEBUG && !defined(IMAGE_SHEAR)
    __FVAllocatorShowStats(zone);
#endif
    // if we can't lock immediately, wait for another opportunity
    if (OSSpinLockTry(&zone->_spinLock)) {
        if (__FVTotalAllocationsLocked(zone) > FV_REAP_THRESHOLD) {
            CFArrayApplyFunction(zone->_freeBuffers, CFRangeMake(0, CFArrayGetCount(zone->_freeBuffers)), __FVAllocationFree, zone);
            CFArrayRemoveAllValues(zone->_freeBuffers);
        }
        OSSpinLockUnlock(&zone->_spinLock);
    }
}

// could be exposed as API in future, since it's declared as malloc_zone_t
static malloc_zone_t *__FVCreateZoneWithName(const char *name)
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
    zone->_basic_zone.zone_name = strdup(name); /* assumes we have the default malloc zone */
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
    return CFStringCreateWithFormat(NULL, NULL, FVSTR("FVAllocator <%p>"), info);
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
    
    _allocatorZone = __FVCreateZoneWithName("FVAllocatorZone");
    
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

#if 0 && DEBUG && !defined(IMAGE_SHEAR) && (!USE_SYSTEM_ZONE)
__attribute__ ((destructor))
static void __log_stats()
{
    // !!! artifically high since a bunch of stuff is freed right before this gets called
    __FVAllocatorShowStats((fv_zone_t *)_allocatorZone);
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

#if DEBUG && !defined(IMAGE_SHEAR)

// can't make this public, since it relies on the argument being an fv_zone_t (which must not be exposed)
static void __FVAllocatorShowStats(fv_zone_t *fvzone)
{
    // use the default zone explicitly; avoid callout to our custom zone(s)
    NSZone *zone = NSDefaultMallocZone();
    NSAutoreleasePool *pool = [[NSAutoreleasePool allocWithZone:zone] init];
    OSSpinLockLock(&fvzone->_spinLock);
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
    OSSpinLockUnlock(&fvzone->_spinLock);
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
    FVLog(@"Zone name: %s", malloc_get_zone_name((malloc_zone_t *)fvzone));
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
    double cacheRequests = (fvzone->_cacheHits + fvzone->_cacheMisses);
    double missRate = cacheRequests > 0 ? (double)fvzone->_cacheMisses / (fvzone->_cacheHits + fvzone->_cacheMisses) * 100 : 0;
    // use a custom formatter to avoid displaying time zone
    CFAllocatorRef alloc = CFAllocatorGetDefault();
    CFDateRef date = CFDateCreate(alloc, snapshotTime);
    static CFDateFormatterRef formatter = NULL;
    if (NULL == formatter) {
        formatter = CFDateFormatterCreate(alloc, NULL, kCFDateFormatterShortStyle, kCFDateFormatterShortStyle);
        CFDateFormatterSetFormat(formatter, FVSTR("yyyy-MM-dd HH:mm:ss"));
    }
    CFStringRef dateDescription = CFDateFormatterCreateStringWithDate(alloc, formatter, date);
    if (NULL != date) CFRelease(date);
    FVLog(@"%@: %d hits and %d misses for a cache failure rate of %.2f%%", dateDescription, fvzone->_cacheHits, fvzone->_cacheMisses, missRate);
    FVLog(@"%@: total memory used: %.2f Mbytes, %d reallocations", dateDescription, (double)totalMemory / 1024 / 1024, fvzone->_reallocCount);
    if (NULL != dateDescription) CFRelease(dateDescription);
    [pool release];
}

#endif

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
