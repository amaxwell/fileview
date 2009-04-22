//
//  FVImageBuffer.m
//  FileView
//
//  Created by Adam Maxwell on 3/15/08.
/*
 This software is Copyright (c) 2008-2009
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

#import "FVImageBuffer.h"
#import "FVUtilities.h"
#import "FVCGImageUtilities.h"
#import <libkern/OSAtomic.h>
#import "FVBitmapContext.h"
#import "FVAllocator.h"


static CFAllocatorRef _allocator = NULL;

static OSSpinLock _monitorLock = OS_SPINLOCK_INIT;
static CFMutableDictionaryRef _monitoredPointers = NULL;

static int64_t _allocatedBytes = 0;

static CFStringRef FVImageAllocatorCopyDescription(const void *info)
{
    return (CFStringRef)[[NSString alloc] initWithFormat:@"FVImageBufferAllocator <%p>", _allocator];
}

static void * FVImageBufferAllocate(CFIndex allocSize, CFOptionFlags hint, void *info)
{
    void *ptr = CFAllocatorAllocate(FVAllocatorGetDefault(), allocSize, hint);
    OSSpinLockLock(&_monitorLock);
    _allocatedBytes += allocSize;
    CFDictionaryAddValue(_monitoredPointers, ptr, (void *)allocSize);
    OSSpinLockUnlock(&_monitorLock);
    return ptr;
}

static void * FVImageBufferReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    OSSpinLockLock(&_monitorLock);
    NSInteger oldSize;
    if (FVCFDictionaryGetIntegerIfPresent(_monitoredPointers, ptr, &oldSize))
        CFDictionaryRemoveValue(_monitoredPointers, ptr);
    else
        oldSize = 0;
    ptr = CFAllocatorReallocate(FVAllocatorGetDefault(), ptr, newSize, hint);
    _allocatedBytes += (newSize - oldSize);
    CFDictionaryAddValue(_monitoredPointers, ptr, (void *)newSize);
    OSSpinLockUnlock(&_monitorLock);
    return ptr;
}

static void FVImageBufferDeallocate(void *ptr, void *info)
{
    OSSpinLockLock(&_monitorLock);
    NSInteger oldSize;
    if (FVCFDictionaryGetIntegerIfPresent(_monitoredPointers, ptr, &oldSize)) {
        CFDictionaryRemoveValue(_monitoredPointers, ptr);
        _allocatedBytes -= oldSize;
    }
    OSSpinLockUnlock(&_monitorLock);
    CFAllocatorDeallocate(FVAllocatorGetDefault(), ptr);
}

static CFIndex FVImageBufferPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    return FVPaddedRowBytesForWidth(1, size);
}

@implementation FVImageBuffer

+ (void)initialize
{
    FVINITIALIZE(FVImageBuffer);

    // create before _allocator
    _monitoredPointers = CFDictionaryCreateMutable(NULL, 0, NULL, &FVIntegerValueDictionaryCallBacks);

    CFAllocatorContext context = { 
        0, 
        NULL, 
        NULL, 
        NULL, 
        FVImageAllocatorCopyDescription, 
        FVImageBufferAllocate, 
        FVImageBufferReallocate, 
        FVImageBufferDeallocate, 
        FVImageBufferPreferredSize 
    };
    _allocator = CFAllocatorCreate(kCFAllocatorUseContext, &context);
}

+ (uint64_t)allocatedBytes
{
    return _allocatedBytes;
}

- (id)init
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

// safe initializer for copy, in case there's a mismatch between width/height/rowBytes
- (id)_initWithBufferSize:(size_t)bufferSize
{
    self = [super init];
    if (self) {
        buffer = NSZoneMalloc([self zone], sizeof(vImage_Buffer));
        if (NULL == buffer) {
            [super dealloc];
            self = nil;
        }
        else {
            buffer->width = bufferSize;
            buffer->height = 1;
            buffer->rowBytes = bufferSize;
            _bufferSize = bufferSize;
            buffer->data = CFAllocatorAllocate([self allocator], bufferSize, 0);
            _freeBufferOnDealloc = YES;
            if (NULL == buffer->data) {
                NSZoneFree([self zone], buffer);
                [super dealloc];
                self = nil;
            }
        }
    }
    return self;
}

- (id)initWithWidth:(size_t)w height:(size_t)h rowBytes:(size_t)r;
{
    self = [self _initWithBufferSize:(r * h)];
    if (self) {
        buffer->width = w;
        buffer->height = h;
        buffer->rowBytes = r;
    }
    return self;    
}

- (id)initWithWidth:(size_t)w height:(size_t)h bytesPerSample:(size_t)bps;
{
    return [self initWithWidth:w height:h rowBytes:FVPaddedRowBytesForWidth(bps, w)];
}

- (id)copyWithZone:(NSZone *)aZone
{
    FVImageBuffer *copy = [[[self class] allocWithZone:aZone] _initWithBufferSize:_bufferSize];
    copy->_freeBufferOnDealloc = _freeBufferOnDealloc;
    copy->buffer->rowBytes = buffer->rowBytes;
    copy->buffer->height = buffer->height;
    copy->buffer->width = buffer->width;
    if (nil != copy) memcpy(copy->buffer->data, buffer->data, copy->_bufferSize);
    return copy;
}

- (void)dealloc
{
    if (_freeBufferOnDealloc) CFAllocatorDeallocate([self allocator], buffer->data);
    NSZoneFree([self zone], buffer);
    [super dealloc];
}

- (void)setFreeBufferOnDealloc:(BOOL)flag;
{
    if (NO == flag) {
        OSSpinLockLock(&_monitorLock);
        NSInteger oldSize;
        if (FVCFDictionaryGetIntegerIfPresent(_monitoredPointers, self->buffer->data, &oldSize)) {
            CFDictionaryRemoveValue(_monitoredPointers, self->buffer->data);
            _allocatedBytes -= oldSize;
        }
        OSSpinLockUnlock(&_monitorLock);
    }
    _freeBufferOnDealloc = flag;
}

- (CFAllocatorRef)allocator { return _allocator; }

- (size_t)bufferSize { return _bufferSize; }

@end
