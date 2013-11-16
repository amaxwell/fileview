//
//  FVImageBuffer.h
//  FileView
//
//  Created by Adam Maxwell on 3/15/08.
/*
 This software is Copyright (c) 2008-2013
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

/** @internal 
 
 @brief Wrapper around vImage_Buffer.
 
 FVImageBuffer provides a Cocoa object wrapper around a vImage_Buffer structure.  It uses a custom allocator to track memory allocations, and can report the number of bytes allocated for all threads.
 
 FVImageBuffer can also be set to not free its underlying vImage_Buffer data pointer in dealloc, which allows transfer of ownership of the raw byte pointer to another object without copying.  This data pointer will have been allocated using the CFAllocator returned by FVImageBuffer::allocator, so CFDataCreateWithBytesNoCopy() should be passed this allocator in order to ensure proper cleanup.
 
 @warning FVImageBuffer is designed for usage with FVCGImageUtilities.h functions and should not be used elsewhere as-is.  FVImageBuffer instances must not be shared between threads unless protected by a mutex.
 
 */
@interface FVImageBuffer : NSObject <NSCopying>
{
@public;
    vImage_Buffer *buffer;
@private;
    size_t        _bufferSize;          // totally unrelated to image size; only for debugging or assertions
    BOOL          _freeBufferOnDealloc; 
}

/** @internal 
 
 @brief Allocator memory usage.
 
 FVImageBuffer instances are excluded from this statistic if FVImageBuffer:setFreeBufferOnDealloc: has been called with @code YES @endcode as the parameter.
 @return The number of bytes in use by FVImageBuffer instances. */
+ (uint64_t)allocatedBytes;

/** @internal 
 
 @brief Raises an exception.
 
 Callers must pass an explicit size.
 @return An initialized buffer instance. */
- (id)init;

/** @internal 
 
 @brief Designated initializer.
 
 Initializes a new buffer with the specified width, height, and bytes per row.
 @param w Width in pixels.
 @param h Height in pixels.
 @param r Bytes per row.  
 @return An initialized buffer instance. */
- (id)initWithWidth:(size_t)w height:(size_t)h rowBytes:(size_t)r;

/** @internal 
 
 @brief Convenience initializer.
 Computes row bytes using FVBitmapContext.h::FVPaddedRowBytesForWidth(@a bps, @a w).
 @param w Width in pixels.
 @param h Height in pixels.
 @param bps Bytes per sample (4 for an 8-bit ARGB image).
 @return An initialized buffer instance. */
- (id)initWithWidth:(size_t)w height:(size_t)h bytesPerSample:(size_t)bps;

/** @internal 
 
 @brief Byte buffer transfer.
 Pass NO to transfer ownership of the vImage data to e.g. CFData.  This is always set to YES for new instances.
 @param flag NO to allow another object to free the underlying vImage_Buffer data. */
- (void)setFreeBufferOnDealloc:(BOOL)flag;

/** @internal 
 
 @brief FVImageBuffer allocator.
 
 If you set _freeBufferOnDealloc to NO, use this allocator to free buffer->data when you're finished with it.  Do not rely on this returning the same allocator for all instances.
 @return A CFAllocator instance. */
- (CFAllocatorRef)allocator;

/** @internal 
 
 @brief Internal buffer size.
 
 Use for debugging and asserting.  In case of reshaping the underlying buffer, this preserves the original size.  If you change the data pointer in the buffer and then call this, you'll get what you deserve. */
- (size_t)bufferSize;

@end
