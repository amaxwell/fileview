//
//  FVCGImageUtilities.mm
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

#import <vector>
#import "FVCGImageUtilities.h"
#import "FVBitmapContext.h"
#import "FVUtilities.h" /* for FVLog */
#import <Accelerate/Accelerate.h>
#import "FVImageBuffer.h"
#import <sys/time.h>

// http://lists.apple.com/archives/perfoptimization-dev/2005/Mar/msg00041.html

// this is a good size for the MBP, and presumably other vector units
#define MAX_TILE_WIDTH 1024

// smaller tile heights give better performance, but we need some latitude to divide the image
#define MAX_TILE_HEIGHT 256
#define MIN_TILE_HEIGHT   4
#define DEFAULT_TILE_HEIGHT 16
#define MAX_INTEGRAL_TOLERANCE 0.005

// need to extend edges to avoid artifacts

#define SCALE_QUALITY kvImageHighQualityResampling

#ifdef IMAGE_SHEAR
#define DEFAULT_OPTIONS kvImageNoFlags
#define SHEAR_OPTIONS kvImageEdgeExtend | SCALE_QUALITY
#else
#define DEFAULT_OPTIONS kvImageDoNotTile
#define SHEAR_OPTIONS kvImageEdgeExtend | kvImageDoNotTile | SCALE_QUALITY
#endif

// monitor cached tile memory consumption by blocking render threads
#define FV_LIMIT_TILEMEMORY_USAGE 1

// this is an advisory limit: actual usage will grow as needed
#define FV_TILEMEMORY_MEGABYTES 15

#if FV_LIMIT_TILEMEMORY_USAGE
// Sadly, NSCondition is apparently buggy pre-10.5: http://www.cocoabuilder.com/archive/message/cocoa/2008/4/4/203257
static pthread_mutex_t _memoryMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t _memoryCond = PTHREAD_COND_INITIALIZER;
#endif

static NSLock *_copyLock = [NSLock new];

NSSize FVCGImageSize(CGImageRef image)
{
    NSSize s;
    s.width = CGImageGetWidth(image);
    s.height = CGImageGetHeight(image);
    return s;
}

size_t __FVMaximumTileWidth(void) { return MAX_TILE_WIDTH; }
size_t __FVMaximumTileHeight(void) { return MAX_TILE_HEIGHT; }

static CGImageRef __FVCopyImageUsingCacheColorspace(CGImageRef image, NSSize size)
{
    [_copyLock lock];
    CGContextRef ctxt = FVIconBitmapContextCreateWithSize(size.width, size.height);
    
    CGContextSaveGState(ctxt);
    CGContextSetInterpolationQuality(ctxt, kCGInterpolationHigh);
    CGContextDrawImage(ctxt, CGRectMake(0, 0, CGBitmapContextGetWidth(ctxt), CGBitmapContextGetHeight(ctxt)), image);
    CGContextRestoreGState(ctxt);
    
    CGImageRef toReturn = CGBitmapContextCreateImage(ctxt);
    FVIconBitmapContextDispose(ctxt);
    [_copyLock unlock];
    return toReturn;
}

// private on all versions of OS X
FV_EXTERN void * CGDataProviderGetBytePtr(CGDataProviderRef provider);
FV_EXTERN size_t CGDataProviderGetSize(CGDataProviderRef provider);

const uint8_t * __FVCGImageGetBytePtr(CGImageRef image, size_t *len)
{
    CGDataProviderRef provider = CGImageGetDataProvider(image);
    uint8_t *bytePtr = NULL;
    if (NULL != CGDataProviderGetBytePtr && NULL != CGDataProviderGetSize) {
        bytePtr = (uint8_t *)CGDataProviderGetBytePtr(provider);
        if (len) *len = CGDataProviderGetSize(provider);
    }
    return bytePtr;
}

static inline bool __FVBitmapInfoIsIncompatible(CGImageRef image)
{
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(image);
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(image);
    
    // ??? check docs for premultiplying + vImage
    if (alphaInfo > kCGImageAlphaFirst)
        return true;
    
    if ((bitmapInfo & kCGBitmapFloatComponents) != 0)
        return true;    
    
    // safe to use without resampling/caching
    return false;
}

