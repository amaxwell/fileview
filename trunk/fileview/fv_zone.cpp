/*
 *  fv_zone.cpp
 *  FileView
 *
 *  Created by Adam Maxwell on 11/14/08.
 *
 */
/*
 This software is Copyright (c) 2008-2012
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

#import "fv_zone.h"
#import <libkern/OSAtomic.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <pthread.h>
#import <sys/time.h>
#import <math.h>
#import <errno.h>

#import <set>
#import <map>
#import <vector>
#import <iostream>
using namespace std;

#define FV_USE_MMAP 0
#if FV_USE_MMAP
#import <sys/mman.h>
#endif

#if MAC_OS_X_VERSION_MAX_ALLOWED <= MAC_OS_X_VERSION_10_5
#ifndef mach_vm_round_page
#define mach_vm_round_page(x) (((mach_vm_offset_t)(x) + PAGE_MASK) & ~((signed)PAGE_MASK))
#endif
#endif

#if DEBUG
#define ENABLE_STATS 0
static void fv_zone_assert(bool x) CLANG_ANALYZER_NORETURN;
static void fv_zone_assert(bool condition) { if(false == (condition)) { HALT; } }
#else
#define ENABLE_STATS 0
#define fv_zone_assert(condition)
#endif

#define FV_VM_MEMORY_MALLOC 240
#define FV_VM_MEMORY_REALLOC 241

// define so the template isn't insanely wide
#define ALLOC struct _fv_allocation_t *
#define MSALLOC ALLOC, bool(*)(ALLOC, ALLOC)

typedef struct _fv_zone_t {
    malloc_zone_t      _basic_zone;
    void              *_reserved[2];          /* for future expansion of malloc_zone_t */
    multiset<MSALLOC> *_availableAllocations; /* <fv_allocation_t *>, counted by size  */
    vector<ALLOC>     *_allocations;          /* all allocations, ordered by address   */
    ALLOC             *_allocPtr;             /* pointer to _allocations storage       */
    size_t             _allocPtrCount;        /* number of ALLOC pointers in _allocPtr */
    size_t             _allocatedSize;        /* free + active allocations (allocSize) */
    size_t             _freeSize;             /* available allocations (allocSize)     */
    pthread_mutex_t    _lock;                 /* lock before manipulating fields       */
#if ENABLE_STATS
    volatile uint32_t  _cacheHits;
    volatile uint32_t  _cacheMisses;
    volatile uint32_t  _reallocCount;
#endif
} fv_zone_t;

typedef struct _fv_allocation_t {
    void            *base;      /* base of entire allocation     */
    size_t           allocSize; /* length of entire allocation   */
    void            *ptr;       /* writable region of allocation */
    size_t           ptrSize;   /* writable length of ptr        */
    const fv_zone_t *zone;      /* fv_zone_t                     */
    bool             free;      /* in use or in the free list    */
#if ENABLE_STATS
    uint32_t         timesUsed; /* for stats logging only        */
#endif
    const void      *guard;     /* pointer to a check variable   */
} fv_allocation_t;

#define LOCK_INIT(z) (pthread_mutex_init(&(z)->_lock, NULL))
#define LOCK(z) (pthread_mutex_lock(&(z)->_lock))
#define UNLOCK(z) (pthread_mutex_unlock(&(z)->_lock))
#define TRYLOCK(z) (pthread_mutex_trylock(&(z)->_lock) == 0)

// used as sentinel field in allocation struct; do not rely on the value
static char _malloc_guard;  /* indicates underlying allocator is malloc_default_zone() */
static char _vm_guard;      /* indicates vm_allocate was used for this block           */

// track all zones allocated by fv_create_zone_named()
static set<fv_zone_t *> *_allZones = NULL;
static pthread_mutex_t   _allZonesLock = PTHREAD_MUTEX_INITIALIZER;

// used to explicitly signal collection
static pthread_cond_t    _collectorCond = PTHREAD_COND_INITIALIZER;

// MallocScribble
static bool              _scribble = false;

// small allocations (below 15K) use malloc_default_zone()
#define FV_VM_THRESHOLD 15360UL
// clean up the pool at 100 MB of freed memory
#define FV_COLLECT_THRESHOLD 104857600UL

#if ENABLE_STATS
#define FV_COLLECT_TIMEINTERVAL 60
#else
#define FV_COLLECT_TIMEINTERVAL 10
#endif

#define FV_ALLOC_FROM_POINTER(ptr) ((fv_allocation_t *)((uintptr_t)(ptr) - sizeof(fv_allocation_t)))

static inline fv_allocation_t *__fv_zone_get_allocation_from_pointer_locked(fv_zone_t *zone, const void *ptr)
{
    fv_allocation_t *alloc = NULL;
    if ((uintptr_t)ptr >= sizeof(fv_allocation_t))
        alloc = FV_ALLOC_FROM_POINTER(ptr);
    if (binary_search(zone->_allocations->begin(), zone->_allocations->end(), alloc) == false) {
        alloc = NULL;
    } 
    else if (NULL != alloc && alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard) {
        malloc_printf("inconsistency in allocation records for zone %s\n", malloc_get_zone_name(&zone->_basic_zone));
        HALT;
    }
    /*
     This simple check to ensure that this is one of our pointers will fail if the math results in 
     dereferenceing a pointer outside our address space, if we're passed a non-FVAllocator pointer 
     in a certain memory region.  This happens when loading the plugin into IB, for instance.
     
     if (NULL != alloc && alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard)
     alloc = NULL;
     */
    return alloc;
}

