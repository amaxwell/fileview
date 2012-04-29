/*
 *  FVCGImageDescription.mm
 *  FileView
 *
 *  Created by Adam Maxwell on 10/21/07.
 */
/*
 This software is Copyright (c) 2007-2012
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

#import "FVCGImageDescription.h"
#import "FVCGImageUtilities.h"
#import "FVUtilities.h"
#import "FVCGColorSpaceDescription.h"
#import "FVAllocator.h"

@implementation FVCGImageDescription

- (id)initWithImage:(CGImageRef)image;
{
    self = [super init];
    if (self) {
        
        // retain in case we access the data provider's byte pointer directly
        _image = CGImageRetain(image);
        
        _width = CGImageGetWidth(_image);
        _height = CGImageGetHeight(_image);
        _bitsPerComponent = CGImageGetBitsPerComponent(_image);
        _bitsPerPixel = CGImageGetBitsPerPixel(_image);
        _bytesPerRow = CGImageGetBytesPerRow(_image);
        _bitmapInfo = CGImageGetBitmapInfo(_image);
        _shouldInterpolate = CGImageGetShouldInterpolate(_image);
        _renderingIntent = CGImageGetRenderingIntent(_image);
        const CGFloat *decode = CGImageGetDecode(_image);
        if (NULL != decode) {
            const size_t decodeLength = _bitsPerPixel / _bitsPerComponent * 2;
            _decode = NSZoneCalloc([self zone], decodeLength, sizeof(CGFloat));
            memcpy(_decode, decode, decodeLength * sizeof(CGFloat));
        }
        else {
            _decode = NULL;
        }
        _colorSpaceDescription = [[FVCGColorSpaceDescription allocWithZone:[self zone]] initWithColorSpace:CGImageGetColorSpace(_image)];
        
        size_t bitmapPtrSize;
        const uint8_t *bitmapPtr = __FVCGImageGetBytePtr(_image, &bitmapPtrSize);
        if (NULL == bitmapPtr) {
            _bitmapData = CGDataProviderCopyData(CGImageGetDataProvider(_image));
        }
        else {
            // wrap in a non-copying, non-freeing CFData for archiving access
            _bitmapData = CFDataCreateWithBytesNoCopy(CFGetAllocator(self), bitmapPtr, bitmapPtrSize, kCFAllocatorNull);
        }
        
        NSAssert3((size_t)CFDataGetLength(_bitmapData) == _bytesPerRow * _height, @"strange data length %ld for %@ (should be >= %lu)", CFDataGetLength(_bitmapData), _image, (unsigned long)(_bytesPerRow * _height));
    }
    return self;
}

- (void)dealloc
{
    [_colorSpaceDescription release];
    if (_bitmapData) CFRelease(_bitmapData);
    NSZoneFree([self zone], _decode);
    CGImageRelease(_image);
    [super dealloc];
}

- (CGImageRef)newImage;
{
    if (NULL == _image) {
        CGColorSpaceRef cspace = [_colorSpaceDescription newColorSpace];
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(_bitmapData);
        _image = CGImageCreate(_width, _height, _bitsPerComponent, _bitsPerPixel, _bytesPerRow, cspace, _bitmapInfo, provider, _decode, _shouldInterpolate, _renderingIntent);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(cspace);
    }
    return CGImageRetain(_image);
}

- (size_t)_decodeLength
{
    return NULL == _decode ? 0 : (sizeof(CGFloat) * _bitsPerPixel / _bitsPerComponent * 2);
}

- (void)encodeWithCoder:(NSCoder *)aCoder;
{
    if ([aCoder allowsKeyedCoding]) {
        [aCoder encodeInt:_width forKey:@"_width"];
        [aCoder encodeInt:_height forKey:@"_height"];
        [aCoder encodeInt:_bitsPerComponent forKey:@"_bitsPerComponent"];
        [aCoder encodeInt:_bitsPerPixel forKey:@"_bitsPerPixel"];
        [aCoder encodeInt:_bytesPerRow forKey:@"_bytesPerRow"];
        [aCoder encodeInt:_bitmapInfo forKey:@"_bitmapInfo"];
        [aCoder encodeInt:_shouldInterpolate forKey:@"_shouldInterpolate"];
        [aCoder encodeInt:_renderingIntent forKey:@"_renderingIntent"];
        [aCoder encodeObject:_colorSpaceDescription forKey:@"_colorSpaceDescription"];
        [aCoder encodeObject:(NSData *)_bitmapData forKey:@"_bitmapData"];
        [aCoder encodeBytes:(const uint8_t *)_decode length:[self _decodeLength]  forKey:@"_decode"];
    }
    else {
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_width];
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_height];
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_bitsPerComponent];
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_bitsPerPixel];
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_bytesPerRow];
        [aCoder encodeValueOfObjCType:@encode(CGBitmapInfo) at:&_bitmapInfo];
        [aCoder encodeValueOfObjCType:@encode(bool) at:&_shouldInterpolate];
        [aCoder encodeValueOfObjCType:@encode(CGColorRenderingIntent) at:&_renderingIntent];
        [aCoder encodeObject:_colorSpaceDescription];
        
        size_t len = CFDataGetLength(_bitmapData);
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&len];
        [aCoder encodeArrayOfObjCType:@encode(char) count:len at:CFDataGetBytePtr(_bitmapData)];
        
        [aCoder encodeBytes:_decode length:[self _decodeLength]];
    }
}

- (id)initWithCoder:(NSCoder *)aDecoder;
{
    self = [super init];
    if (self) {
        if ([aDecoder allowsKeyedCoding]) {
            _width = [aDecoder decodeIntForKey:@"_width"];
            _height = [aDecoder decodeIntForKey:@"_height"];
            _bitsPerComponent = [aDecoder decodeIntForKey:@"_bitsPerComponent"];
            _bitsPerPixel = [aDecoder decodeIntForKey:@"_bitsPerPixel"];
            _bytesPerRow = [aDecoder decodeIntForKey:@"_bytesPerRow"];
            _bitmapInfo = [aDecoder decodeIntForKey:@"_bitmapInfo"];
            _shouldInterpolate = [aDecoder decodeIntForKey:@"_shouldInterpolate"];
            _renderingIntent = (CGColorRenderingIntent)[aDecoder decodeIntForKey:@"_renderingIntent"];
            _colorSpaceDescription = [[aDecoder decodeObjectForKey:@"_colorSpaceDescription"] retain];
            _bitmapData = (CFDataRef)[[aDecoder decodeObjectForKey:@"_bitmapData"] retain];

            _image = NULL;
            
            NSUInteger len;
            const CGFloat *decode = (CGFloat *)[aDecoder decodeBytesForKey:@"_decode" returnedLength:&len];
            if (len > 0) {
                _decode = NSZoneCalloc([self zone], len, sizeof(char));
                memcpy(_decode, decode, len);
            }
            else {
                _decode = NULL;
            }
        }
        else {
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_width];
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_height];
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_bitsPerComponent];
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_bitsPerPixel];
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_bytesPerRow];
            [aDecoder decodeValueOfObjCType:@encode(CGBitmapInfo) at:&_bitmapInfo];
            [aDecoder decodeValueOfObjCType:@encode(bool) at:&_shouldInterpolate];
            [aDecoder decodeValueOfObjCType:@encode(CGColorRenderingIntent) at:&_renderingIntent];
            _colorSpaceDescription = [[aDecoder decodeObject] retain];
            
            size_t bitmapLength;
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&bitmapLength];
            void *data = CFAllocatorAllocate(FVAllocatorGetDefault(), bitmapLength * sizeof(char), 0);
            [aDecoder decodeArrayOfObjCType:@encode(char) count:bitmapLength at:data];
            _bitmapData = CFDataCreateWithBytesNoCopy(FVAllocatorGetDefault(), data, bitmapLength, FVAllocatorGetDefault());

            _image = NULL;
            
            NSUInteger len;
            const CGFloat *decode = (CGFloat *)[aDecoder decodeBytesWithReturnedLength:&len];
            if (len > 0) {
                _decode = NSZoneCalloc([self zone], len, sizeof(char));
                memcpy(_decode, decode, len);
            }
            else {
                _decode = NULL;
            }
        }
    }
    return self;
}

@end