static void __FVGetPermuteMapToARGB(CGBitmapInfo bitmapInfo, uint8_t permuteMap[4])
{
    NSUInteger order = bitmapInfo & kCGBitmapByteOrderMask;
    CGImageAlphaInfo alphaInfo = (CGImageAlphaInfo)(bitmapInfo & kCGBitmapAlphaInfoMask);
    
    /*
     Transform to ARGB = (0,1,2,3) for vImage.
     
     http://lists.apple.com/archives/carbon-dev/2006/Nov/msg00014.html
     
     Summary: big endian order is RGB, little endian is BGR.  CGImageAlphaInfo says whether alpha is next to R (first) or B (last).
     - RGBA is big endian, alpha last
     - ARGB is big endian, alpha first
     - BGRA is little endian, alpha first
     - ABGR is little endian, alpha last
     */
    
    // we should never end up with a non-alpha bitmap, so those cases aren't handled
    
    switch (order) {
#ifdef __LITTLE_ENDIAN__
            /* !!! I came up with this by error-and-trial for CGImageAlphaInfo = kCGImageAlphaLast, using a png screenshot.  This appears to be the same for ppc and i386, and would be equivalent to BARG.  No idea what's going on here, since I think kCGBitmapByteOrderDefault should be endian-dependent.  Same ordering works under Rosetta, but I've no idea what happens with other CGImageAlphaInfo values.
             */
        case kCGBitmapByteOrderDefault:
            permuteMap[0] = 1;
            permuteMap[1] = 2;
            permuteMap[2] = 3;
            permuteMap[3] = 0;
            break;
#endif
        case kCGBitmapByteOrder16Little:
        case kCGBitmapByteOrder32Little:
            if (kCGImageAlphaPremultipliedLast == alphaInfo || kCGImageAlphaLast == alphaInfo) {
                // ABGR format
                FVLog(@"alphaInfo = %d", alphaInfo);
                permuteMap[0] = 0;
                permuteMap[1] = 3;
                permuteMap[2] = 2;
                permuteMap[3] = 1;
            }
            else if (kCGImageAlphaPremultipliedFirst == alphaInfo || kCGImageAlphaFirst == alphaInfo) {
                // BGRA format
                permuteMap[0] = 3;
                permuteMap[1] = 2;
                permuteMap[2] = 1;
                permuteMap[3] = 0;
            }
            else {
                FVLog(@"little endian: unhandled alphaInfo %d", alphaInfo);
            }
            break;
#ifdef __BIG_ENDIAN__
            case kCGBitmapByteOrderDefault:
            permuteMap[0] = 1;
            permuteMap[1] = 2;
            permuteMap[2] = 3;
            permuteMap[3] = 0;
            break;
#endif
            case kCGBitmapByteOrder16Big:
            case kCGBitmapByteOrder32Big:
            if (kCGImageAlphaPremultipliedLast == alphaInfo || kCGImageAlphaLast == alphaInfo) {
                // RGBA format
                permuteMap[0] = 3;
                permuteMap[1] = 0;
                permuteMap[2] = 1;
                permuteMap[3] = 2;
            }
            else if (kCGImageAlphaPremultipliedFirst == alphaInfo || kCGImageAlphaFirst == alphaInfo) {
                // ARGB format
                permuteMap[0] = 0;
                permuteMap[1] = 1;
                permuteMap[2] = 2;
                permuteMap[3] = 3;
            }
            else {
                FVLog(@"big endian: unhandled alphaInfo %d", alphaInfo);
            }
            break;
            default:
            FVLog(@"unhandled byte order %d", order);
            NSCParameterAssert(0);
            permuteMap[0] = 0;
            permuteMap[1] = 1;
            permuteMap[2] = 2;
            permuteMap[3] = 3;
    }
}

typedef struct _FVRegion {
    size_t x;
    size_t y;
    size_t w;
    size_t h;
    size_t row;
    size_t column;
} FVRegion;

#ifdef IMAGE_SHEAR

static CGImageRef __FVCreateCGImageFromARBG8888Buffer(vImage_Buffer *buffer)
{
    CFDataRef data = CFDataCreate(NULL, (uint8_t *)buffer->data, buffer->rowBytes * buffer->height);
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    if (data) CFRelease(data);
    
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    
    // meshed data is premultiplied ARGB (ppc) or BGRA (i386)
    CGBitmapInfo bitmapInfo = (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);    
    
    CGImageRef image;
    image = CGImageCreate(buffer->width, buffer->height, 8, 32, buffer->rowBytes, cspace, bitmapInfo, provider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cspace);
    
    return image;
}

#endif