// fv_allocation_t struct always immediately precedes the data pointer
// returns NULL if the pointer was not allocated in this zone
static inline fv_allocation_t *__fv_zone_get_allocation_from_pointer(fv_zone_t *zone, const void *ptr)
{
    LOCK(zone);
    fv_allocation_t *alloc = __fv_zone_get_allocation_from_pointer_locked(zone, ptr);
    UNLOCK(zone);
    return alloc;
}

static inline bool __fv_zone_use_vm(size_t size) { return size >= FV_VM_THRESHOLD; }


// Deallocates a particular block, according to its underlying storage (vm or szone).
static inline void __fv_zone_destroy_allocation(fv_allocation_t *alloc)
{
    if (__builtin_expect((alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard), 0)) {
        malloc_printf("%s: invalid allocation pointer %p\n", __func__, alloc);
        malloc_printf("Break on malloc_printf to debug.\n");
        HALT;
    }
    
    // _vm_guard indicates it should be freed with vm_deallocate
    if (__builtin_expect(&_vm_guard == alloc->guard, 1)) {
        fv_zone_assert(__fv_zone_use_vm(alloc->allocSize));
#if FV_USE_MMAP
        int ret = munmap(alloc->base, alloc->allocSize);
#else
        mach_vm_size_t len = alloc->allocSize;
        kern_return_t ret = mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)alloc->base, len);
#endif
        if (__builtin_expect(0 != ret, 0)) {
            malloc_printf("mach_vm_deallocate failed to deallocate object %p", alloc);        
            malloc_printf("Break on malloc_printf to debug.\n");
        }
    }
    else {
        malloc_zone_free(malloc_default_zone(), alloc->base);
    }
}

// does not include fv_allocation_t header size
static inline size_t __fv_zone_round_size(const size_t requestedSize, bool *useVM)
{
    fv_zone_assert(NULL != useVM);
    // allocate at least requestedSize
    size_t actualSize = requestedSize;
    *useVM = __fv_zone_use_vm(actualSize);
    if (*useVM) {
        
        if (actualSize < 102400) 
            actualSize = mach_vm_round_page(actualSize);
        else if (actualSize < 143360)
            actualSize = mach_vm_round_page(143360);
        else if (actualSize < 204800)
            actualSize = mach_vm_round_page(204800);
        else if (actualSize < 262144)
            actualSize = mach_vm_round_page(262144);
        else if (actualSize < 307200)
            actualSize = mach_vm_round_page(307200);
        else if (actualSize < 512000)
            actualSize = mach_vm_round_page(512000);
        else if (actualSize < 614400)
            actualSize = mach_vm_round_page(614400);
        else 
            actualSize = mach_vm_round_page(actualSize);
        
    }
    else if (actualSize < 128) {
        actualSize = 128;
    }
    if (__builtin_expect(requestedSize > actualSize, 0)) {
        malloc_printf("%s: invalid size %y after rounding %y to page boundary\n", __func__, actualSize, requestedSize);
        malloc_printf("Break on malloc_printf to debug.\n");
        HALT;
    }
    return actualSize;
}

// Record the allocation for zone destruction.
static inline void __fv_zone_record_allocation(fv_allocation_t *alloc, fv_zone_t *zone)
{
    LOCK(zone);
    fv_zone_assert(binary_search(zone->_allocations->begin(), zone->_allocations->end(), alloc) == false);
    zone->_allocatedSize += alloc->allocSize;
    vector <fv_allocation_t *>::iterator it = upper_bound(zone->_allocations->begin(), zone->_allocations->end(), alloc);
    zone->_allocations->insert(it, alloc);
    zone->_allocPtr = &zone->_allocations->front();
    zone->_allocPtrCount = zone->_allocations->size();
    UNLOCK(zone);
}

/*
 Layout of memory allocated by __fv_zone_vm_allocation().  The padding at the beginning is for page alignment.  
 Caller is responsible for passing the result of __fv_zone_round_size() to this function.
 
 |<-- base (page boundary)                  
 |<------------------------------ allocSize ---------------------------->|
 |<- padding ->|<- fv_allocation_t ->|<- data data data data data data ->|
 |                                   |<------------ ptrSize ------------>|
 |                                   |<- ptr (writeable)
 */

static fv_allocation_t *__fv_zone_vm_allocation(const size_t requestedSize, fv_zone_t *zone)
{
    // base address of the allocation, including fv_allocation_t
    mach_vm_address_t memory;
    fv_allocation_t *alloc = NULL;
    
    // use this space for the header
    size_t actualSize = requestedSize + PAGE_SIZE;
    fv_zone_assert(mach_vm_round_page(actualSize) == actualSize);
    
    // allocations going through this allocator will always be larger than 4K
#if FV_USE_MMAP
    memory = (mach_vm_address_t)mmap(0, actualSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, VM_MAKE_TAG(FV_VM_MEMORY_MALLOC), 0);
    if ((void *)memory == MAP_FAILED) memory = 0;
#else    
    kern_return_t ret;
    ret = mach_vm_allocate(mach_task_self(), &memory, actualSize, VM_FLAGS_ANYWHERE | VM_MAKE_TAG(FV_VM_MEMORY_MALLOC));
    if (KERN_SUCCESS != ret) memory = 0;    
#endif
    
    // set up the data structure
    if (__builtin_expect(0 != memory, 1)) {
        // align ptr to a page boundary
        void *ptr = (void *)mach_vm_round_page((uintptr_t)(memory + sizeof(fv_allocation_t)));
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
        fv_zone_assert(alloc->ptrSize >= requestedSize);
        __fv_zone_record_allocation(alloc, zone);
    }
    return alloc;
}

