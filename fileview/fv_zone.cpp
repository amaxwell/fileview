/*
 *  fv_zone.cpp
 *  FileView
 *
 *  Created by Adam Maxwell on 11/14/08.
 *
 */
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

#include "fv_zone.h"
#import <libkern/OSAtomic.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <pthread.h>
#import <sys/time.h>

#import <set>
#import <iostream>

#if DEBUG
#define FVCParameterAssert(condition) do { if(false == (condition)) { HALT; } } while(0)
#else
#define FVCParameterAssert(condition)
#endif

typedef struct _fv_zone_t {
    malloc_zone_t      _basic_zone;
    std::multiset<struct _fv_allocation_t *, bool(*)(struct _fv_allocation_t *, struct _fv_allocation_t *)>  *_availableAllocations;
    OSSpinLock         _spinLock;
    std::set<struct _fv_allocation_t *>          *_allocations;
    volatile uint32_t  _cacheHits;
    volatile uint32_t  _cacheMisses;
    volatile uint32_t  _reallocCount;
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


// used as guard field in allocation struct; do not rely on the value
static char _malloc_guard;  /* indicates underlying allocator is malloc_default_zone() */
static char _vm_guard;      /* indicates vm_allocate was used for this block           */

static std::set<fv_zone_t *> *_allZones = NULL;
static pthread_mutex_t        _allZonesLock = PTHREAD_MUTEX_INITIALIZER;

// small allocations (below 15K) use malloc_default_zone()
#define FV_VM_THRESHOLD 15360UL
// clean up the pool at 100 MB of freed memory
#define FV_REAP_THRESHOLD 104857600UL

#if DEBUG
#define FV_REAP_TIMEINTERVAL 60
#else
#define FV_REAP_TIMEINTERVAL 300
#endif

// fv_allocation_t struct always immediately precedes the data pointer
// returns NULL if the pointer was not allocated in this zone
static inline fv_allocation_t *__FVGetAllocationFromPointer(fv_zone_t *zone, const void *ptr)
{
    fv_allocation_t *alloc = NULL;
    if ((uintptr_t)ptr >= sizeof(fv_allocation_t))
        alloc = (fv_allocation_t *)((uintptr_t)ptr - sizeof(fv_allocation_t));
    if (zone->_allocations->find(alloc) == zone->_allocations->end()) {
        alloc = NULL;
    } 
    else if (NULL != alloc && alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard) {
        malloc_printf("inconsistency in allocation records for zone %s\n", malloc_get_zone_name(&zone->_basic_zone));
        HALT;
    }
    /*
     The simple check to ensure that this is one of our pointers will fail if the math results in a pointer outside our address space, if we're passed a non-FVAllocator pointer in a certain memory region.  This happens when loading the plugin into IB, for instance.
     if (NULL != alloc && alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard)
     alloc = NULL;
     */
    return alloc;
}

static inline bool __FVAllocatorUseVMForSize(size_t size) { return size >= FV_VM_THRESHOLD; }


// Deallocates a particular block, according to its underlying storage (vm or szone).
static inline void __FVAllocationDestroy(fv_allocation_t *alloc)
{
    if (__builtin_expect((alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard), 0)) {
        malloc_printf("%s: invalid allocation pointer %p\n", __PRETTY_FUNCTION__, alloc);
        malloc_printf("Break on malloc_printf to debug.\n");
        HALT;
    }
    
    // _vm_guard indicates it should be freed with vm_deallocate
    if (__builtin_expect(&_vm_guard == alloc->guard, 1)) {
        FVCParameterAssert(__FVAllocatorUseVMForSize(alloc->allocSize));
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

// does not include fv_allocation_t header size
static inline size_t __FVAllocatorRoundSize(const size_t requestedSize, bool *useVM)
{
    FVCParameterAssert(NULL != useVM);
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
static inline void __FVRecordAllocation(fv_allocation_t *alloc, fv_zone_t *zone)
{
    OSSpinLockLock(&zone->_spinLock);
    FVCParameterAssert(zone->_allocations->find(alloc) == zone->_allocations->end());
    zone->_allocations->insert(alloc);
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
    FVCParameterAssert(round_page(actualSize) == actualSize);
    
    // allocations going through this allocator will always be larger than 4K
    kern_return_t ret;
    ret = vm_allocate(mach_task_self(), &memory, actualSize, VM_FLAGS_ANYWHERE);
    if (KERN_SUCCESS != ret) memory = 0;
    
    // set up the data structure
    if (__builtin_expect(0 != memory, 1)) {
        // align ptr to a page boundary
        void *ptr = (void *)round_page((uintptr_t)(memory + sizeof(fv_allocation_t)));
        // alloc struct immediately precedes ptr so we can find it again
        alloc = (fv_allocation_t *)((uintptr_t)ptr - sizeof(fv_allocation_t));
        alloc->ptr = ptr;
        // ptrSize field is the size of ptr, not including the header or padding; used for array sorting
        alloc->ptrSize = (uintptr_t)memory + actualSize - (uintptr_t)alloc->ptr;
        // record the base address and size for deallocation purposes
        alloc->base = (void *)memory;
        alloc->allocSize = actualSize;
        alloc->zone = zone;
        alloc->free = true;
        alloc->guard = &_vm_guard;
        FVCParameterAssert(alloc->ptrSize >= requestedSize);
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
        alloc = (fv_allocation_t *)memory;
        alloc->ptr = (void *)((uintptr_t)memory + sizeof(fv_allocation_t));
        // ptrSize field is the size of ptr, not including the header; used for array sorting
        alloc->ptrSize = (uintptr_t)memory + actualSize - (uintptr_t)alloc->ptr;
        FVCParameterAssert(alloc->ptrSize == actualSize - sizeof(fv_allocation_t));
        // record the base address and size for deallocation purposes
        alloc->base = memory;
        alloc->allocSize = actualSize;
        alloc->zone = zone;
        alloc->free = true;
        alloc->guard = &_malloc_guard;
        FVCParameterAssert(alloc->ptrSize >= requestedSize);
        __FVRecordAllocation(alloc, zone);
    }
    return alloc;
}

#pragma mark Zone implementation

static size_t __FVAllocatorZoneSize(malloc_zone_t *fvzone, const void *ptr)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    const fv_allocation_t *alloc = __FVGetAllocationFromPointer(zone, ptr);
    // Simple check to ensure that this is one of our pointers; which size to return, though?  Need to return size for values allocated in this zone with malloc, even though malloc_default_zone() is the underlying zone, or else they won't be freed.
    return alloc ? alloc->ptrSize : 0;
}

static void *__FVAllocatorZoneMalloc(malloc_zone_t *fvzone, size_t size)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    
    const size_t origSize = size;
    bool useVM;
    // look for the possibly-rounded-up size, or the tolerance might cause us to create a new block
    size = __FVAllocatorRoundSize(size, &useVM);
    
    // !!! unlock on each if branch
    OSSpinLockLock(&zone->_spinLock);
    
    void *ret = NULL;
    
    fv_allocation_t request = { NULL, 0, NULL, size, NULL, NULL };
    std::multiset<fv_allocation_t *>::iterator next = zone->_availableAllocations->lower_bound(&request);
    fv_allocation_t *alloc = *next;
    
    if (zone->_availableAllocations->end() == next || ((float)(alloc->ptrSize - size) / size) > 1) {
        OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_cacheMisses);
        // nothing found; unlock immediately and allocate a new chunk of memory
        OSSpinLockUnlock(&zone->_spinLock);
        alloc = useVM ? __FVAllocationFromVMSystem(size, zone) : __FVAllocationFromMalloc(size, zone);
    }
    else {
        OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_cacheHits);
        // pass iterator to erase this element, not just any element of this size
        zone->_availableAllocations->erase(next);
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
    if (useVM) { FVCParameterAssert(memory == ret); }
    return ret;
}

static void __FVAllocatorZoneFree(malloc_zone_t *fvzone, void *ptr)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    
    // ignore NULL
    if (__builtin_expect(NULL != ptr, 1)) {    
        fv_allocation_t *alloc = __FVGetAllocationFromPointer(zone, ptr);
        // error on an invalid pointer
        if (__builtin_expect(NULL == alloc, 0)) {
            malloc_printf("%s: pointer %p not malloced in zone %s\n", __PRETTY_FUNCTION__, ptr, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
            return; /* not reached; keep clang happy */
        }
        // add to free list
        OSSpinLockLock(&zone->_spinLock);
        // check to ensure that it's not already in the free list
        // FIXME: assert availableAllocations does not contain alloc
        zone->_availableAllocations->insert(alloc);
        alloc->free = true;
        OSSpinLockUnlock(&zone->_spinLock);    
    }
}

static void *__FVAllocatorZoneRealloc(malloc_zone_t *fvzone, void *ptr, size_t size)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_reallocCount);
    
    void *newPtr;
    
    // okay to call realloc with a NULL pointer, but should not be the typical usage
    if (__builtin_expect(NULL != ptr, 1)) {    
        
        // bizarre, but documented behavior of realloc(3)
        if (__builtin_expect(0 == size, 0)) {
            __FVAllocatorZoneFree(fvzone, ptr);
            return __FVAllocatorZoneMalloc(fvzone, size);
        }
        
        fv_allocation_t *alloc = __FVGetAllocationFromPointer(zone, ptr);
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
            newPtr = __FVAllocatorZoneMalloc(fvzone, size);
            memcpy(newPtr, ptr, alloc->ptrSize);
            __FVAllocatorZoneFree(fvzone, ptr);
        }
        
    }
    else {
        // original pointer was NULL, so just malloc a new block
        newPtr = __FVAllocatorZoneMalloc(fvzone, size);
    }
    return newPtr;
}