static vImage_Error __FVConvertIndexedImageRegionToPlanar8_buffers(CGImageRef image, const uint8_t *srcBytes, const size_t rowBytes, const FVRegion region, NSArray *buffers)
{
    CGColorSpaceRef cspace = CGImageGetColorSpace(image);
    const size_t tableElements = CGColorSpaceGetColorTableCount(cspace) * CGColorSpaceGetNumberOfComponents(CGColorSpaceGetBaseColorSpace(cspace));
    NSCParameterAssert(3 == CGColorSpaceGetNumberOfComponents(CGColorSpaceGetBaseColorSpace(cspace)));
        
    // For color space creation, RGB is supposed to be packed per index, and presumably big endian order.
    unsigned char table[768] = { UCHAR_MAX };
    NSCParameterAssert(tableElements <= sizeof(table) / sizeof(unsigned char));
    CGColorSpaceGetColorTable(cspace, table);
    
    FVImageBuffer *planarBuffers[4];
    [buffers getObjects:planarBuffers];
    
    // set sizes to avoid a mismatch; these are guaranteed to be large enough
    for (NSUInteger i = 0; i < sizeof(planarBuffers) / sizeof(FVImageBuffer *); i++) {
        NSCParameterAssert(planarBuffers[i]->buffer->rowBytes >= region.w);
        planarBuffers[i]->buffer->width = region.w;
        planarBuffers[i]->buffer->height = region.h;
    }
    
    // original image is 1 byte/sample
    const size_t indexedImageBytesPerSample = 1;
    
    // Do the transformation manually, since vImageLookupTable_Planar8toPlanarF screws up the alpha channel (I think...); look up each pixel of the source image in the color table, then copy those values to the ARGB destination buffer
    for (NSUInteger rowIndex = 0; rowIndex < region.h; rowIndex++) {
        const uint8_t *srcRow = srcBytes + rowBytes * (region.y + rowIndex) + region.x * indexedImageBytesPerSample;        
        
        // we're converting the indexed image to ARGB8888
        uint8_t *dstAlpha = (uint8_t *)planarBuffers[0]->buffer->data + planarBuffers[0]->buffer->rowBytes * rowIndex;
        uint8_t *dstRed = (uint8_t *)planarBuffers[1]->buffer->data + planarBuffers[1]->buffer->rowBytes * rowIndex;
        uint8_t *dstGreen = (uint8_t *)planarBuffers[2]->buffer->data + planarBuffers[2]->buffer->rowBytes * rowIndex;
        uint8_t *dstBlue = (uint8_t *)planarBuffers[3]->buffer->data + planarBuffers[3]->buffer->rowBytes * rowIndex;
        
        for (NSUInteger srcColumn = 0; srcColumn < region.w; srcColumn++) {
            const uint8_t *rgbIndex = srcRow + srcColumn;
            // *rgbIndex ranges from 0--255, and is an index into the packed table
            uint16_t tableIndex = (*rgbIndex * 3);
            *dstAlpha++ = UCHAR_MAX;
            *dstRed++ = table[tableIndex+0];
            *dstGreen++ = table[tableIndex+1];
            *dstBlue++ = table[tableIndex+2];
        }        
    }
    
    return kvImageNoError;
}

// the image's byte pointer is passed in as a parameter in case we're copying from the data provider (which can be really slow)
static vImage_Error __FVConvertRGB888ImageRegionToPlanar8_buffers(CGImageRef image, const uint8_t *srcBytes, const size_t rowBytes, const FVRegion region, FVImageBuffer *destBuffer, NSArray *buffers)
{
    const size_t bytesPerSample = 3;
    vImage_Buffer *dstBuffer = destBuffer->buffer;
    dstBuffer->width = region.w;
    dstBuffer->height = region.h;
    dstBuffer->rowBytes = FVPaddedRowBytesForWidth(bytesPerSample, region.w);
    
    for (NSUInteger rowIndex = 0; rowIndex < region.h; rowIndex++) {
        const uint8_t *srcRow = srcBytes + rowBytes * (region.y + rowIndex) + region.x * bytesPerSample;
        uint8_t *dstRow = (uint8_t *)dstBuffer->data + dstBuffer->rowBytes * rowIndex;
        memcpy(dstRow, srcRow, bytesPerSample * region.w);
    }
    
    vImage_Error ret;    
    FVImageBuffer *planarBuffers[4];
    [buffers getObjects:planarBuffers];
    
    // set sizes to avoid a mismatch; these are guaranteed to be large enough
    for (NSUInteger i = 0; i < sizeof(planarBuffers) / sizeof(FVImageBuffer *); i++) {
        NSCParameterAssert(planarBuffers[i]->buffer->rowBytes >= region.w);
        planarBuffers[i]->buffer->width = region.w;
        planarBuffers[i]->buffer->height = region.h;
    }
    
    uint8_t permuteMap[4] = { 0, 0, 0, 0 };
    
    // zero element in buffers is alpha
    permuteMap[0] = 0;
    NSUInteger order = CGImageGetBitmapInfo(image) & kCGBitmapByteOrderMask;
    
    switch (order) {
        case kCGBitmapByteOrder16Little:
        case kCGBitmapByteOrder32Little:
            // BGR
            permuteMap[1] = 3;
            permuteMap[2] = 2;
            permuteMap[3] = 1;
            break;
        default:
            // RGB
            permuteMap[1] = 1;
            permuteMap[2] = 2;
            permuteMap[3] = 3;
    }
    
    // add alpha channel
    vImageOverwriteChannelsWithScalar_Planar8(UCHAR_MAX, planarBuffers[permuteMap[0]]->buffer, DEFAULT_OPTIONS);
    ret = vImageConvert_RGB888toPlanar8(dstBuffer, planarBuffers[permuteMap[1]]->buffer, planarBuffers[permuteMap[2]]->buffer, planarBuffers[permuteMap[3]]->buffer, DEFAULT_OPTIONS);
    
    return ret;
}

