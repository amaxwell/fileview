//
//  FVAliasBadge.m
//  FileView
//
//  Created by Adam Maxwell on 04/01/08.
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

#import "FVAliasBadge.h"
#import "FVUtilities.h"

@implementation FVAliasBadge

static CFMutableDictionaryRef _badges = NULL;
static const NSUInteger _sizes[] = { 32, 64, 128, 256, 512 };

// OK to do this in +initialize, since the class is only used to access badges
+ (void)initialize
{
    FVINITIALIZE(FVAliasBadge);

    _badges = CFDictionaryCreateMutable(NULL, 0, &FVIntegerKeyDictionaryCallBacks, &kCFTypeDictionaryValueCallBacks);
    NSUInteger i, iMax = sizeof(_sizes) / sizeof(NSUInteger);
    
    IconRef linkBadge;
    OSStatus err;
    err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kAliasBadgeIcon, &linkBadge);
    
    for (i = 0; i < iMax && noErr == err; i++) {
        
        CGRect dstRect = CGRectMake(0, 0, _sizes[i], _sizes[i]);
        
        NSGraphicsContext *windowContext = FVWindowGraphicsContextWithSize(NSRectFromCGRect(dstRect).size);
        NSParameterAssert(nil != windowContext);
        
        CGLayerRef layer = CGLayerCreateWithContext([windowContext graphicsPort], dstRect.size, NULL);
        CGContextRef context = CGLayerGetContext(layer);
        
        // don't use CGContextClearRect with non-window/bitmap contexts
        CGContextSetRGBFillColor(context, 0, 0, 0, 0);
        CGContextFillRect(context, dstRect);
        
        // rect needs to be a square, or else the aspect ratio of the arrow is wrong
        // rect needs to be the same size as the full icon, or the scale of the arrow is wrong
        
        // We don't know the size of the actual link arrow (and it changes with the size of dstRect), so fine-tuning the drawing isn't really possible as far as I can see.
        PlotIconRefInContext(context, &dstRect, kAlignBottomLeft, kTransformNone, NULL, kPlotIconRefNormalFlags, linkBadge);
        
        CFDictionarySetValue(_badges, (void *)_sizes[i], layer);
        CGLayerRelease(layer);
    }
    ReleaseIconRef(linkBadge);
}

+ (CGLayerRef)aliasBadgeWithSize:(NSSize)size;
{
    NSUInteger i, iMax = sizeof(_sizes) / sizeof(NSUInteger);
    for (i = 0; i < iMax; i++) {
        
        NSUInteger height = _sizes[i];        
        if (height > size.height)
            return (CGLayerRef)CFDictionaryGetValue(_badges, (void *)height);
    }
    return (CGLayerRef)CFDictionaryGetValue(_badges, (void *)_sizes[iMax - 1]);
}

@end