// this may not be perfectly (thread) safe, but the caller is responsible for whatever happens...
static void __FVAllocatorZoneDestroy(malloc_zone_t *fvzone)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    
    // remove from timed processing
    pthread_mutex_lock(&_allZonesLock);
    _allZones->erase(zone);
    pthread_mutex_unlock(&_allZonesLock);
    
    // remove all the free buffers
    OSSpinLockLock(&zone->_spinLock);
    zone->_availableAllocations->clear();
    
    // now deallocate all buffers allocated using this zone, regardless of underlying call
    std::set<fv_allocation_t *>::iterator it;
    for (it = zone->_allocations->begin(); it != zone->_allocations->end(); it++) {
        __FVAllocationDestroy(*it);
    }
    zone->_allocations->clear();
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
    size_t *size = reinterpret_cast<size_t *>(context);
    const fv_allocation_t *alloc = reinterpret_cast<const fv_allocation_t *>(value);
    *size += alloc->ptrSize;
}

static size_t __FVAllocatorTotalSize(fv_zone_t *zone)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    size_t sizeTotal = 0;
    OSSpinLockLock(&zone->_spinLock);
    std::set<fv_allocation_t *>::iterator it;
    for (it = zone->_allocations->begin(); it != zone->_allocations->end(); it++) {
        __FVAllocatorSumAllocations(*it, &sizeTotal);
    }
    OSSpinLockUnlock(&zone->_spinLock);
    return sizeTotal;
}

