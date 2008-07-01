//
//  FVImageBuffer.h
//  FileView
//
//  Created by Adam Maxwell on 3/15/08.
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

#import <Cocoa/Cocoa.h>
#import <Accelerate/Accelerate.h>

@interface FVImageBuffer : NSObject <NSCopying>
{
@public;
    vImage_Buffer *buffer;
@private;
    size_t        _bufferSize;          // totally unrelated to image size; only for debugging or assertions
    BOOL          _freeBufferOnDealloc; 
}

+ (uint64_t)allocatedBytes;

// Returns a planar buffer of appropriate size for tiling (__FVMaximumTileWidth() x __FVMaximumTileHeight()).
- (id)init;

// Returns a cached buffer of the same size as that returned by -init; use -dispose /instead/ of -release, since this returns a cached instance.
+ (id)new;

// Return a buffer of the default size, with each side multiplied by scale.  If you create a buffer with newPlanarBufferWithScale, you must call -dispose on it /instead/ of -release, since this may return a cached instance.
+ (id)newPlanarBufferWithScale:(double)scale;

// Equivalent to -release for non-cached objects.  May be used as a replacement for release, and must be used if you use +new... methods.
- (oneway void)dispose;

// Designated initializer.
- (id)initWithWidth:(size_t)w height:(size_t)h rowBytes:(size_t)r;

// Computes row bytes using FVPaddedRowBytesForWidth(bps, w).
- (id)initWithWidth:(size_t)w height:(size_t)h bytesPerSample:(size_t)bps;

// Defaults to YES; set to NO to transfer ownership of the vImage data to CFData, and free it with -allocator.
- (void)setFreeBufferOnDealloc:(BOOL)flag;

// If you set _freeBufferOnDealloc to NO, use this allocator to free buffer->data when you're finished with it.
- (CFAllocatorRef)allocator;

@end
