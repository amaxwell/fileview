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
#import <libkern/OSAtomic.h>
#import "FVObject.h"
#import "FVUtilities.h"

typedef struct _fv_alloc_info_t {
    size_t  size;
    void   *ptr;
} fv_alloc_info_t;

static CFAllocatorRef _allocator = NULL;
static OSSpinLock _pointerTableLock = OS_SPINLOCK_INIT;
static NSMapTable *_pointerTable = NULL;
static CFMutableArrayRef _freeBuffers = NULL;
static OSSpinLock _freeBufferLock = OS_SPINLOCK_INIT;

static CFComparisonResult __FVBufferSizeComparator(const void *val1, const void *val2, void *context)
{
    const size_t size1 = ((fv_alloc_info_t *)val1)->size;
    const size_t size2 = ((fv_alloc_info_t *)val2)->size;
    if (size1 > size2)
        return kCFCompareGreaterThan;
    else if (size2 < size1)
        return kCFCompareLessThan;
    else
        return kCFCompareEqualTo;
}

static CFStringRef __FVAllocatorCopyDescription(const void *info)
{
    return (CFStringRef)[[NSString alloc] initWithFormat:@"FVCacheFileAllocator <%p>", _allocator];
}

static void * __FVAllocate(CFIndex allocSize, CFOptionFlags hint, void *info)
{
    // check for available buffer of sufficient size and return
    OSSpinLockLock(&_freeBufferLock);
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    CFArraySortValues(_freeBuffers, range, __FVBufferSizeComparator, NULL);
    fv_alloc_info_t tempInfo;
    tempInfo.size = allocSize;
    CFIndex idx = CFArrayBSearchValues(_freeBuffers, range, &tempInfo, __FVBufferSizeComparator, NULL);
    
    void *ptr = NULL;
    if (idx >= range.length) {
        fv_alloc_info_t *allocInfo = NSZoneMalloc(NSDefaultMallocZone(), sizeof(fv_alloc_info_t));
        ptr = NSZoneMalloc(NSDefaultMallocZone(), allocSize);
        allocInfo->ptr = ptr;
        allocInfo->size = allocSize;
        OSSpinLockLock(&_pointerTableLock);
        NSMapInsertKnownAbsent(_pointerTable, ptr, allocInfo);
        OSSpinLockUnlock(&_pointerTableLock);
    }
    else {
        const fv_alloc_info_t *allocInfo = CFArrayGetValueAtIndex(_freeBuffers, idx);
        CFArrayRemoveValueAtIndex(_freeBuffers, idx);
        ptr = allocInfo->ptr;
    }
    OSSpinLockUnlock(&_freeBufferLock);
    return ptr;
}

static void * __FVReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    // could possibly optimize by returning ptr to the pool and getting a new buffer, then copying contents
    void *newPtr = NSZoneRealloc(NSZoneFromPointer(ptr), ptr, newSize);
    OSSpinLockLock(&_pointerTableLock);
    fv_alloc_info_t *allocInfo = NSMapGet(_pointerTable, ptr);
    if (NULL == allocInfo) HALT;
    allocInfo->size = newSize;
    allocInfo->ptr = newPtr;
    // remove ptr from table and add newPtr as key
    NSMapRemove(_pointerTable, ptr);
    NSMapInsertKnownAbsent(_pointerTable, ptr, allocInfo);
    OSSpinLockUnlock(&_pointerTableLock);
    return newPtr;
}

static void __FVDeallocate(void *ptr, void *info)
{
    // no one should be trying to realloc during dealloc, so don't hold the lock
    OSSpinLockLock(&_pointerTableLock);
    const fv_alloc_info_t *allocInfo = NSMapGet(_pointerTable, ptr);
    OSSpinLockUnlock(&_pointerTableLock);
    if (NULL == allocInfo) HALT;
    // add to free list
    OSSpinLockLock(&_freeBufferLock);
    CFArrayAppendValue(_freeBuffers, allocInfo);
    OSSpinLockUnlock(&_freeBufferLock);
}

static CFIndex __FVPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    return size;
}

__attribute__ ((constructor))
static void __initialize_allocator()
{    
    // create before _allocator
    _pointerTable = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks, NSNonOwnedPointerMapValueCallBacks, 256);
    _freeBuffers = CFArrayCreateMutable(NULL, 0, NULL);
    
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
    _allocator = CFAllocatorCreate(kCFAllocatorUseContext, &context);
}

CFAllocatorRef FVAllocatorGetDefault() 
{ 
    return _allocator; 
}