// the image's byte pointer is passed in as a parameter in case we're copying from the data provider (which can be really slow)
static vImage_Error __FVConvertARGB8888ImageRegionToPlanar8_buffers(CGImageRef image, const uint8_t *srcBytes, const size_t rowBytes, const FVRegion region, FVImageBuffer *destBuffer, NSArray *buffers)
{
    const size_t bytesPerSample = 4;
    vImage_Buffer *dstBuffer = destBuffer->buffer;
    dstBuffer->width = region.w;
    dstBuffer->height = region.h;
    dstBuffer->rowBytes = FVPaddedRowBytesForWidth(bytesPerSample, region.w);
    
    for (NSUInteger rowIndex = 0; rowIndex < region.h; rowIndex++) {
        const uint8_t *srcRow = srcBytes + rowBytes * (region.y + rowIndex) + region.x * bytesPerSample;
        uint8_t *dstRow = (uint8_t *)dstBuffer->data + dstBuffer->rowBytes * rowIndex;
        memcpy(dstRow, srcRow, bytesPerSample * region.w);
    }
    
    vImage_Error ret;    
    FVImageBuffer *planarBuffers[4];
    [buffers getObjects:planarBuffers];
    
    // set sizes to avoid a mismatch; these are guaranteed to be large enough
    for (NSUInteger i = 0; i < sizeof(planarBuffers) / sizeof(FVImageBuffer *); i++) {
        NSCParameterAssert(planarBuffers[i]->buffer->rowBytes >= region.w);
        planarBuffers[i]->buffer->width = region.w;
        planarBuffers[i]->buffer->height = region.h;
    }
    
    uint8_t permuteMap[4] = { 0, 0, 0, 0 };
    __FVGetPermuteMapToARGB(CGImageGetBitmapInfo(image), permuteMap);
    
    ret = vImageConvert_ARGB8888toPlanar8(dstBuffer, planarBuffers[permuteMap[0]]->buffer, planarBuffers[permuteMap[1]]->buffer, planarBuffers[permuteMap[2]]->buffer, planarBuffers[permuteMap[3]]->buffer, DEFAULT_OPTIONS);
    
    return ret;
}

static inline size_t __FVGetNumberOfColumnsInRegionVector(std::vector <FVRegion> regions)
{
    size_t columnIndex = 0;
    std::vector<FVRegion>::iterator iter;
    for (iter = regions.begin(); iter < regions.end() && iter->row == 0; iter++)
        columnIndex++;

    return columnIndex;
}

static inline size_t __FVMaximumTileWidthForImage(CGImageRef image)
{
    return std::min((size_t)MAX_TILE_WIDTH,  CGImageGetWidth(image));
}

static inline size_t __FVMaximumTileHeightForImage(CGImageRef image)
{
    return std::min((size_t)MAX_TILE_HEIGHT,  CGImageGetHeight(image));
}

static std::vector <FVRegion> __FVTileRegionsForImage(CGImageRef image, double scale)
{
    size_t originalHeight = CGImageGetHeight(image);
    size_t originalWidth = CGImageGetWidth(image);
    
    size_t tileWidth = __FVMaximumTileWidthForImage(image);
    
    const size_t minimumTileHeight = std::min((size_t)MIN_TILE_HEIGHT, originalHeight);
    
    // height of 16 is fast, so start searching there
    size_t tileHeight = std::min((size_t)DEFAULT_TILE_HEIGHT, __FVMaximumTileHeightForImage(image));
    
    // need to choose regions so that scale * region.h is as nearly integral as possible
    double v = scale * (double)tileHeight;
    while (ABS(floor(v) - v) > MAX_INTEGRAL_TOLERANCE && tileHeight >= minimumTileHeight) {
        tileHeight -= 1;
        v = scale * (double)tileHeight;
    }
    
    // if decreasing didn't help, try increasing
    while (ABS(floor(v) - v) > MAX_INTEGRAL_TOLERANCE && (size_t)tileHeight < __FVMaximumTileHeightForImage(image)) {
        tileHeight += 1;
        v = scale * (double)tileHeight;
    }
    
    size_t columns = originalWidth / tileWidth;
    if (columns * tileWidth < originalWidth)
        columns++;
    size_t rows = originalHeight / tileHeight;
    if (rows * tileHeight < originalHeight)
        rows++;
    
    std::vector <FVRegion> regions;
    
    for (NSUInteger rowIndex = 0; rowIndex < rows; rowIndex++) {
        
        size_t regionHeight = tileHeight;
        size_t yloc = rowIndex * tileHeight;
        
        if (yloc + regionHeight > originalHeight)
            regionHeight = originalHeight - yloc;
        
        for (NSUInteger columnIndex = 0; columnIndex < columns; columnIndex++) {
            
            size_t regionWidth = tileWidth;
            size_t xloc = columnIndex * tileWidth;
            
            if (xloc + regionWidth > originalWidth)
                regionWidth = originalWidth - xloc;
            
            FVRegion region = { xloc, yloc, regionWidth, regionHeight, rowIndex, columnIndex };
            regions.push_back(region);
        }
    }
    return regions;
}


