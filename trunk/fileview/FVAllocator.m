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


@interface FVCacheBuffer : FVObject
{
@public
    size_t  size;
    void   *ptr;
}
@end

static CFAllocatorRef _allocator = NULL;
static OSSpinLock _pointerTableLock = OS_SPINLOCK_INIT;
static CFMutableDictionaryRef _pointerTable = NULL;
static CFMutableArrayRef _freeBuffers = NULL;
static OSSpinLock _freeBufferLock = OS_SPINLOCK_INIT;

static CFComparisonResult __FVBufferSizeComparator(const void *val1, const void *val2, void *context)
{
    const size_t size1 = ((FVCacheBuffer *)val1)->size;
    const size_t size2 = ((FVCacheBuffer *)val2)->size;
    if (size1 > size2)
        return kCFCompareGreaterThan;
    else if (size2 < size1)
        return kCFCompareLessThan;
    else
        return kCFCompareEqualTo;
}

static CFStringRef FVAllocatorCopyDescription(const void *info)
{
    return (CFStringRef)[[NSString alloc] initWithFormat:@"FVCacheFileAllocator <%p>", _allocator];
}

static void * FVAllocate(CFIndex allocSize, CFOptionFlags hint, void *info)
{
    // check for available buffer of sufficient size and return
    OSSpinLockLock(&_freeBufferLock);
    CFRange range = CFRangeMake(0, CFArrayGetCount(_freeBuffers));
    CFArraySortValues(_freeBuffers, range, __FVBufferSizeComparator, NULL);
    FVCacheBuffer *buffer = [FVCacheBuffer new];
    buffer->size = allocSize;
    CFIndex idx = CFArrayBSearchValues(_freeBuffers, range, buffer, __FVBufferSizeComparator, NULL);
    
    void *ptr = NULL;
    if (idx >= range.length) {
        ptr = NSZoneMalloc(NSDefaultMallocZone(), allocSize);
        buffer->ptr = ptr;
        OSSpinLockLock(&_pointerTableLock);
        CFDictionaryAddValue(_pointerTable, ptr, (const void *)buffer);
        OSSpinLockUnlock(&_pointerTableLock);
    }
    else {
        FVCacheBuffer *prev = (id)CFArrayGetValueAtIndex(_freeBuffers, idx);
        CFArrayRemoveValueAtIndex(_freeBuffers, idx);
        ptr = prev->ptr;
    }
    OSSpinLockUnlock(&_freeBufferLock);
    [buffer release];
    return ptr;
}

static void * FVReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    // could possibly optimize by returning ptr to the pool and getting a new buffer, then copying contents
    void *newPtr = NSZoneRealloc(NSZoneFromPointer(ptr), ptr, newSize);
    FVCacheBuffer *buffer;
    if (CFDictionaryGetValueIfPresent(_pointerTable, ptr, (const void **)&buffer)) {
        buffer->size = newSize;
        buffer->ptr = newPtr;
        // remove ptr from table and add newPtr as key
        OSSpinLockLock(&_pointerTableLock);
        CFDictionaryRemoveValue(_pointerTable, ptr);
        CFDictionaryAddValue(_pointerTable, newPtr, buffer);
        OSSpinLockUnlock(&_pointerTableLock);
    }
    else {
        abort();
    }
    return newPtr;
}

static void FVDeallocate(void *ptr, void *info)
{
    OSSpinLockLock(&_pointerTableLock);
    FVCacheBuffer *buffer;
    if (CFDictionaryGetValueIfPresent(_pointerTable, ptr, (const void **)&buffer)) {
        // add to free list
        OSSpinLockLock(&_freeBufferLock);
        CFArrayAppendValue(_freeBuffers, buffer);
        OSSpinLockUnlock(&_freeBufferLock);
    }
    OSSpinLockUnlock(&_pointerTableLock);
}

static CFIndex FVPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    return size;
}

@implementation FVCacheBuffer

@end

__attribute__ ((constructor))
static void __initialize_allocator()
{    
    // create before _allocator
    _pointerTable = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);    
    _freeBuffers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    
    CFAllocatorContext context = { 
        0, 
        NULL, 
        NULL, 
        NULL, 
        FVAllocatorCopyDescription, 
        FVAllocate, 
        FVReallocate, 
        FVDeallocate, 
        FVPreferredSize 
    };
    _allocator = CFAllocatorCreate(kCFAllocatorUseContext, &context);
}

CFAllocatorRef FVAllocatorGetDefault() 
{ 
    return _allocator; 
}