// memory is not page-aligned so there's no padding between the start of the allocated block and the returned fv_allocation_t pointer
static fv_allocation_t *__fv_zone_malloc_allocation(const size_t requestedSize, fv_zone_t *zone)
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
        fv_zone_assert(alloc->ptrSize == actualSize - sizeof(fv_allocation_t));
        // record the base address and size for deallocation purposes
        alloc->base = memory;
        alloc->allocSize = actualSize;
        alloc->zone = zone;
        alloc->free = true;
        alloc->guard = &_malloc_guard;
        fv_zone_assert(alloc->ptrSize >= requestedSize);
        __fv_zone_record_allocation(alloc, zone);
    }
    return alloc;
}

#pragma mark Zone implementation

static size_t fv_zone_size(malloc_zone_t *fvzone, const void *ptr)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    const fv_allocation_t *alloc = __fv_zone_get_allocation_from_pointer(zone, ptr);
    // Simple check to ensure that this is one of our pointers; which size to return, though?  Need to return size for values allocated in this zone with malloc, even though malloc_default_zone() is the underlying zone, or else they won't be freed.
    return alloc ? alloc->ptrSize : 0;
}

static void *fv_zone_malloc(malloc_zone_t *fvzone, size_t size)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    
    const size_t origSize = size;
    bool useVM;
    // look for the possibly-rounded-up size, or the tolerance might cause us to create a new block
    size = __fv_zone_round_size(size, &useVM);
    
    // !!! unlock on each if branch
    LOCK(zone);
    
    void *ret = NULL;
    
    fv_allocation_t request = { NULL, 0, NULL, size, NULL, NULL };
    multiset<fv_allocation_t *>::iterator next = zone->_availableAllocations->lower_bound(&request);
    fv_allocation_t *alloc = *next;
    
    if (zone->_availableAllocations->end() == next || ((float)(alloc->ptrSize - size) / size) > 1) {
#if ENABLE_STATS
        OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_cacheMisses);
#endif
        // nothing found; unlock immediately and allocate a new chunk of memory
        UNLOCK(zone);
        alloc = useVM ? __fv_zone_vm_allocation(size, zone) : __fv_zone_malloc_allocation(size, zone);
    }
    else {
#if ENABLE_STATS
        OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_cacheHits);
#endif
        // pass iterator to erase this element, rather than an arbitrary element of this size
        zone->_availableAllocations->erase(next);
        fv_zone_assert(zone->_freeSize >= alloc->allocSize);
        zone->_freeSize -= alloc->allocSize;
        UNLOCK(zone);
        if (__builtin_expect(origSize > alloc->ptrSize, 0)) {
            malloc_printf("incorrect size %y (%y expected) in %s\n", alloc->ptrSize, origSize, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
    }
    if (__builtin_expect(NULL != alloc, 1)) {
#if ENABLE_STATS
        alloc->timesUsed++;
#endif
        alloc->free = false;
        ret = alloc->ptr;
        if (_scribble) memset(ret, 0xaa, alloc->ptrSize);
    }
    return ret;    
}

static void *fv_zone_calloc(malloc_zone_t *zone, size_t num_items, size_t size)
{
    void *memory = fv_zone_malloc(zone, num_items * size);
    memset(memory, 0, num_items * size);
    return memory;
}

// implementation for non-VM case was modified after the implementation in CFBase.c
static void *fv_zone_valloc(malloc_zone_t *zone, size_t size)
{
    // this will already be page-aligned if we're using vm
    const bool useVM = __fv_zone_use_vm(size);
    if (false == useVM) size += PAGE_SIZE;
    void *memory = fv_zone_malloc(zone, size);
    memset(memory, 0, size);
    // this should have no effect if we used vm to allocate
    void *ret = (void *)mach_vm_round_page((uintptr_t)memory);
    if (useVM) { fv_zone_assert(memory == ret); }
    return ret;
}