static vImage_Error __FVConvertPlanar8To8888Host(NSArray *planarBuffers, const vImage_Buffer *destBuffer)
{
    NSCParameterAssert([planarBuffers count] == 4);
    
    const FVImageBuffer *planarA[4];
    [planarBuffers getObjects:planarA];
    
    vImage_Error ret;
    
#ifdef __LITTLE_ENDIAN__
    // we want BGRA
    ret = vImageConvert_Planar8toARGB8888(planarA[3]->buffer, planarA[2]->buffer, planarA[1]->buffer, planarA[0]->buffer, destBuffer, DEFAULT_OPTIONS);
#else
#ifdef __BIG_ENDIAN__
    // we want ARGB
    ret = vImageConvert_Planar8toARGB8888(planarA[0]->buffer, planarA[1]->buffer, planarA[2]->buffer, planarA[3]->buffer, destBuffer, DEFAULT_OPTIONS);
#else
#error unknown architecture
#endif // __BIG_ENDIAN__
#endif // __LITTLE_ENDIAN__
    
    return ret;
}

static NSUInteger __FVAddRowOfARGB8888BuffersToImage(NSArray *buffers, const NSUInteger previousRowIndex, vImage_Buffer *destImage)
{
    NSUInteger bufCount = [buffers count];
    NSCParameterAssert(bufCount > 0);
    FVImageBuffer *imageBuffer = [buffers objectAtIndex:0];
    const size_t lastRowIndex = imageBuffer->buffer->height + previousRowIndex;
    NSUInteger sourceRow = 0;        
    
    // !!! avoid overflow; should check this elsewhere and assert here
    for (NSUInteger destRow = previousRowIndex; destRow < lastRowIndex && destRow < destImage->height; destRow++) {
        
        uint8_t *rowPtr = (uint8_t *)destImage->data + destRow * destImage->rowBytes;
        
        for (NSUInteger bufIndex = 0; bufIndex < bufCount; bufIndex++) {
            imageBuffer = [buffers objectAtIndex:bufIndex];
            size_t widthToCopy = imageBuffer->buffer->width * 4;
            uint8_t *srcPtr = (uint8_t *)imageBuffer->buffer->data + sourceRow * imageBuffer->buffer->rowBytes;
            memcpy(rowPtr, srcPtr, widthToCopy);
            rowPtr = rowPtr + widthToCopy;
        }
        sourceRow++;
    }
    return lastRowIndex;
}

#ifdef IMAGE_SHEAR
static size_t __FVScaledWidthOfRegions(std::vector <FVRegion> regions, const double scale)
{
    size_t cumulativeWidth = 0;
    for (NSUInteger i = 0; i < regions.size(); i++) {
        FVRegion region = regions[i];
        if (region.row > 0)
            break;
        cumulativeWidth += round(scale * (double)region.w);
    }
    return cumulativeWidth;
}

static size_t __FVScaledHeightOfRegions(std::vector <FVRegion> regions, const double scale)
{
    size_t cumulativeHeight = 0;
    for (NSUInteger i = 0; i < regions.size(); i++) {
        FVRegion region = regions[i];
        if (region.column == 0)
            cumulativeHeight += round(scale * (double)region.h);
    }
    return cumulativeHeight;
}
#endif

/*
 Use to avoid buffer overruns; due to scaling and tolerance buildup, we can easily end up with a column or row outside the destination image.  In that case, we just truncate the input region before passing it to __FVAddRowOfARGB8888BuffersToImage.  This led to a really insidious crashing bug, since we generally have enough horizontal padding to avoid the overrun on memcpy in __FVAddRowOfARGB8888BuffersToImage.
 
 The accumulatedRows check has to be done in the scaling function, but we check columns each time; computationally this is negligible, especially compared with scaling.  IMP caching is there just because it's easy, and the next best thing to for...in syntax.
 */
static void __FVCheckAndTrimRow(NSArray *regionRow, vImage_Buffer *destinationBuffer, size_t accumulatedRows)
{
    NSUInteger regionIndex, regionCount = [regionRow count];
    size_t accumulatedColumns = 0;
    
    id (*objectAtIndex)(id, SEL, NSUInteger);
    objectAtIndex = (id (*)(id, SEL, NSUInteger))[regionRow methodForSelector:@selector(objectAtIndex:)];

    FVImageBuffer *imageBuffer;
    
    // see if we're too wide...
    for (regionIndex = 0; regionIndex < regionCount; regionIndex++) {
        imageBuffer = objectAtIndex(regionRow, @selector(objectAtIndex:), regionIndex);
        accumulatedColumns += imageBuffer->buffer->width;
    }

    ssize_t shrinkage = accumulatedColumns - destinationBuffer->width;
    // ... and trim the last (far right) column if necessary
    if (shrinkage > 0) {
        // NSLog(@"horizontal shrinkage: %ld pixel(s)", (long)shrinkage);
        imageBuffer = [regionRow lastObject];
        imageBuffer->buffer->width -= shrinkage;
    }
    
    // trim the last (bottom) row if we're too tall
    shrinkage = accumulatedRows - destinationBuffer->height;
    if (shrinkage > 0) {
        // NSLog(@"vertical shrinkage: %ld pixel(s)", (long)shrinkage);
        for (regionIndex = 0; regionIndex < regionCount; regionIndex++) {
            imageBuffer = objectAtIndex(regionRow, @selector(objectAtIndex:), regionIndex);
            imageBuffer->buffer->height -= shrinkage;
        }
    }
}

