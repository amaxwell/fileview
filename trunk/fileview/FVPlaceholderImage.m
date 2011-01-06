//
//  FVPlaceholderImage.m
//  FileView
//
//  Created by Adam Maxwell on 2/26/08.
/*
 This software is Copyright (c) 2008-2011
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

#import "FVPlaceholderImage.h"
#import "FVUtilities.h"

// Instruments showed a fair number of paths being created in drawing placeholders, and drawing an image is faster and less memory intensive than drawing a path each time.  Most of the path drawing overhead is in fonts, so there's not much we can do about that.
static CFMutableDictionaryRef _placeholders = NULL;
static const NSUInteger _sizes[] = { 32, 64, 128, 256, 512 };

@implementation FVPlaceholderImage

// OK to do this in +initialize, since the class is only used to access images
+ (void)initialize
{
    FVINITIALIZE(FVPlaceholderImage);
    
    _placeholders = CFDictionaryCreateMutable(NULL, 0, &FVIntegerKeyDictionaryCallBacks, &kCFTypeDictionaryValueCallBacks);
    NSUInteger i, iMax = sizeof(_sizes) / sizeof(NSUInteger);
    
    for (i = 0; i < iMax; i++) {
        
        NSRect dstRect = NSMakeRect(0, 0, _sizes[i], _sizes[i]);
        
        NSGraphicsContext *windowContext = FVWindowGraphicsContextWithSize(dstRect.size);
        NSParameterAssert(nil != windowContext);

        CGLayerRef layer = CGLayerCreateWithContext([windowContext graphicsPort], NSRectToCGRect(dstRect).size, NULL);
        CGContextRef context = CGLayerGetContext(layer);
        NSParameterAssert(nil != context);

        // don't use CGContextClearRect with non-window/bitmap contexts
        CGContextSetRGBFillColor(context, 0, 0, 0, 0);
        CGContextFillRect(context, NSRectToCGRect(dstRect));
        
        NSGraphicsContext *nsContext = [NSGraphicsContext graphicsContextWithGraphicsPort:context flipped:YES];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:nsContext];
        [nsContext saveGraphicsState];
        
        CGFloat radius = MIN(NSWidth(dstRect) / 4.0, 10.0);
        CGFloat lineWidth = MIN((CGFloat)_sizes[i] / 64, 2.0);
        dstRect = NSInsetRect(dstRect, 2.0, 2.0);
        
        NSBezierPath *path = [NSBezierPath fv_bezierPathWithRoundRect:dstRect xRadius:radius yRadius:radius];
        CGFloat pattern[2] = { 6.0, 3.0 };
        
        [path setLineWidth:lineWidth];
        [path setLineDash:pattern count:2 phase:0.0];
        [[NSColor lightGrayColor] setStroke];
        [path stroke];
        [path setLineWidth:1.0];
        [path setLineDash:NULL count:0 phase:0.0];
        [nsContext restoreGraphicsState];
        
        [NSGraphicsContext restoreGraphicsState];
                
        CFDictionarySetValue(_placeholders, (void *)_sizes[i], layer);
        CGLayerRelease(layer);
    }
}

+ (CGLayerRef)placeholderWithSize:(NSSize)size;
{
    NSUInteger i, iMax = sizeof(_sizes) / sizeof(NSUInteger);
    for (i = 0; i < iMax; i++) {
        
        NSUInteger height = _sizes[i];        
        if (height > size.height)
            return (CGLayerRef)CFDictionaryGetValue(_placeholders, (void *)height);
    }
    return (CGLayerRef)CFDictionaryGetValue(_placeholders, (void *)_sizes[iMax - 1]);
}

@end

