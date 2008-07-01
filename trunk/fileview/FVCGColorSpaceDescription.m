//
//  FVCGColorSpaceDescription.m
//  FileView
//
//  Created by Adam Maxwell on 3/23/08.
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

#import "FVCGColorSpaceDescription.h"
#import "FVUtilities.h"
#import "FVCGImageUtilities.h"

@implementation FVCGColorSpaceDescription

static inline bool __FVCGCanSaveIndexedSpaces(void)
{
    return (NULL != CGColorSpaceGetColorTableCount && NULL != CGColorSpaceGetColorTable && NULL != CGColorSpaceGetBaseColorSpace);
}

- (id)initWithColorSpace:(CGColorSpaceRef)colorSpace;
{
    self = [super init];
    if (self) {
        _components = CGColorSpaceGetNumberOfComponents(colorSpace);
        _colorSpaceModel = __FVGetColorSpaceModelOfColorSpace(colorSpace);
        
        // init to zero for pre-10.5 and for non-indexed spaces
        _baseColorSpaceComponents = 0;
        _colorTableCount = 0;
        _colorTableLength = 0;
        _colorTable = NULL;
        
        if (kCGColorSpaceModelIndexed == _colorSpaceModel && __FVCGCanSaveIndexedSpaces()) {
            _baseColorSpaceComponents = CGColorSpaceGetNumberOfComponents(CGColorSpaceGetBaseColorSpace(colorSpace));

            /*
             The documentation for CGColorSpaceGetColorTableCount is misleading.  It does not return the value passed to CGColorSpaceCreateIndexed or the actual length of the buffer filled by CGColorSpaceGetColorTable.  For an RGB-based indexed colorspace, _colorTableCount is typically 256.  Per the header comments for CGColorSpaceCreateIndexed, we pass (256 - 1) to CGColorSpaceCreateIndexed.  From that comment, we also find that the actual length of the array is 256 * 3 for an RGB-based space.
             */
            _colorTableCount = CGColorSpaceGetColorTableCount(colorSpace);
            _colorTableLength = _colorTableCount * _baseColorSpaceComponents;
            _colorTable = NSZoneCalloc([self zone], _colorTableLength, sizeof(unsigned char));
            CGColorSpaceGetColorTable(colorSpace, _colorTable);
        }
#if 0
        CGColorSpaceRef newSpace = CGColorSpaceCreateIndexed(CGColorSpaceGetBaseColorSpace(colorSpace), _colorTableCount - 1, _colorTable);
        if (NULL == newSpace)
            fprintf(stderr, "unable to create indexed space immediately\n");
        CGColorSpaceRelease(newSpace);
#endif
    }
    return self;
}

- (void)dealloc
{
    NSZoneFree([self zone], _colorTable);
    [super dealloc];
}

- (CGColorSpaceRef)_createDeviceColorSpaceForComponents:(size_t)components
{
    CGColorSpaceRef colorSpace = NULL;
    switch(components) {
        case 1:
            colorSpace = CGColorSpaceCreateDeviceGray();
            break;
        case 3:
            colorSpace = CGColorSpaceCreateDeviceRGB();
            break;
        case 4:
            colorSpace = CGColorSpaceCreateDeviceCMYK();
            break;
        default:
            FVLog(@"Unable to create color space with %d components", components);
    }
    return colorSpace;
}


- (CGColorSpaceRef)_createIndexedColorSpace
{
    CGColorSpaceRef baseColorSpace = [self _createDeviceColorSpaceForComponents:_baseColorSpaceComponents];
    CGColorSpaceRef cspace = CGColorSpaceCreateIndexed(baseColorSpace, _colorTableCount - 1, _colorTable);
    if (NULL != cspace)
        CGColorSpaceRelease(baseColorSpace);
    else
        FVLog(@"Unable to recreate indexed color space; returning %@ instead", baseColorSpace);
    return (cspace == NULL ? baseColorSpace : cspace);
}

- (CGColorSpaceRef)createColorSpace;
{
    CGColorSpaceRef cspace = NULL;
    switch (_colorSpaceModel) {
        case kCGColorSpaceModelMonochrome:
            cspace = CGColorSpaceCreateDeviceGray();
            break;
        case kCGColorSpaceModelRGB:
            cspace = CGColorSpaceCreateDeviceRGB();
            break;
        case kCGColorSpaceModelCMYK:
            cspace = CGColorSpaceCreateDeviceCMYK();
            break;
        case kCGColorSpaceModelIndexed:
            cspace = [self _createIndexedColorSpace];
            break;
        default:
            cspace = [self _createDeviceColorSpaceForComponents:_components];
            FVLog(@"Unsupported colorspace model %d, using %@ instead", _colorSpaceModel, cspace);
    }
    return cspace;
}

- (void)encodeWithCoder:(NSCoder *)aCoder;
{
    if ([aCoder allowsKeyedCoding]) {
        [aCoder encodeInt:_colorSpaceModel forKey:@"_colorSpaceModel"];
        [aCoder encodeInt:_components forKey:@"_components"];
        [aCoder encodeInt:_baseColorSpaceComponents forKey:@"_baseColorSpaceComponents"];
        [aCoder encodeInt:_colorTableCount forKey:@"_colorTableCount"];
        [aCoder encodeInt:_colorTableLength forKey:@"_colorTableLength"];
        [aCoder encodeBytes:_colorTable length:_colorTableLength  forKey:@"_colorTable"];
    }
    else {
        [aCoder encodeValueOfObjCType:@encode(CGColorSpaceModel) at:&_colorSpaceModel];
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_components];
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_baseColorSpaceComponents];
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_colorTableCount];
        [aCoder encodeValueOfObjCType:@encode(size_t) at:&_colorTableLength];
        [aCoder encodeBytes:_colorTable length:_colorTableLength];
    }
}

- (id)initWithCoder:(NSCoder *)aDecoder;
{
    self = [super init];
    if (self) {
        if ([aDecoder allowsKeyedCoding]) {
            _colorSpaceModel = (CGColorSpaceModel)[aDecoder decodeIntForKey:@"_colorSpaceModel"];
            _components = [aDecoder decodeIntForKey:@"_components"];
            _baseColorSpaceComponents = [aDecoder decodeIntForKey:@"_baseColorSpaceComponents"];
            _colorTableCount = [aDecoder decodeIntForKey:@"_colorTableCount"];
            _colorTableLength = [aDecoder decodeIntForKey:@"_colorTableLength"];
            
            NSUInteger len;
            const void *colorTable = [aDecoder decodeBytesForKey:@"_colorTable" returnedLength:&len];
            NSParameterAssert(len == _colorTableLength);
            _colorTable = NSZoneCalloc([self zone], _colorTableLength, sizeof(unsigned char));
            memcpy(_colorTable, colorTable, _colorTableLength * sizeof(unsigned char));
        }
        else {
            [aDecoder decodeValueOfObjCType:@encode(CGColorSpaceModel) at:&_colorSpaceModel];
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_components];
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_baseColorSpaceComponents];
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_colorTableCount];
            [aDecoder decodeValueOfObjCType:@encode(size_t) at:&_colorTableLength];
            
            NSUInteger len;
            const void *colorTable = [aDecoder decodeBytesWithReturnedLength:&len];
            NSParameterAssert(len == _colorTableLength);
            _colorTable = NSZoneCalloc([self zone], _colorTableLength, sizeof(unsigned char));
            memcpy(_colorTable, colorTable, _colorTableLength * sizeof(unsigned char));
        }
    }
    return self;
}

@end
