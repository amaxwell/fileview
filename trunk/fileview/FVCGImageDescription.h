/*
 *  FVCGImageDescription.h
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

#import <Cocoa/Cocoa.h>

@class FVCGColorSpaceDescription;

/** @internal @brief CGImage archive wrapper.
 
 FVCGImageDescription is a wrapper object for a CGImage that allows archiving it with NSArchiver.  Color spaces are represented by FVCGColorSpaceDescription, which may result in loss of information, but it is more efficient than conversion to TIFF or other standard image formats.  */
@interface FVCGImageDescription : NSObject <NSCoding> 
{
@private;
    size_t                     _width;
    size_t                     _height;
    size_t                     _bitsPerComponent;
    size_t                     _bitsPerPixel;
    size_t                     _bytesPerRow;
    CGBitmapInfo               _bitmapInfo;
    bool                       _shouldInterpolate;
    CGColorRenderingIntent     _renderingIntent;
    FVCGColorSpaceDescription *_colorSpaceDescription;
    CFDataRef                  _bitmapData;
    CGFloat                   *_decode;
    /* Not archived */
    CGImageRef                 _image;
}

/** @internal @brief Designated initializer.
 
 Initializes the instance with a given CGImage.  In the best case, bitmap data will not be copied.
 @param image The CGImage to archive.
 @return An initialized instance, suitable for archiving. */
- (id)initWithImage:(CGImageRef)image;

/** @internal @brief Create a CGImage.
 
 Lazily creates a new CGImage from the internal description information and bitmap data.  If the image has already been created, it is retained before being returned.  The caller is always responsible for releasing this object.
 @return A CGImage based on the internal description. */
- (CGImageRef)newImage;

@end