static size_t __FVAllocatorGetSizeInUse(fv_zone_t *zone)
{
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    size_t sizeTotal = 0, sizeFree = 0;
    OSSpinLockLock(&zone->_spinLock);
    std::set<fv_allocation_t *>::iterator it;
    for (it = zone->_allocations->begin(); it != zone->_allocations->end(); it++) {
        __FVAllocatorSumAllocations(*it, &sizeTotal);
    }
    std::multiset<fv_allocation_t *>::iterator freeiter;
    for (freeiter = zone->_availableAllocations->begin(); freeiter != zone->_availableAllocations->end(); freeiter++) {
        __FVAllocatorSumAllocations(*freeiter, &sizeFree);
    }
    OSSpinLockUnlock(&zone->_spinLock);
    if (sizeTotal < sizeFree) {
        malloc_printf("inconsistent allocation record; free list exceeds allocation count\n");
        HALT;
    }
    return (sizeTotal - sizeFree);
}

static void __FVAllocatorZoneStatistics(malloc_zone_t *fvzone, malloc_statistics_t *stats)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    fprintf(stderr, "%s\n", __PRETTY_FUNCTION__);
    stats->blocks_in_use = zone->_allocations->size() - zone->_availableAllocations->size();
    stats->size_in_use = __FVAllocatorGetSizeInUse(zone);
    stats->max_size_in_use = __FVAllocatorTotalSize(zone);
    stats->size_allocated = stats->max_size_in_use;
}

