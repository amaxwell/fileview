//
//  FVImageBuffer.m
//  FileView
//
//  Created by Adam Maxwell on 3/15/08.
/*
 This software is Copyright (c) 2008-2010
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

#if __LP64__
static volatile uint64_t _allocatedBytes = 0;
#else
static volatile uint32_t _allocatedBytes = 0;
#endif

@implementation FVImageBuffer

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
            bool swap;
#if __LP64__
            do {
                swap = OSAtomicCompareAndSwap64Barrier(_allocatedBytes, _allocatedBytes + _bufferSize, (int64_t *)&_allocatedBytes);
            } while (false == swap);
#else
            do {
                swap = OSAtomicCompareAndSwap32Barrier(_allocatedBytes, _allocatedBytes + _bufferSize, (int32_t *)&_allocatedBytes);
            } while (false == swap);    
#endif
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
    bool swap;
#if __LP64__
    do {
        swap = OSAtomicCompareAndSwap64Barrier(_allocatedBytes, _allocatedBytes - _bufferSize, (int64_t *)&_allocatedBytes);
    } while (false == swap);
#else
    do {
        swap = OSAtomicCompareAndSwap32Barrier(_allocatedBytes, _allocatedBytes - _bufferSize, (int32_t *)&_allocatedBytes);
    } while (false == swap);    
#endif
    NSZoneFree([self zone], buffer);
    [super dealloc];
}

- (void)setFreeBufferOnDealloc:(BOOL)flag;
{
    _freeBufferOnDealloc = flag;
}

- (CFAllocatorRef)allocator { return FVAllocatorGetDefault(); }

- (size_t)bufferSize { return _bufferSize; }

@end
