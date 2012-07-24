//
//  FVNSImageIcon.m
//  FileView
//
//  Created by Adam R. Maxwell on 07/23/12.
/*
 This software is Copyright (c) 2008-2012
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

#import "FVNSImageIcon.h"
#import "FVBitmapContext.h"

@implementation FVNSImageIcon

/*
 The outContext pointer allows additional drawing on the image, but the returned
 reference is 
 a) not owned by the caller,
 b) does not neccessarily mutate the CGImage
 
 Only returns NULL if context creation fails, which shouldn't happen unless we run
 out of address space.
 */
static CGImageRef __FVCreateImageWithImage(NSImage *nsImage, size_t width, size_t height, CGContextRef *outContext)
{
    NSGraphicsContext *nsContext = [[FVBitmapContext bitmapContextWithSize:NSMakeSize(width, height)] graphicsContext];
    CGContextRef ctxt = [nsContext graphicsPort];
    if (outContext) *outContext = ctxt;
    // should never happen; might be better to abort here...
    if (NULL == ctxt) return NULL;
    CGRect rect = CGRectZero;
    rect.size = CGSizeMake(width, height);
    CGContextClearRect(ctxt, rect);
    CGImageRef image = NULL;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nsContext];
    [nsImage drawInRect:NSRectFromCGRect(rect) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    image = CGBitmapContextCreateImage(ctxt);
    return image;
}

static CGImageRef __FVCreateThumbnailWithImage(NSImage *nsImage, CGContextRef *outContext)
{
    return __FVCreateImageWithImage(nsImage, FVMaxThumbnailDimension, FVMaxThumbnailDimension, outContext);
}

static CGImageRef __FVCreateFullImageWithImage(NSImage *nsImage, CGContextRef *outContext)
{
    return __FVCreateImageWithImage(nsImage, FVMaxImageDimension, FVMaxImageDimension, outContext);
}

- (id)initWithImage:(NSImage *)image
{
    self = [super init];
    if (self) {
        _fullImage = __FVCreateFullImageWithImage(image, NULL);
        _thumbnail = __FVCreateThumbnailWithImage(image, NULL);
    }
    return self;
}

- (void)dealloc
{
    CGImageRelease(_thumbnail);
    CGImageRelease(_fullImage);
    [super dealloc];
}

- (BOOL)needsRenderForSize:(NSSize)size
{
    return NO;
}

- (void)renderOffscreen
{
    // no-op
}

- (NSSize)size { return NSMakeSize(FVMaxThumbnailDimension, FVMaxThumbnailDimension); }

- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{    
    CGContextSaveGState(context);
    // get rid of any shadow, as the image draws it
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    
    if (FVShouldDrawFullImageWithThumbnailSize(dstRect.size, FVCGImageSize(_thumbnail)))
        CGContextDrawImage(context, [self _drawingRectWithRect:dstRect], _fullImage);
    else
        CGContextDrawImage(context, [self _drawingRectWithRect:dstRect], _thumbnail);
    
    CGContextRestoreGState(context);
}

@end