// called when preparing for a fork() (see _malloc_fork_prepare() in malloc.c)
static void __FVAllocatorForceLock(malloc_zone_t *fvzone)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    OSSpinLockLock(&zone->_spinLock);
}

// called in parent and child after fork() (see _malloc_fork_parent() and _malloc_fork_child() in malloc.c)
static void __FVAllocatorForceUnlock(malloc_zone_t *fvzone)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
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

static void __enumerator_applier(const void *value, applier_context *ctxt)
{
    const fv_allocation_t *alloc = reinterpret_cast<const fv_allocation_t *>(value);
    
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
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(zone_address);
    OSSpinLockLock(&zone->_spinLock);
    kern_return_t ret = 0;
    applier_context ctxt = { task, context, type_mask, zone, reader, recorder, &ret };
    std::set<fv_allocation_t *>::iterator it;
    for (it = zone->_allocations->begin(); it != zone->_allocations->end(); it++) {
        __enumerator_applier(*it, &ctxt);
    }
    OSSpinLockUnlock(&zone->_spinLock);
    return ret;
}

static const struct malloc_introspection_t __FVAllocatorZoneIntrospect = {
    __FVAllocatorEnumerator,
    __FVAllocatorZoneGoodSize,
    __FVAllocatorZoneIntrospectTrue,
    __FVAllocatorZonePrint,
    __FVAllocatorZoneLog,
    __FVAllocatorForceLock,
    __FVAllocatorForceUnlock,
    __FVAllocatorZoneStatistics
};

static bool __FVAllocationSizeComparator(fv_allocation_t *val1, fv_allocation_t *val2) { return (val1->ptrSize < val2->ptrSize); }

// could be exposed as API in future, since it's declared as malloc_zone_t
malloc_zone_t *fv_create_zone_named(const char *name)
{
    // can't rely on initializers to do this early enough, since FVAllocator creates a zone in a __constructor__
    pthread_mutex_lock(&_allZonesLock);
    if (NULL == _allZones) _allZones = new std::set<fv_zone_t *>;
    pthread_mutex_unlock(&_allZonesLock);

    fv_zone_t *zone = (fv_zone_t *)malloc_zone_malloc(malloc_default_zone(), sizeof(fv_zone_t));
    memset(zone, 0, sizeof(fv_zone_t));
    zone->_basic_zone.size = __FVAllocatorZoneSize;
    zone->_basic_zone.malloc = __FVAllocatorZoneMalloc;
    zone->_basic_zone.calloc = __FVAllocatorZoneCalloc;
    zone->_basic_zone.valloc = __FVAllocatorZoneValloc;
    zone->_basic_zone.free = __FVAllocatorZoneFree;
    zone->_basic_zone.realloc = __FVAllocatorZoneRealloc;
    zone->_basic_zone.destroy = __FVAllocatorZoneDestroy;
    zone->_basic_zone.zone_name = strdup(name); /* assumes we have the default malloc zone */
    zone->_basic_zone.batch_malloc = NULL;
    zone->_basic_zone.batch_free = NULL;
    zone->_basic_zone.introspect = (struct malloc_introspection_t *)&__FVAllocatorZoneIntrospect;
    zone->_basic_zone.version = 3;  /* from scalable_malloc.c in Libc-498.1.1 */
    
    // malloc_set_zone_name calls out to this zone, so we need the array/set to exist
    
    // http://www.cplusplus.com/reference/stl/set/set.html
    // proof that C++ programmers have to be insane
    bool (*compare_ptr)(fv_allocation_t *, fv_allocation_t *) = __FVAllocationSizeComparator;
    zone->_availableAllocations = new std::multiset<fv_allocation_t *, bool(*)(fv_allocation_t *, fv_allocation_t *)>(compare_ptr);
    zone->_allocations = new std::set<fv_allocation_t *>;
    
    // register so the system handles lookups correctly, or malloc_zone_from_ptr() breaks (along with free())
    malloc_zone_register((malloc_zone_t *)zone);
    
    // register for timer
    pthread_mutex_lock(&_allZonesLock);
    _allZones->insert(zone);
    pthread_mutex_unlock(&_allZonesLock);
    
    return (malloc_zone_t *)zone;
}