static void __fv_zone_free_allocation_locked(fv_zone_t *zone, fv_allocation_t *alloc)
{
    if (_scribble) memset(alloc->ptr, 0x55, alloc->ptrSize);
    // check to ensure that it's not already in the free list
    pair <multiset<fv_allocation_t *>::iterator, multiset<fv_allocation_t *>::iterator> range;
    range = zone->_availableAllocations->equal_range(alloc);
    multiset <fv_allocation_t *>::iterator it;
    for (it = range.first; it != range.second; it++) {
        if (*it == alloc) {
            malloc_printf("%s: double free of pointer %p in zone %s\n", __func__, alloc->ptr, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
    }
    // add to free list
    zone->_availableAllocations->insert(alloc);
    alloc->free = true;
    zone->_freeSize += alloc->allocSize;
    
    // signal for collection if needed (lock not required, no effect if not blocking on the condition)
    if (zone->_freeSize > FV_COLLECT_THRESHOLD)
        pthread_cond_signal(&_collectorCond);    
}

static void fv_zone_free(malloc_zone_t *fvzone, void *ptr)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    
    // ignore NULL
    if (__builtin_expect(NULL != ptr, 1)) {    
        LOCK(zone);
        fv_allocation_t *alloc = __fv_zone_get_allocation_from_pointer_locked(zone, ptr);
        // error on an invalid pointer
        if (__builtin_expect(NULL == alloc, 0)) {
            malloc_printf("%s: pointer %p not malloced in zone %s\n", __func__, ptr, malloc_get_zone_name(&zone->_basic_zone));
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
            return; /* not reached; keep clang happy */
        }
        __fv_zone_free_allocation_locked(zone, alloc);
        UNLOCK(zone);
    }
}

#if defined(MAC_OS_X_VERSION_10_6) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
static void fv_zone_free_definite(malloc_zone_t *fvzone, void *ptr, size_t size)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    fv_allocation_t *alloc = FV_ALLOC_FROM_POINTER(ptr);
    LOCK(zone);
    __fv_zone_free_allocation_locked(zone, alloc);
    UNLOCK(zone);      
}
#endif

static void *fv_zone_realloc(malloc_zone_t *fvzone, void *ptr, size_t size)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);

#if ENABLE_STATS
    OSAtomicIncrement32Barrier((volatile int32_t *)&zone->_reallocCount);
#endif
    
    // !!! two early returns here
    
    // okay to call realloc with a NULL pointer, but should not be the typical usage; just malloc a new block
    if (__builtin_expect(NULL == ptr, 0))
        return fv_zone_malloc(fvzone, size);
        
    // bizarre, but documented behavior of realloc(3)
    if (__builtin_expect(0 == size, 0)) {
        fv_zone_free(fvzone, ptr);
        return fv_zone_malloc(fvzone, size);
    }
    
    void *newPtr;

    fv_allocation_t *alloc = __fv_zone_get_allocation_from_pointer(zone, ptr);
    // error on an invalid pointer
    if (__builtin_expect(NULL == alloc, 0)) {
        malloc_printf("%s: pointer %p not malloced in zone %s\n", __func__, ptr, malloc_get_zone_name(&zone->_basic_zone));
        malloc_printf("Break on malloc_printf to debug.\n");
        HALT;
        return NULL; /* not reached; keep clang happy */
    }
    
    kern_return_t ret = KERN_FAILURE;
    
    // See if it's already large enough, due to padding, or the caller requesting a smaller block (so we never resize downwards).
    if (alloc->ptrSize >= size) {
        newPtr = ptr;
        ret = KERN_SUCCESS;
    }
    else if (alloc->guard == &_vm_guard) {
        // pointer to the current end of this region
        mach_vm_address_t addr = (mach_vm_address_t)alloc->base + alloc->allocSize;
        // attempt to allocate at a specific address and extend the existing region
        ret = mach_vm_allocate(mach_task_self(), &addr, mach_vm_round_page(size) - alloc->allocSize, VM_FLAGS_FIXED | VM_MAKE_TAG(FV_VM_MEMORY_REALLOC));
        // if this succeeds, increase sizes and assign newPtr to the original parameter
        if (KERN_SUCCESS == ret) {
            alloc->allocSize += mach_vm_round_page(size);
            alloc->ptrSize += mach_vm_round_page(size);
            // adjust allocation size in the zone
            LOCK(zone);
            zone->_allocatedSize += mach_vm_round_page(size);
            UNLOCK(zone);
            newPtr = ptr;
        }
    }
    
    // if this wasn't a vm region or the vm region couldn't be extended, allocate a new block
    if (KERN_SUCCESS != ret) {
        // get a new buffer, copy contents, return original ptr to the pool; should try to use vm_copy here
        newPtr = fv_zone_malloc(fvzone, size);
        memcpy(newPtr, ptr, alloc->ptrSize);
        fv_zone_free(fvzone, ptr);
    }
        
    return newPtr;
}

// this may not be perfectly (thread) safe, but the caller is responsible for whatever happens...
static void fv_zone_destroy(malloc_zone_t *fvzone)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    
    // remove from timed processing
    pthread_mutex_lock(&_allZonesLock);
    if (NULL == _allZones || _allZones->count(zone) == 0) {
        malloc_printf("attempt to destroy invalid fvzone %s\n", malloc_get_zone_name(&zone->_basic_zone));
        HALT;
    }
    _allZones->erase(zone);
    pthread_mutex_unlock(&_allZonesLock);
    
    // remove all the free buffers
    LOCK(zone);
    zone->_availableAllocations->clear();
    delete zone->_availableAllocations;
    zone->_availableAllocations = NULL;

    // now deallocate all buffers allocated using this zone, regardless of underlying call
    for_each(zone->_allocations->begin(), zone->_allocations->end(), __fv_zone_destroy_allocation);
    zone->_allocations->clear();    
    delete zone->_allocations;
    zone->_allocations = NULL;
    
    zone->_allocPtr = NULL;
    zone->_allocPtrCount = 0;
    UNLOCK(zone);
    
    // free the zone itself (must have been allocated with malloc!)
    malloc_zone_free(malloc_zone_from_ptr(zone), zone);
}

