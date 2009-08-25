//
//  FVCGColorSpaceDescription.h
//  FileView
//
//  Created by Adam Maxwell on 3/23/08.
/*
 This software is Copyright (c) 2008-2009
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

/** @internal @brief Color space description.
 
 This object encapsulates the color model (including lookup table) of a CGColorSpace for archiving with NSArchiver.  When unarchiving, device-dependent colorspaces are used, so complete fidelity may not be achieved.  Color space names are not (publicly) available on 10.5 and earlier, so that simple route is not available.  In addition, not all color spaces have an ICC profile, so that isn't reliable either (and is only available on 10.5 and later).  
 
 Grayscale and RGB colorspaces are supported.  CMYK colorspaces are nominally supported, but may not have been tested.
 
 */

@interface FVCGColorSpaceDescription : NSObject <NSCoding>
{
@private;
    CGColorSpaceModel      _colorSpaceModel;
    size_t                 _components;
    size_t                 _baseColorSpaceComponents;
    size_t                 _colorTableCount;  // value returned by CGColorSpaceGetColorTableCount
    size_t                 _colorTableLength; // length of _colorTable
    unsigned char         *_colorTable;       // length is _colorTableLength * _baseColorSpaceComponents
}

/** @internal @brief Designated initializer.
 
 Several heuristics are used to determine the color space characteristics.
 
 @param colorSpace The source CGColorSpace.
 @return An initialized description object. */
- (id)initWithColorSpace:(CGColorSpaceRef)colorSpace;

/** @internal @brief Create a CGColorSpace.
 
 Creates a new CGColorSpace based on the characteristics of the FVCGColorSpaceDescription.  The caller is responsible for releasing this instance.
 
 @return An initialized description object. */
- (CGColorSpaceRef)newColorSpace;

@end
