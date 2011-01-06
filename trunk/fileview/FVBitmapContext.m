//
//  FVBitmapContextCache.m
//  FileView
//
//  Created by Adam Maxwell on 10/21/07.
/*
 This software is Copyright (c) 2007-2011
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

#import "FVBitmapContext.h"
#import "FVCGImageUtilities.h"
#import "FVAllocator.h"

/** @internal @brief Bitmap context creation.
 
 Create a new ARGB (ppc) or BGRA (x86) bitmap context of the given size, with rows padded appropriately and Device RGB colorspace.  The context should be released using CFRelease, and its bitmap data should be deallocated with CFAllocatorDeallocate/FVAllocatorGetDefault.  The context may contain garbage, so clear it first if you're drawing transparent content.
 @param width Width in pixels.
 @param height Height in pixels. 
 @return A new CGBitmapContext or NULL if it could not be created. */
static CGContextRef __FVIconBitmapContextCreateWithSize(size_t width, size_t height);

@implementation FVBitmapContext

- (id)init
{
    [NSException raise:NSInternalInconsistencyException format:@"Invalid initializer %s", __func__];
    return nil;
}

- (id)initPixelsWide:(size_t)pixelsWide pixelsHigh:(size_t)pixelsHigh;
{
    self = [super init];
    if (self) {
        _port = __FVIconBitmapContextCreateWithSize(pixelsWide, pixelsHigh);
    }
    return self;
}

+ (FVBitmapContext *)bitmapContextWithSize:(NSSize)pixelSize;
{
    return [[[self allocWithZone:[self zone]] initPixelsWide:pixelSize.width pixelsHigh:pixelSize.height] autorelease];
}

- (void)dealloc
{
    [_flipped release];
    [_context release];
    void *bitmapData = CGBitmapContextGetData(_port);
    if (bitmapData) CFAllocatorDeallocate(FVAllocatorGetDefault(), bitmapData);
    CGContextRelease(_port);
    [super dealloc];
}

- (CGContextRef)graphicsPort;
{
    FVAPIParameterAssert(NULL != _port);
    return _port;
}

- (NSGraphicsContext *)graphicsContext;
{
    if (nil == _context)
        _context = [[NSGraphicsContext graphicsContextWithGraphicsPort:[self graphicsPort] flipped:NO] retain];    
    FVAPIParameterAssert(nil != _context);
    return _context;
}

- (NSGraphicsContext *)flippedGraphicsContext;
{
    if (nil == _flipped)
        _flipped = [[NSGraphicsContext graphicsContextWithGraphicsPort:[self graphicsPort] flipped:YES] retain];
    FVAPIParameterAssert(nil != _flipped);
    return _flipped;
}

@end

// discard indexed color images (e.g. GIF) and convert to RGBA for FVCGImageDescription compatibility
static inline bool __FVColorSpaceIsIncompatible(CGImageRef image)
{
    CGColorSpaceRef cs = CGImageGetColorSpace(image);
    return CGColorSpaceGetNumberOfComponents(cs) != 3 && CGColorSpaceGetNumberOfComponents(cs) != 1;
}

// may add more checks here in future
bool FVImageIsIncompatible(CGImageRef image)
{
    return __FVColorSpaceIsIncompatible(image) || CGImageGetBitsPerComponent(image) != 8;
}

size_t FVPaddedRowBytesForWidth(const size_t bytesPerSample, const size_t pixelsWide)
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

static CGContextRef __FVIconBitmapContextCreateWithSize(size_t width, size_t height)
{
    size_t bitsPerComponent = 8;
    size_t nComponents = 4;
    size_t bytesPerRow = FVPaddedRowBytesForWidth(nComponents, width);
    
    size_t requiredDataSize = bytesPerRow * height;
    
    /* 
     CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB) gives us a device independent colorspace, but we don't care in this case, since we're just drawing to the screen, and color conversion when blitting the CGImageRef is a pretty big hit.  See http://www.cocoabuilder.com/archive/message/cocoa/2002/10/31/56768 for additional details, including a recommendation to use alpha in the highest 8 bits (ARGB) and use kCGRenderingIntentAbsoluteColorimetric for rendering intent.
     */
    
    /*
     From John Harper on quartz-dev: http://lists.apple.com/archives/Quartz-dev/2008/Feb/msg00045.html
     "Since you are creating the images you give to CA in the GenericRGB color space, CA will have to copy each image and color-match it to the display before they can be uploaded to the GPU. So the first thing I would try is using a DisplayRGB colorspace when you create the bitmap context. Also, to avoid having the graphics card make another copy, you should align the row bytes of the new image to at least 64 bytes. Finally, it's normally best to create BGRA images on intel machines and ARGB on ppc, so that would be the image format (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host)."
     
     Based on the older post outlined above, I was already using a device RGB colorspace, but former information indicated that 16 byte row alignment was best, and I was using ARGB on both ppc and x86.  Not sure if the alignment comment is completely applicable since I'm not interacting directly with the GPU, but it shouldn't hurt.
     */
    
    char *bitmapData = CFAllocatorAllocate(FVAllocatorGetDefault(), requiredDataSize, 0);
    if (NULL == bitmapData) return NULL;
    
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctxt;
    CGBitmapInfo bitmapInfo = (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    ctxt = CGBitmapContextCreate(bitmapData, width, height, bitsPerComponent, bytesPerRow, cspace, bitmapInfo);
    CGColorSpaceRelease(cspace);
    
    CGContextSetRenderingIntent(ctxt, kCGRenderingIntentAbsoluteColorimetric);
    
    // note that bitmapData and the context itself are allocated and not freed here
    
    return ctxt;
}