static void fv_zone_print(malloc_zone_t *zone, boolean_t verbose) {
    malloc_printf("%s\n", __func__);
}

static void fv_zone_log(malloc_zone_t *zone, void *address) {
    malloc_printf("%s\n", __func__);
}

static boolean_t fv_zone_check(malloc_zone_t *zone) {
    malloc_printf("%s\n", __func__);
    return 1;
}

static size_t fv_zone_good_size(malloc_zone_t *zone, size_t size)
{
    malloc_printf("%s\n", __func__);
    bool ignored;
    return __fv_zone_round_size(size, &ignored);
}

/*
 
 Standard malloc_zone statistics functions use fv_zone.ptrSize to determine usage.
 This size determination is not compatible with collection or __fv_zone_show_stats,
 where I'm more interested in total allocation size.  Both are correct, but which
 one is appropriate depends on whether you're more concerned about client code heap
 usage or overhead of the fv_zone.
 
 */

static inline void __fv_zone_sum_allocations(fv_allocation_t *alloc, size_t *size)
{
    *size += alloc->ptrSize;
}

static size_t __fv_zone_total_size(fv_zone_t *zone)
{
    malloc_printf("%s\n", __func__);
    size_t sizeTotal = 0;
    LOCK(zone);
    vector<fv_allocation_t *>::iterator it;
    for (it = zone->_allocations->begin(); it != zone->_allocations->end(); it++) {
        __fv_zone_sum_allocations(*it, &sizeTotal);
    }
    UNLOCK(zone);
    return sizeTotal;
}

static size_t __fv_zone_get_size_in_use(fv_zone_t *zone)
{
    malloc_printf("%s\n", __func__);
    size_t sizeTotal = 0, sizeFree = 0;
    LOCK(zone);
    vector<fv_allocation_t *>::iterator it;
    for (it = zone->_allocations->begin(); it != zone->_allocations->end(); it++) {
        __fv_zone_sum_allocations(*it, &sizeTotal);
    }
    multiset<fv_allocation_t *>::iterator freeiter;
    for (freeiter = zone->_availableAllocations->begin(); freeiter != zone->_availableAllocations->end(); freeiter++) {
        __fv_zone_sum_allocations(*freeiter, &sizeFree);
    }
    UNLOCK(zone);
    if (sizeTotal < sizeFree) {
        malloc_printf("inconsistent allocation record; free list exceeds allocation count\n");
        HALT;
    }
    return (sizeTotal - sizeFree);
}

static void fv_zone_statistics(malloc_zone_t *fvzone, malloc_statistics_t *stats)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    malloc_printf("%s\n", __func__);
    stats->blocks_in_use = zone->_allocations->size() - zone->_availableAllocations->size();
    stats->size_in_use = __fv_zone_get_size_in_use(zone);
    stats->max_size_in_use = __fv_zone_total_size(zone);
    stats->size_allocated = stats->max_size_in_use;
}

// called when preparing for a fork() (see _malloc_fork_prepare() in malloc.c)
static void fv_zone_force_lock(malloc_zone_t *fvzone)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    LOCK(zone);
}

// called in parent and child after fork() (see _malloc_fork_parent() and _malloc_fork_child() in malloc.c)
static void fv_zone_force_unlock(malloc_zone_t *fvzone)
{
    fv_zone_t *zone = reinterpret_cast<fv_zone_t *>(fvzone);
    UNLOCK(zone);
}

typedef struct _fv_enumerator_context {
    task_t              task;
    void               *context;
    unsigned            type_mask;
    kern_return_t     (*reader)(task_t, vm_address_t, vm_size_t, void **);
    void              (*recorder)(task_t, void *, unsigned type, vm_range_t *, unsigned);
    kern_return_t      *ret;
} fv_enumerator_context;

static void __fv_zone_enumerate_allocation(const void *value, fv_enumerator_context *ctxt)
{    
    // call once to get a local copy of the header
    fv_allocation_t *alloc;
    kern_return_t err = ctxt->reader(ctxt->task, (vm_address_t)value, sizeof(fv_allocation_t), (void **)&alloc);
    if (err) {
        malloc_printf("%s: failed to read header\n", __func__);
        *ctxt->ret = err;
        return;
    }
    
    /*
     Now that we know the size of the allocation, read the entire block into local memory, recalling that
     base != alloc in some cases.  Store all the alloc parameters we use in local memory, then set alloc
     to NULL since calling reader() again will likely stomp on it, and it's better to crash immediately
     due to a NULL dereference.  See the layout comment at __fv_zone_vm_allocation for details.
     */
    const size_t allocSize = alloc->allocSize;
    const size_t ptrSize = alloc->ptrSize;
    const vm_address_t baseAddress = (vm_address_t)alloc->base;
    const vm_address_t ptrAddress = (vm_address_t)alloc->ptr;
    const bool isFree = alloc->free;
    alloc = NULL;
    
    void *base;
    err = ctxt->reader(ctxt->task, baseAddress, allocSize, (void **)&base);
        
    if (err) {
        malloc_printf("%s: failed to read base ptr of size %y\n", __func__, allocSize);
        *ctxt->ret = err;
        return;
    }
        
    // now run the recorder on the local copy
    vm_range_t range;
    if (ctxt->type_mask & MALLOC_ADMIN_REGION_RANGE_TYPE) {
        range.address = baseAddress;
        range.size = allocSize - ptrSize;
        ctxt->recorder(ctxt->task, ctxt->context, MALLOC_ADMIN_REGION_RANGE_TYPE, &range, 1);
    }
    if (ctxt->type_mask & (MALLOC_PTR_REGION_RANGE_TYPE | MALLOC_ADMIN_REGION_RANGE_TYPE)) {
        range.address = baseAddress;
        range.size = allocSize;
        ctxt->recorder(ctxt->task, ctxt->context, MALLOC_PTR_REGION_RANGE_TYPE, &range, 1);
    }
    if (ctxt->type_mask & MALLOC_PTR_IN_USE_RANGE_TYPE && false == isFree) {
        range.address = ptrAddress;
        range.size = ptrSize;
        ctxt->recorder(ctxt->task, ctxt->context, MALLOC_PTR_IN_USE_RANGE_TYPE, &range, 1);
    }
    
    *ctxt->ret = 0;
}