static CGImageRef __FVTileAndScale_8888_or_888_Image(CGImageRef image, const NSSize desiredSize)
{
    // make this call early so we avoid other allocations on this thread in case we have to wait on _copyLock
    CFDataRef originalImageData = NULL;
    const uint8_t *srcBytes = __FVCGImageGetBytePtr(image, NULL);    
    if (NULL == srcBytes) {
        // block other threads from copying at the same time; this tends to be a large memory hit
        [_copyLock lock];
        originalImageData = CGDataProviderCopyData(CGImageGetDataProvider(image));
        srcBytes = CFDataGetBytePtr(originalImageData);
    }
    
    size_t originalWidth = CGImageGetWidth(image);
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(image);
    
    bool isIndexedImage = false;
    if (kCGColorSpaceModelIndexed == __FVGetColorSpaceModelOfColorSpace(CGImageGetColorSpace(image))) {
        // we'd better not reach this on 10.4...
        FVAPIAssert(floor(NSAppKitVersionNumber > NSAppKitVersionNumber10_4), @"indexed color space functions not available on 10.4");
        isIndexedImage = true;
    }
    
    size_t destRowBytes = FVPaddedRowBytesForWidth(4, desiredSize.width);
    FVImageBuffer *interleavedImageBuffer = [[FVImageBuffer alloc] initWithWidth:desiredSize.width height:desiredSize.height rowBytes:destRowBytes];
    vImage_Buffer *interleavedBuffer = interleavedImageBuffer->buffer;
    
    const double scale = desiredSize.width / (double)originalWidth;
    ResamplingFilter filter = vImageNewResamplingFilter(scale, SCALE_QUALITY);
    
    std::vector <FVRegion> regions = __FVTileRegionsForImage(image, scale);
    
    // we don't need to retain the tiles, since we don't release them after adding to the arrays
    NSMutableArray *planarTilesA = (NSMutableArray *)CFArrayCreateMutable(NULL, 4, NULL);
    NSMutableArray *planarTilesB = (NSMutableArray *)CFArrayCreateMutable(NULL, 4, NULL);
    
    FVImageBuffer *imageBuffer;
    NSUInteger i;
    for (i = 0; i < 4; i++) {
        // if scaling up, allocate extra memory, since we reuse these buffers    
        imageBuffer = [FVImageBuffer newPlanarBufferWithScale:ceil(scale)];
        [planarTilesA addObject:imageBuffer];
        
        imageBuffer = [FVImageBuffer newPlanarBufferWithScale:ceil(scale)];
        [planarTilesB addObject:imageBuffer];
    }
    imageBuffer = nil;
    
    NSUInteger tileCount = regions.size();
    
    const FVImageBuffer *planarA[4];
    [planarTilesA getObjects:planarA];
    
    const FVImageBuffer *planarB[4];
    [planarTilesB getObjects:planarB];    
    
    // keep track of the next scanline/byte offset in the final image
    NSUInteger nextScanline = 0;
    
    // keep track of which region we're in, so we can stitch together each row into the final image
    NSUInteger regionRowIndex = 0;
    NSMutableArray *currentRegionRow = [NSMutableArray new];
    
    // first region should be the largest region; this is a temporary buffer passed to the planar conversion function
    // NB: not required for the indexed images, since we copy those directly to the planar buffers
    FVImageBuffer *regionBuffer = isIndexedImage ? nil : [[FVImageBuffer alloc] initWithWidth:regions[0].w height:regions[0].h bytesPerSample:4];
    
    // maintain these instead of creating new buffers on each pass through the loop
    NSUInteger regionColumnIndex = __FVGetNumberOfColumnsInRegionVector(regions);
    for (NSUInteger j = 0; j < regionColumnIndex; j++) {
        imageBuffer = [[FVImageBuffer alloc] initWithWidth:(regions[j].w * ceil(scale)) height:(regions[j].h * ceil(scale)) bytesPerSample:4];
        [currentRegionRow addObject:imageBuffer];
        [imageBuffer dispose];
    }
    
    // reset to zero so we can use this as index into currentRegionRow
    regionColumnIndex = 0;
    
    const size_t imageBytesPerRow = CGImageGetBytesPerRow(image);
    size_t accumulatedRows = 0;
    
    for (NSUInteger tileIndex = 0; tileIndex < tileCount; tileIndex++) {
        
        FVRegion region = regions[tileIndex];
        
        if (region.row != regionRowIndex) {
            // these FVImageBuffers have correct values for width/height, and represent a series of scanlines 
            accumulatedRows += imageBuffer->buffer->height;
            __FVCheckAndTrimRow(currentRegionRow, interleavedBuffer, accumulatedRows);
            nextScanline = __FVAddRowOfARGB8888BuffersToImage(currentRegionRow, nextScanline, interleavedBuffer);
            regionRowIndex++;
            regionColumnIndex = 0;
        }
        
        vImage_Error ret;
        
        // reset from the scaled values, so the region extraction knows the tiles are large enough
        size_t rowBytes = FVPaddedRowBytesForWidth(1, region.w);
        for (i = 0; i < 4; i++) {
            planarA[i]->buffer->rowBytes = rowBytes;
            planarB[i]->buffer->rowBytes = rowBytes;
        }
        
        // deinterleave a region of the image, using regionBuffer for temporary memory
        if (kCGImageAlphaNone == alphaInfo && false == isIndexedImage)
            ret = __FVConvertRGB888ImageRegionToPlanar8_buffers(image, srcBytes, imageBytesPerRow, region, regionBuffer, planarTilesA);
        else if (isIndexedImage)
            ret = __FVConvertIndexedImageRegionToPlanar8_buffers(image, srcBytes, imageBytesPerRow, region, planarTilesA);
        else
            ret = __FVConvertARGB8888ImageRegionToPlanar8_buffers(image, srcBytes, imageBytesPerRow, region, regionBuffer, planarTilesA);
        
        // vImage does not use CGFloat; we use zero offset horizontally
        float offset = 0;
        
        // do horizontal shear for all channels, with A as source and B as destination
        size_t scaledWidth = round(scale * (double)region.w);
        size_t scaledRowBytes = FVPaddedRowBytesForWidth(1, scaledWidth);
        for (i = 0; i < 4; i++) {
            planarB[i]->buffer->width = scaledWidth;
            planarB[i]->buffer->height = region.h;
            planarB[i]->buffer->rowBytes = scaledRowBytes;
            ret = vImageHorizontalShear_Planar8(planarA[i]->buffer, planarB[i]->buffer, 0, 0, offset, 0, filter, 0, SHEAR_OPTIONS);
            if (kvImageNoError != ret) FVLog(@"vImageHorizontalShear_Planar8 failed with error %d", ret);
        }
        
        // do vertical shear for all channels, with B as source and A as destination
        offset = scale * ((float)region.h - round((float)region.h * scale));
        size_t scaledHeight = round(scale * (double)region.h);
        for (i = 0; i < 4; i++) {
            // use the scaled value from the buffer
            planarA[i]->buffer->width = planarB[i]->buffer->width;
            planarA[i]->buffer->rowBytes = planarB[i]->buffer->rowBytes;
            planarA[i]->buffer->height = scaledHeight;
            ret = vImageVerticalShear_Planar8(planarB[i]->buffer, planarA[i]->buffer, 0, 0, offset, 0, filter, 0, SHEAR_OPTIONS);
            if (kvImageNoError != ret) FVLog(@"vImageVerticalShear_Planar8 failed with error %d", ret);
        }
        
        // premultiply alpha in place if it wasn't previously premultiplied (A is now the source)
        if (alphaInfo != kCGImageAlphaPremultipliedFirst && alphaInfo != kCGImageAlphaPremultipliedLast) {
            for (i = 1; i < 4; i++)
                vImagePremultiplyData_Planar8(planarA[i]->buffer, planarA[0]->buffer, planarA[i]->buffer, DEFAULT_OPTIONS);
        }    
        
        // now convert to a mesh format, using the appropriate column buffer as destination
        imageBuffer = [currentRegionRow objectAtIndex:regionColumnIndex];
        // no need to reset rowBytes, as it should be sufficiently long and correctly padded
        imageBuffer->buffer->width = planarA[0]->buffer->width;
        imageBuffer->buffer->height = planarA[0]->buffer->height;
        ret = __FVConvertPlanar8To8888Host(planarTilesA, imageBuffer->buffer);
        if (kvImageNoError != ret) FVLog(@"__FVConvertPlanar8To8888Host failed with error %d", ret);        
        
        regionColumnIndex++;
        
    }
    
    if ([currentRegionRow count]) {
        accumulatedRows += imageBuffer->buffer->height;
        __FVCheckAndTrimRow(currentRegionRow, interleavedBuffer, accumulatedRows);
        __FVAddRowOfARGB8888BuffersToImage(currentRegionRow, nextScanline, interleavedBuffer);
    }
    
    vImageDestroyResamplingFilter(filter);
    
    if (originalImageData) {
        CFRelease(originalImageData);
        [_copyLock unlock];
    }
    
    // tell this buffer not to call free() when it deallocs, so we avoid copying the data
    [interleavedImageBuffer setFreeBufferOnDealloc:NO];
    CFAllocatorRef alloc = [interleavedImageBuffer allocator];
    CFDataRef data = CFDataCreateWithBytesNoCopy(alloc, (uint8_t *)interleavedBuffer->data, interleavedBuffer->rowBytes * interleavedBuffer->height, alloc);
    
    // cleanup is safe now
    
    // call -dispose on the tiles so they're returned to the cache
    [planarTilesA makeObjectsPerformSelector:@selector(dispose)];
    [planarTilesA release];
    [planarTilesB makeObjectsPerformSelector:@selector(dispose)];
    [planarTilesB release];
    [currentRegionRow release];
    
    // could probably cache a few of these
    [regionBuffer dispose];
    
#if FV_LIMIT_TILEMEMORY_USAGE
    pthread_mutex_lock(&_memoryMutex);
    pthread_cond_broadcast(&_memoryCond);
    pthread_mutex_unlock(&_memoryMutex);
#endif
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    if (data) CFRelease(data);
    
    // ignore most of the details from the original image
    size_t bitsPerComponent = 8;
    size_t bitsPerPixel = 32;
    CGColorSpaceRef cspace = isIndexedImage ? CGColorSpaceRetain(CGColorSpaceGetBaseColorSpace(CGImageGetColorSpace(image))) : CGColorSpaceCreateDeviceRGB();
    CGColorRenderingIntent intent = CGImageGetRenderingIntent(image);
    
    // meshed data is premultiplied ARGB (ppc) or BGRA (i386)
    CGBitmapInfo bitmapInfo = (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);    
    
    image = CGImageCreate(interleavedBuffer->width, interleavedBuffer->height, bitsPerComponent, bitsPerPixel, interleavedBuffer->rowBytes, cspace, bitmapInfo, provider, NULL, true, intent);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cspace);
    
    // we need to release this one, since its memory is now transferred to NSData (and it's too big to cache)
    [interleavedImageBuffer dispose];
    
    return image; 
}

