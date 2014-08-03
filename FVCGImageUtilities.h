//
//  FVCGImageUtilities.h
//  FileView
//
//  Created by Adam Maxwell on 3/8/08.
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

#ifndef _FVCGIMAGEUTILITIES_H_
#define _FVCGIMAGEUTILITIES_H_

#import <Cocoa/Cocoa.h>

__BEGIN_DECLS

/** @file FVCGImageUtilities.h  Manipulate CGImages. */

/** @internal 
 
 @brief Get image size in pixels.
 @return CGImage size in pixels. */
FV_PRIVATE_EXTERN NSSize FVCGImageSize(CGImageRef image);

/** @internal 
 
 @brief Resample an image.
 
 This function is used for resampling CGImages or converting an image to be compatible with cache limitations (if it uses the wrong colorspace, for instance).  Tiling and scaling are performed using vImage, which may give unacceptable results at very small scale levels due to limitations in the tiling scheme.  However, it should be more memory-efficient than using FVCGCreateResampledImageOfSize.  Images returned are always host-order 8-bit with alpha channel.
 @param image The CGImage to scale (source image).
 @param desiredSize The final size in pixels.
 @return A new CGImage or NULL if it could not be scaled. */
FV_PRIVATE_EXTERN CGImageRef FVCreateResampledImageOfSize(CGImageRef image, const NSSize desiredSize);

/** @internal 
 
 @brief Resample an image.
 
 This function is used for resampling CGImages or converting an image to be compatible with cache limitations (if it uses the wrong colorspace, for instance).  The image is redrawn into a new CGBitmapContext, and any scaling is performed by CoreGraphics.  Images returned are always host-order 8-bit with alpha channel.
 @warning This function can be memory-intensive.
 @param image The CGImage to scale (source image).
 @param desiredSize The final size in pixels.
 @return A new CGImage or NULL if it could not be scaled. */
FV_PRIVATE_EXTERN CGImageRef FVCGCreateResampledImageOfSize(CGImageRef image, const NSSize desiredSize);

/** @internal 
 
 @brief Return pointer to bitmap storage.
 
 @todo What length is returned for float32 or uint16_t images?
 
 @warning This uses CoreGraphics SPI, and may return NULL at any time; use CGDataProviderCopyData as a fallback, or don't use it at all unless you absolutely need the memory performance. 
 @param image The image whose bitmap data you want to access.
 @param len Returns the length of the bitmap pointer by reference.
 @return A pointer to the data, or NULL on failure. */
FV_PRIVATE_EXTERN const uint8_t * __FVCGImageGetBytePtr(CGImageRef image, size_t *len);

/** @internal 
 
 @brief Get the CGColorSpaceModel of a color space.
 
 @warning This is a hack on 10.4 and earlier.
 @param colorSpace The color space to query.
 @return A CGColorspaceModel value.  May be kCGColorSpaceModelUnknown. */
FV_PRIVATE_EXTERN CGColorSpaceModel __FVGetColorSpaceModelOfColorSpace(CGColorSpaceRef colorSpace);

/** @internal 
 
 @brief List of tile rects.
 
 The ImageShear test project uses this to draw tiles for diagnostic purposes.  It has no other useful function.
 @return An array of NSRect structures.  The caller is responsible for freeing this list with NSZoneFree. */
FV_PRIVATE_EXTERN NSRect * FVCopyRectListForImageWithScaledSize(CGImageRef image, const NSSize desiredSize, NSUInteger *rectCount);

__END_DECLS

#endif /* _FVCGIMAGEUTILITIES_H_ */