// taken directly from scalable_malloc.c; maybe used when task == mach_task_self?
static kern_return_t
__fv_zone_default_reader(task_t task, vm_address_t address, vm_size_t size, void **ptr)
{
    malloc_printf("%s\n", __func__);
    *ptr = (void *)address;
    return 0;
}

static kern_return_t 
fv_zone_enumerator(task_t task, void *context, unsigned type_mask, vm_address_t zone_address, memory_reader_t reader, vm_range_recorder_t recorder)
{
    fv_zone_assert(0 != zone_address);
    
    if (NULL == reader) reader = __fv_zone_default_reader;
    
    kern_return_t ret = 0;

    // read the zone itself first before dereferencing it
    fv_zone_t *zone;
    ret = reader(task, zone_address, sizeof(fv_zone_t), (void **)&zone);
    if (ret) return ret;
    fv_zone_assert(NULL != zone);
    
    fv_enumerator_context ctxt = { task, context, type_mask, reader, recorder, &ret };    
    fv_allocation_t **allocations;
    
    /*
     _allocPtrCount is the number of fv_allocation_t pointers that we have in _allocPtr, and we want to read all of them
     from the contiguous block in the vector.  So this will try to read allocLen * sizeof(void *).
     Since __fv_zone_enumerate_allocation also calls reader, we call it each time through the loop in case it
     becomes invalid between calls.
     */     
    
    /*
     scalable_malloc doesn't lock in szone_ptr_in_use_enumerator, so we assume this doesn't change during 
     enumeration (caller has locked the zone or paused the process)
     */
    const size_t allocationCount = zone->_allocPtrCount;
    
    for (size_t i = 0; i < allocationCount; i++) {
        
        // read all the allocation pointers into local memory
        ret = reader(task, (vm_address_t)zone->_allocPtr, allocationCount * sizeof(fv_allocation_t *), (void **)&allocations);
        if (ret) return ret;    
        
        // now read and record the next allocation
        __fv_zone_enumerate_allocation(allocations[i], &ctxt);
        if (ret) return ret;
        
        // need the zone again for _allocPtr
        ret = reader(task, zone_address, sizeof(fv_zone_t), (void **)&zone);
        if (ret) return ret;
    }

    return ret;
}

static const struct malloc_introspection_t __fv_zone_introspect = {
    fv_zone_enumerator,
    fv_zone_good_size,
    fv_zone_check,
    fv_zone_print,
    fv_zone_log,
    fv_zone_force_lock,
    fv_zone_force_unlock,
    fv_zone_statistics
};

static bool __fv_alloc_size_compare(fv_allocation_t *val1, fv_allocation_t *val2) { return (val1->ptrSize < val2->ptrSize); }

#pragma mark Setup and cleanup

#if ENABLE_STATS
static void __fv_zone_show_stats(fv_zone_t *fvzone);
#endif

static void __fv_zone_collect_zone(fv_zone_t *zone)
{
#if ENABLE_STATS
    __fv_zone_show_stats(zone);
#endif
    // read freeSize before locking, since collection isn't critical
    // if we can't lock immediately, wait for another opportunity
    if (zone->_freeSize > FV_COLLECT_THRESHOLD && TRYLOCK(zone)) {
            
        set<fv_allocation_t *>::iterator it;
        
        // clear out all of the available allocations; this could be more intelligent
        for (it = zone->_availableAllocations->begin(); it != zone->_availableAllocations->end(); it++) {
            // remove from the allocation list
            vector<fv_allocation_t *>::iterator toerase = lower_bound(zone->_allocations->begin(), zone->_allocations->end(), *it);
            fv_zone_assert(*toerase == *it);
            zone->_allocations->erase(toerase);
            
            // change the sizes in the zone's record
            fv_zone_assert(zone->_allocatedSize >= (*it)->allocSize);
            fv_zone_assert(zone->_freeSize >= (*it)->allocSize);
            zone->_allocatedSize -= (*it)->allocSize;
            zone->_freeSize -= (*it)->allocSize;
            
            // deallocate underlying storage
            __fv_zone_destroy_allocation(*it);
        } 
        
        // removal doesn't alter sort order, so no need to call sort() here
        
        // reset heap pointer and length
        zone->_allocPtr = &zone->_allocations->front();
        zone->_allocPtrCount = zone->_allocations->size();

        // now remove all blocks from the free list
        zone->_availableAllocations->clear();
        
        UNLOCK(zone);
    }
}