NSRect * FVCopyRectListForImageWithScaledSize(CGImageRef image, const NSSize desiredSize, NSUInteger *rectCount)
{    
    const size_t height = CGImageGetHeight(image);
    const double scale = desiredSize.width / (double)CGImageGetWidth(image);
    std::vector <FVRegion> regions = __FVTileRegionsForImage(image, scale);
    
    NSRect *rectList = (NSRect *)NSZoneMalloc(NULL, sizeof(NSRect) * regions.size());
    const NSUInteger rc = regions.size();
    
    for (NSUInteger i = 0; i < rc; i++) {
        
        FVRegion region = regions.back();
        rectList[i].origin.x = region.x;
        rectList[i].origin.y = height - region.y - region.h;
        rectList[i].size.width = region.w;
        rectList[i].size.height = region.h;
        regions.pop_back();
    }
    *rectCount = rc;
    return rectList;
}

CGImageRef FVCGCreateResampledImageOfSize(CGImageRef image, const NSSize desiredSize)
{
    return __FVCopyImageUsingCacheColorspace(image, desiredSize);
}

// always returns false on 10.4
static inline bool __FVCanUseIndexedColorSpaces()
{
    return (NULL != CGColorSpaceGetColorTable && NULL != CGColorSpaceGetColorTableCount && NULL != CGColorSpaceGetBaseColorSpace);
}