#pragma mark Setup and cleanup

#define ENABLE_STATS 1
#if DEBUG && ENABLE_STATS
static void __FVAllocatorShowStats(fv_zone_t *fvzone);
#endif

static void __FVAllocatorReapZone(fv_zone_t *zone)
{
#if DEBUG && ENABLE_STATS
    __FVAllocatorShowStats(zone);
#endif
    // if we can't lock immediately, wait for another opportunity
    if (OSSpinLockTry(&zone->_spinLock)) {
        
        // iterate the free list to see how much memory is unused
        size_t freeMemory = 0;
        std::set<fv_allocation_t *>::iterator it;
        for (it = zone->_availableAllocations->begin(); it != zone->_availableAllocations->end(); it++) {
            freeMemory += (*it)->allocSize;
        }         
        
        if (freeMemory > FV_REAP_THRESHOLD) {
            
            // clear out all of the available allocations; this could be more intelligent
            for (it = zone->_availableAllocations->begin(); it != zone->_availableAllocations->end(); it++) {
                // remove from the allocation list
                FVCParameterAssert(zone->_allocations->find(*it) != zone->_allocations->end());
                zone->_allocations->erase(*it);
                // deallocate underlying storage
                __FVAllocationDestroy(*it);
            } 
            // now remove all blocks from the free list
            zone->_availableAllocations->clear();
        }
        OSSpinLockUnlock(&zone->_spinLock);
    }
}

// periodically check all zones against the per-zone high water mark for unused memory
static void *__FVAllocatorReapThread(void *unused)
{
    do {
        sleep(FV_REAP_TIMEINTERVAL);
        pthread_mutex_lock(&_allZonesLock);
        std::set<fv_zone_t *>::iterator it;
        for (it = _allZones->begin(); it != _allZones->end(); it++) {
            __FVAllocatorReapZone(*it);
        }
        pthread_mutex_unlock(&_allZonesLock);
    } while (1);
    
    return NULL;
}

__attribute__ ((constructor))
static void __initialize_reaper_thread()
{    
    
    // create a thread to do periodic cleanup so memory usage doesn't get out of hand
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    
    // not required as an ivar at present
    pthread_t thread;
    (void)pthread_create(&thread, &attr, __FVAllocatorReapThread, NULL);
    pthread_attr_destroy(&attr);    
}

#pragma mark statistics

#if DEBUG && ENABLE_STATS