// periodically check all zones against the per-zone high water mark for unused memory
static void *__fv_zone_collector_thread(void *unused)
{        
    int ret = pthread_mutex_lock(&_allZonesLock);
    while (0 == ret || ETIMEDOUT == ret) {
        
        struct timeval tv;
        struct timespec ts;
        
        (void)gettimeofday(&tv, NULL);
        TIMEVAL_TO_TIMESPEC(&tv, &ts);     
        ts.tv_sec += FV_COLLECT_TIMEINTERVAL;
        
        // see http://www.opengroup.org/onlinepubs/009695399/functions/pthread_cond_timedwait.html for notes on timed wait    
        ret = pthread_cond_timedwait(&_collectorCond, &_allZonesLock, &ts);
        if (NULL != _allZones) {
            for_each(_allZones->begin(), _allZones->end(), __fv_zone_collect_zone);
        }

#if ENABLE_STATS
        (void)gettimeofday(&tv, NULL);
        TIMEVAL_TO_TIMESPEC(&tv, &ts);

        static double lastCollectSeconds = tv.tv_sec + double(tv.tv_usec) / 1000000;
        static unsigned int collectionCount = 0;
        
        collectionCount++;
        const double currentCollectSeconds = tv.tv_sec + double(tv.tv_usec) / 1000000;
        fprintf(stderr, "%s collection %u, %.2f seconds since previous\n", ETIMEDOUT == ret ? "TIMED" : "FORCED", collectionCount, currentCollectSeconds - lastCollectSeconds);
        lastCollectSeconds = currentCollectSeconds;
#endif
    }
    (void)pthread_mutex_unlock(&_allZonesLock);
    
    return NULL;
}

static void __initialize_collector_thread()
{    
    // create a thread to do periodic cleanup so memory usage doesn't get out of hand
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    
    // not required as an ivar at present
    pthread_t thread;
    (void)pthread_create(&thread, &attr, __fv_zone_collector_thread, NULL);
    pthread_attr_destroy(&attr);    
}

#pragma mark API

malloc_zone_t *fv_create_zone_named(const char *name)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __initialize_collector_thread);
    // can't rely on initializers to do this early enough, since FVAllocator creates a zone in a __constructor__
    pthread_mutex_lock(&_allZonesLock);
    // TODO: is using new okay?
    if (NULL == _allZones) _allZones = new set<fv_zone_t *>;
    if (getenv("MallocScribble") != NULL) {
        malloc_printf("will scribble memory allocations in zone %s\n", name);
        _scribble = true;
    }
    pthread_mutex_unlock(&_allZonesLock);
    
    // let calloc zero all fields
    fv_zone_t *zone = (fv_zone_t *)malloc_zone_calloc(malloc_default_zone(), 1, sizeof(fv_zone_t));
    
    zone->_basic_zone.size = fv_zone_size;
    zone->_basic_zone.malloc = fv_zone_malloc;
    zone->_basic_zone.calloc = fv_zone_calloc;
    zone->_basic_zone.valloc = fv_zone_valloc;
    zone->_basic_zone.free = fv_zone_free;
    zone->_basic_zone.realloc = fv_zone_realloc;
    zone->_basic_zone.destroy = fv_zone_destroy;
    zone->_basic_zone.batch_malloc = NULL;
    zone->_basic_zone.batch_free = NULL;
    zone->_basic_zone.introspect = (struct malloc_introspection_t *)&__fv_zone_introspect;
    zone->_basic_zone.version = 0;  /* from scalable_malloc.c in Libc-498.1.1 */
    
#if defined(MAC_OS_X_VERSION_10_6) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
    zone->_basic_zone.memalign = NULL;
    zone->_basic_zone.free_definite_size = fv_zone_free_definite;
#endif
    
    // explicitly initialize padding to NULL
    zone->_reserved[0] = NULL;
    zone->_reserved[1] = NULL;
    
    // http://www.cplusplus.com/reference/stl/set/set.html
    // proof that C++ programmers have to be insane
    bool (*compare_ptr)(ALLOC, ALLOC) = __fv_alloc_size_compare;
    zone->_availableAllocations = new multiset<MSALLOC>(compare_ptr);
    zone->_allocations = new vector<ALLOC>;
    LOCK_INIT(zone);
    
    // register so the system handles lookups correctly, or malloc_zone_from_ptr() breaks (along with free())
    malloc_zone_register((malloc_zone_t *)zone);
    
    // malloc_set_zone_name calls out to this zone, so call it after setup is complete
    malloc_set_zone_name(&zone->_basic_zone, name);
    
    // register for timer
    pthread_mutex_lock(&_allZonesLock);
    _allZones->insert(zone);
    pthread_mutex_unlock(&_allZonesLock);
    
    return (malloc_zone_t *)zone;
}

#pragma mark statistics

#if ENABLE_STATS