// CGColorSpaceGetColorSpaceModel is in 10.4 and 10.5 CoreGraphics framework; not sure what it does, since it returns 1 for an indexed colorspace

CGColorSpaceModel __FVGetColorSpaceModelOfColorSpace(CGColorSpaceRef colorSpace)
{
    if (NULL != CGColorSpaceGetModel) return CGColorSpaceGetModel(colorSpace);    
    CGColorSpaceRef devRGB = CGColorSpaceCreateDeviceRGB();
    // if not RGB, return unknown so we can punt by redrawing into a new bitmap context
    CGColorSpaceModel model = kCGColorSpaceModelUnknown;
    // hack; basically relies on CG returning a cached instance for the device RGB space
    if (CFEqual(devRGB, colorSpace)) model = kCGColorSpaceModelRGB;
    CGColorSpaceRelease(devRGB);
    return model;
}

CGImageRef FVCreateResampledImageOfSize(CGImageRef image, const NSSize desiredSize)
{
    CGColorSpaceModel colorModel = __FVGetColorSpaceModelOfColorSpace(CGImageGetColorSpace(image));
    
    if (FVImageIsIncompatible(image) || __FVBitmapInfoIsIncompatible(image) || kCGColorSpaceModelUnknown == colorModel) {
        // let CG handle the scaling if we're redrawing anyway (avoids duplicating huge images, also)
        return __FVCopyImageUsingCacheColorspace(image, desiredSize);
    }
    
    if (kCGColorSpaceModelIndexed == colorModel) {
        // indexed spaces with alpha are tricky, and 10.4 doesn't support the necessary calls
        if (CGImageGetAlphaInfo(image) != kCGImageAlphaNone || false == __FVCanUseIndexedColorSpaces())
            return __FVCopyImageUsingCacheColorspace(image, desiredSize);
    }
    
#if FV_LIMIT_TILEMEMORY_USAGE
    // see http://www.opengroup.org/onlinepubs/009695399/functions/pthread_cond_timedwait.html for notes on timed wait
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct timespec ts;
    TIMEVAL_TO_TIMESPEC(&tv, &ts);
    ts.tv_nsec += 50000000;
    pthread_mutex_lock(&_memoryMutex);
    int ret = 0;
    while ([FVImageBuffer allocatedBytes] > FV_TILEMEMORY_MEGABYTES * 1024 * 1024 && 0 == ret)
        ret = pthread_cond_timedwait(&_memoryCond, &_memoryMutex, &ts);
    pthread_mutex_unlock(&_memoryMutex);
#endif

    return __FVTileAndScale_8888_or_888_Image(image, desiredSize);
}