static std::multiset<size_t> __FVAllocatorFreeSizesLocked(fv_zone_t *fvzone, size_t *freeMemPtr)
{
    size_t freeMemory = 0;
    std::multiset<size_t> allocationSet;
    std::set<fv_allocation_t *>::iterator it;
    for (it = fvzone->_availableAllocations->begin(); it != fvzone->_availableAllocations->end(); it++) {
        fv_allocation_t *alloc = *it;
        if (__builtin_expect((alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard), 0)) {
            malloc_printf("%s: invalid allocation pointer %p\n", __PRETTY_FUNCTION__, alloc);
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
        // FIXME: consistent size usage
        freeMemory += alloc->allocSize;
        allocationSet.insert(alloc->ptrSize);
    } 
    if (freeMemPtr) *freeMemPtr = freeMemory;
    return allocationSet;
}

static std::multiset<size_t> __FVAllocatorAllSizesLocked(fv_zone_t *fvzone, size_t *totalMemPtr)
{
    size_t totalMemory = 0;
    std::multiset<size_t> allocationSet;
    std::set<fv_allocation_t *>::iterator it;
    for (it = fvzone->_allocations->begin(); it != fvzone->_allocations->end(); it++) {
        fv_allocation_t *alloc = *it;
        if (__builtin_expect((alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard), 0)) {
            malloc_printf("%s: invalid allocation pointer %p\n", __PRETTY_FUNCTION__, alloc);
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
        // FIXME: consistent size usage
        totalMemory += alloc->allocSize;
        allocationSet.insert(alloc->ptrSize);
    } 
    if (totalMemPtr) *totalMemPtr = totalMemory;
    return allocationSet;
}

// can't make this public, since it relies on the argument being an fv_zone_t (which must not be exposed)
static void __FVAllocatorShowStats(fv_zone_t *fvzone)
{
    // use the default zone explicitly; avoid callout to our custom zone(s)
    OSSpinLockLock(&fvzone->_spinLock);
    // record the actual time of this measurement
    const time_t absoluteTime = time(NULL);
    size_t totalMemory = 0, freeMemory = 0;
    std::multiset<size_t> allocationSet = __FVAllocatorAllSizesLocked(fvzone, &totalMemory);
    std::multiset<size_t> freeSet = __FVAllocatorFreeSizesLocked(fvzone, &freeMemory);
    OSSpinLockUnlock(&fvzone->_spinLock);
    
    fprintf(stderr, "------------------------------------\n");
    fprintf(stderr, "Zone name: %s\n", malloc_get_zone_name(&fvzone->_basic_zone));
    fprintf(stderr, "   Size     Count(Free)  Total  Percentage\n");
    fprintf(stderr, "   (b)       --    --    (Mb)      ----   \n");
    
    const double totalMemoryMbytes = (double)totalMemory / 1024 / 1024;
    std::multiset<size_t>::iterator it;
    for (it = allocationSet.begin(); it != allocationSet.end(); it = allocationSet.upper_bound(*it)) {
        size_t allocationSize = *it;
        size_t count = allocationSet.count(allocationSize);
        size_t freeCount = freeSet.count(allocationSize);
        double totalMbytes = double(allocationSize) * count / 1024 / 1024;
        double percentOfTotal = totalMbytes / totalMemoryMbytes * 100;
        fprintf(stderr, "%8lu    %3lu  (%3lu)  %5.2f    %5.2f %%\n", (long)allocationSize, (long)count, (long)freeCount, totalMbytes, percentOfTotal);        
    }
    
    // avoid divide-by-zero
    double cacheRequests = (fvzone->_cacheHits + fvzone->_cacheMisses);
    double missRate = cacheRequests > 0 ? (double)fvzone->_cacheMisses / (fvzone->_cacheHits + fvzone->_cacheMisses) * 100 : 0;
    
    struct tm time;
    localtime_r(&absoluteTime, &time);
    
    const char *timeFormat = "%Y-%m-%d %T"; // 2008-11-12 21:51:00 --> 20 characters
    char timeString[32] = { '\0' };
    strftime(timeString, sizeof(timeString), timeFormat, &time);
    fprintf(stderr, "%s: %d hits and %d misses for a cache failure rate of %.2f%%\n", timeString, fvzone->_cacheHits, fvzone->_cacheMisses, missRate);
    fprintf(stderr, "%s: total in use: %.2f Mbytes, total available: %.2f Mbytes, %d reallocations, \n", timeString, double(totalMemory) / 1024 / 1024, double(freeMemory) / 1024 / 1024, fvzone->_reallocCount);
}

#endif

