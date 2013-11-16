//
//  FVBitmapContextCache.h
//  FileView
//
//  Created by Adam Maxwell on 10/21/07.
/*
 This software is Copyright (c) 2007-2013
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

#ifndef _FVBITMAPCONTEXT_H_
#define _FVBITMAPCONTEXT_H_

#import <Cocoa/Cocoa.h>
#import "FVObject.h"

__BEGIN_DECLS

/** @internal 
 
 @brief Wrapper around a CGBitmapContext.
 
 FVBitmapContext is a simple wrapper around a bitmap-based graphics context, and provides Core Graphics and Cocoa graphics contexts.  Memory for the bitmap data may not be allocated in the default zone or the object's zone, and is considered to be owned by the FVBitmapContext.  Consequently, do not attempt to access the CGContext's bitmap data after the FVBitmapContext is deallocated.  Likewise, retaining any of the graphics contexts returned from an instance and using them after it has been deallocated is a programmer error.
 
 The underlying CGContext is guaranteed to be compatible with caching and scaling methods used elsewhere in the framework (correct colorspace, pixel format, and size).
 
 @warning FVBitmapContext instances should not be shared between threads unless protected by a mutex.
 
 */

@interface FVBitmapContext : FVObject
{
@private
    CGContextRef       _port;
    NSGraphicsContext *_flipped;
    NSGraphicsContext *_context;
}

/** @internal 
 
 @brief Convenience initializer.
 
 This is the only public API for creating an FVBitmapContext.
 
 @param pixelSize Height and width in pixels.  Floating point values will be truncated.
 @return An autoreleased instance of a new FVBitmapContext. */
+ (FVBitmapContext *)bitmapContextWithSize:(NSSize)pixelSize;

/** @internal 
 
 @brief Core Graphics context.
 
 @return CGContext owned by FVBitmapContext. */
- (CGContextRef)graphicsPort;

/** @internal 
 
 @brief Unflipped Cocoa graphics context.
 
 Lazily instantiates a new NSGraphicsContext from FVBitmapContext::graphicsPort. 
 @return Unflipped NSGraphicsContext owned by FVBitmapContext. */
- (NSGraphicsContext *)graphicsContext;

/** @internal 
 
 @brief Flipped Cocoa graphics context.
 
 Lazily instantiates a new NSGraphicsContext from FVBitmapContext::graphicsPort. 
 @return Flipped NSGraphicsContext owned by FVBitmapContext. */
- (NSGraphicsContext *)flippedGraphicsContext;

@end

/** @file FVBitmapContext.h  Bitmap context creation and disposal. */

/** @internal 
 
 @brief Row bytes for pixel width.
 
 Computes the appropriate number of bytes per row for 64-byte alignment.  Algorithm borrowed from Apple's sample code.
 @param bytesPerSample Bytes per pixel (e.g. an 8-bits-per-channel ARGB image has 32 bits per pixel, so uses 4 bytes per pixel).
 @param pixelsWide Width of the image in pixels.
 @return Number of bytes to allocate per row. */
FV_PRIVATE_EXTERN size_t FVPaddedRowBytesForWidth(const size_t bytesPerSample, const size_t pixelsWide) FV_HIDDEN;

/** @internal 
 
 @brief See if an image is compatible with caching assumptions.
 
 If this returns false, the image should be redrawn into a bitmap context created with FVBitmapContext::bitmapContextWithSize:, and CGBitmapContextCreateImage() should be used to create a new CGImage that can be cached.
 @return true if the image does not need to be redrawn. 
 @todo Move this elsewhere. */
FV_PRIVATE_EXTERN bool FVImageIsIncompatible(CGImageRef image) FV_HIDDEN;

__END_DECLS

#endif /* _FVBITMAPCONTEXT_H_ */