static multiset<size_t> __fv_zone_free_sizes_locked(fv_zone_t *fvzone, size_t *freeMemPtr)
{
    size_t freeMemory = 0;
    multiset<size_t> allocationSet;
    set<fv_allocation_t *>::iterator it;
    for (it = fvzone->_availableAllocations->begin(); it != fvzone->_availableAllocations->end(); it++) {
        fv_allocation_t *alloc = *it;
        if (__builtin_expect((alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard), 0)) {
            malloc_printf("%s: invalid allocation pointer %p\n", __func__, alloc);
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
        // FIXME: consistent size usage
        freeMemory += alloc->allocSize;
        allocationSet.insert(alloc->ptrSize);
    } 
    if (freeMemPtr) *freeMemPtr = freeMemory;
    fv_zone_assert(freeMemory == fvzone->_freeSize);
    return allocationSet;
}

static multiset<size_t> __fv_zone_all_sizes_locked(fv_zone_t *fvzone, size_t *totalMemPtr)
{
    size_t totalMemory = 0;
    multiset<size_t> allocationSet;
    vector<fv_allocation_t *>::iterator it;
    for (it = fvzone->_allocations->begin(); it != fvzone->_allocations->end(); it++) {
        fv_allocation_t *alloc = *it;
        if (__builtin_expect((alloc->guard != &_vm_guard && alloc->guard != &_malloc_guard), 0)) {
            malloc_printf("%s: invalid allocation pointer %p\n", __func__, alloc);
            malloc_printf("Break on malloc_printf to debug.\n");
            HALT;
        }
        // FIXME: consistent size usage
        totalMemory += alloc->allocSize;
        allocationSet.insert(alloc->ptrSize);
    } 
    fv_zone_assert(totalMemory == fvzone->_allocatedSize);
    if (totalMemPtr) *totalMemPtr = totalMemory;
    return allocationSet;
}

static map<size_t, double> __fv_zone_average_usage(fv_zone_t *zone)
{
    map<size_t, double> map;
    LOCK(zone);
    vector<fv_allocation_t *> vec(zone->_allocations->begin(), zone->_allocations->end());
    if (vec.size()) {
        sort(vec.begin(), vec.end(), __fv_alloc_size_compare);
        vector<fv_allocation_t *>::iterator it;
        vector<size_t> count;
        size_t prev = vec[0]->ptrSize;
        // average the usage count of each size class
        for (it = vec.begin(); it != vec.end(); it++) {
            
            if ((*it)->ptrSize != prev) {
                double average = 0;
                vector<size_t>::iterator ait;
                for (ait = count.begin(); ait != count.end(); ait++)
                    average += *ait;
                if (count.size() > 1)
                    average = average / count.size();
                count.clear();
                map[prev] = average;
                prev = (*it)->ptrSize;
            }
            count.push_back((*it)->timesUsed);
        }
        // get the last one...
        if (count.size()) {
            double average = 0;
            vector<size_t>::iterator ait;
            for (ait = count.begin(); ait != count.end(); ait++)
                average += *ait;
            if (count.size() > 1)
                average = average / count.size();
            count.clear();
            map[prev] = average;
        }
    }
    UNLOCK(zone);
    return map;
}

// can't make this public, since it relies on the argument being an fv_zone_t (which must not be exposed)
static void __fv_zone_show_stats(fv_zone_t *fvzone)
{
    // record the actual time of this measurement
    const time_t absoluteTime = time(NULL);
    size_t totalMemory = 0, freeMemory = 0;
    
    LOCK(fvzone);
    multiset<size_t> allocationSet = __fv_zone_all_sizes_locked(fvzone, &totalMemory);
    multiset<size_t> freeSet = __fv_zone_free_sizes_locked(fvzone, &freeMemory);
    UNLOCK(fvzone);

    map<size_t, double> usageMap = __fv_zone_average_usage(fvzone);

    fprintf(stderr, "------------------------------------\n");
    fprintf(stderr, "Zone name: %s\n", malloc_get_zone_name(&fvzone->_basic_zone));
    fprintf(stderr, "   Size     Count(Free)  Total  Percentage     Reuse\n");
    fprintf(stderr, "   (b)       --    --    (Mb)      ----         --- \n");
    
    const double totalMemoryMbytes = (double)totalMemory / 1024 / 1024;
    multiset<size_t>::iterator it;
    for (it = allocationSet.begin(); it != allocationSet.end(); it = allocationSet.upper_bound(*it)) {
        size_t allocationSize = *it;
        size_t count = allocationSet.count(allocationSize);
        size_t freeCount = freeSet.count(allocationSize);
        double totalMbytes = double(allocationSize) * count / 1024 / 1024;
        double percentOfTotal = totalMbytes / totalMemoryMbytes * 100;
        double averageUsage = 0;
        map<size_t, double>::iterator usageIterator = usageMap.find(allocationSize);
        averageUsage = usageIterator == usageMap.end() ? nan("") : usageIterator->second;
        
        fprintf(stderr, "%8lu    %3lu  (%3lu)  %5.2f    %5.2f %%  %12.0f\n", (long)allocationSize, (long)count, (long)freeCount, totalMbytes, percentOfTotal, averageUsage);        
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
    fprintf(stderr, "%s: total in use: %.2f Mbytes, total available: %.2f Mbytes, %d reallocations\n", timeString, double(totalMemory) / 1024 / 1024, double(freeMemory) / 1024 / 1024, fvzone->_reallocCount);
}

#endif

