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
    size_t  size;
    void   *ptr;
} fv_alloc_info_t;

// single instance of this allocator
static CFAllocatorRef     _allocator = NULL;

// map with pointer from malloc as key, and fv_alloc_info_t* as value
static NSMapTable        *_pointerTable = NULL;
static OSSpinLock         _pointerTableLock = OS_SPINLOCK_INIT;

// array of buffers that are currently free (have been deallocated)
static CFMutableArrayRef  _freeBuffers = NULL;
static OSSpinLock         _freeBufferLock = OS_SPINLOCK_INIT;

#define FV_VM_THRESHOLD 16384UL

static CFComparisonResult __FVAllocInfoComparator(const void *val1, const void *val2, void *context)
{
    const size_t size1 = ((fv_alloc_info_t *)val1)->size;
    const size_t size2 = ((fv_alloc_info_t *)val2)->size;
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
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<0x%x>,\t size = %d"), info->ptr, info->size);
}

// returns kCFNotFound if no buffer of sufficient size exists
static CFIndex __FVAllocatorGetIndexOfAllocationGreaterThan(const CFIndex allocSize)
{
    NSCParameterAssert(OSSpinLockTry(&_freeBufferLock) == false);
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    // need a temporary struct for comparison
    const fv_alloc_info_t tempInfo = { allocSize, NULL };
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

#pragma mark CFAllocatorContext functions

static CFStringRef __FVAllocatorCopyDescription(const void *info)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("FVAllocator <%p>"), _allocator);
}

static void *__FVAllocateFromSystem(const size_t requestedSize, size_t *actualSize)
{
    void *ptr;
    // allocations going through this allocator should generally larger than 4K
    if (__builtin_expect(requestedSize >= FV_VM_THRESHOLD, 1)) {
        kern_return_t ret;
        *actualSize = round_page(requestedSize);
        ret = vm_allocate(mach_task_self(), (vm_address_t *)&ptr, *actualSize, VM_FLAGS_ANYWHERE);
        if (0 != ret) ptr = NULL;
    }
    else {
        ptr = malloc_zone_malloc(malloc_default_zone(), requestedSize);
        *actualSize = requestedSize;
    }
    return ptr;
}

// return an available buffer of sufficient size or create a new one
static void * __FVAllocate(CFIndex allocSize, CFOptionFlags hint, void *info)
{
    // !!! unlock on each if branch
    OSSpinLockLock(&_freeBufferLock);
    CFIndex idx = __FVAllocatorGetIndexOfAllocationGreaterThan(allocSize);
    void *ptr = NULL;
    if (__builtin_expect(kCFNotFound == idx, 0)) {
        // nothing found; unlock immediately
        OSSpinLockUnlock(&_freeBufferLock);
        fv_alloc_info_t *allocInfo = malloc_zone_calloc(malloc_default_zone(), 1, sizeof(fv_alloc_info_t));
        // may round up to page size, so pass a pointer to allocInfo's size field
        ptr = __FVAllocateFromSystem(allocSize, &allocInfo->size);
        allocInfo->ptr = ptr;
        if (__builtin_expect(NULL != ptr, 1)) {
            OSSpinLockLock(&_pointerTableLock);
            NSMapInsertKnownAbsent(_pointerTable, ptr, allocInfo);
            OSSpinLockUnlock(&_pointerTableLock);
        }
    }
    else {
        const fv_alloc_info_t *allocInfo = CFArrayGetValueAtIndex(_freeBuffers, idx);
        CFArrayRemoveValueAtIndex(_freeBuffers, idx);
        OSSpinLockUnlock(&_freeBufferLock);
        if (__builtin_expect((size_t)allocSize > allocInfo->size, 0)) HALT;
        ptr = allocInfo->ptr;
    }
    return ptr;
}

static void __FVDeallocate(void *ptr, void *info)
{
    // no one should be trying to realloc during dealloc, so don't hold the lock
    OSSpinLockLock(&_pointerTableLock);
    const fv_alloc_info_t *allocInfo = NSMapGet(_pointerTable, ptr);
    OSSpinLockUnlock(&_pointerTableLock);
    if (__builtin_expect(NULL == allocInfo, 0)) HALT;
    // add to free list
    OSSpinLockLock(&_freeBufferLock);
    CFIndex idx = __FVAllocatorGetInsertionIndexForAllocation(allocInfo);
    CFArrayInsertValueAtIndex(_freeBuffers, idx, allocInfo);
    OSSpinLockUnlock(&_freeBufferLock);
}

static void * __FVReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    // get a new buffer, copy contents, return ptr to the pool
    void *newPtr = __FVAllocate(newSize, hint, info);
    OSSpinLockLock(&_pointerTableLock);
    const fv_alloc_info_t *allocInfo = NSMapGet(_pointerTable, ptr);
    OSSpinLockUnlock(&_pointerTableLock);
    if (__builtin_expect(NULL == allocInfo, 0)) HALT;
    memcpy(newPtr, ptr, allocInfo->size);
    __FVDeallocate(ptr, info);
    return newPtr;
}

static CFIndex __FVPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    size_t allocSize = size;
    return allocSize >= FV_VM_THRESHOLD ? round_page(allocSize) : allocSize;
}

__attribute__ ((constructor))
static void __initialize_allocator()
{  
    _pointerTable = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks, NSNonOwnedPointerMapValueCallBacks, 256);
    const CFArrayCallBacks cb = { 0, NULL, NULL, __FVAllocInfoCopyDescription, NULL };
    _freeBuffers = CFArrayCreateMutable(NULL, 0, &cb);
    
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
