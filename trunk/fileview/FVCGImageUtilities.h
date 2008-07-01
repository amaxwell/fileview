//
//  FVCGImageUtilities.h
//  FileView
//
//  Created by Adam Maxwell on 3/8/08.
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

static inline NSSize FVCGImageSize(CGImageRef image)
{
    NSSize s;
    s.width = CGImageGetWidth(image);
    s.height = CGImageGetHeight(image);
    return s;
}

// algorithm borrowed from Apple sample code
static inline size_t FVPaddedRowBytesForWidth(const size_t bytesPerSample, const size_t pixelsWide)
{
    size_t destRowBytes = bytesPerSample * pixelsWide;
    // Widen bytesPerRow out to a integer multiple of 64 bytes
    destRowBytes = (destRowBytes + 63) & ~63;
    
    // Make sure we are not an even power of 2 wide.
    // Will loop a few times for destRowBytes <= 64
    while (0 == (destRowBytes & (destRowBytes - 1)))
        destRowBytes += 64;
    return destRowBytes;
}

// only exported for FVImageBuffer; do not use
FV_PRIVATE_EXTERN size_t __FVMaximumTileWidth(void);
FV_PRIVATE_EXTERN size_t __FVMaximumTileHeight(void);

// use for resampling CGImages or converting an image to be compatible with cache limitations
FV_PRIVATE_EXTERN CGImageRef FVCreateResampledImageOfSize(CGImageRef image, const NSSize desiredSize);

// redraws the image into a new CGBitmapContext
FV_PRIVATE_EXTERN CGImageRef FVCGCreateResampledImageOfSize(CGImageRef image, const NSSize desiredSize);

// this uses CG SPI, and may return NULL at any time; use CGDataProviderCopyData as a fallback
FV_PRIVATE_EXTERN const uint8_t * __FVCGImageGetBytePtr(CGImageRef image, size_t *len);

// this is a hack on 10.4 and earlier
FV_PRIVATE_EXTERN CGColorSpaceModel __FVGetColorSpaceModelOfColorSpace(CGColorSpaceRef colorSpace);

// the ImageShear test project uses this
FV_PRIVATE_EXTERN NSRect * FVCopyRectListForImageWithScaledSize(CGImageRef image, const NSSize desiredSize, NSUInteger *rectCount);
