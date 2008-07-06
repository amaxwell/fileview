//
//  FVImageView.m
//  ImageShear
//
//  Created by Adam Maxwell on 5/4/08.
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

#import "FVImageView.h"
#import "FVCGImageUtilities.h"

@implementation FVImageView

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key
{
    NSSet *defaultPaths = [super keyPathsForValuesAffectingValueForKey:key];
    if ([key isEqualToString:@"pixelsWide"] || [key isEqualToString:@"pixelsHigh"]) {
        defaultPaths = [[defaultPaths mutableCopy] autorelease];
        [(NSMutableSet *)defaultPaths addObject:@"scale"];
        [(NSMutableSet *)defaultPaths addObject:@"image"];
    }
    return defaultPaths;
}

- (id)initWithFrame:(NSRect)aRect
{
    self = [super initWithFrame:aRect];
    if (self) {
        _scale = 1.0;
        _drawGrid = NO;
        _drawOriginalImage = NO;
        _backgroundColor = [[NSColor purpleColor] retain];
    }
    return self;
}

- (void)dealloc
{
    CGImageRelease(_originalImage);
    CGImageRelease(_image);
    NSZoneFree(NSZoneFromPointer(_rectList), _rectList);
    [_backgroundColor release];
    [super dealloc];
}

- (void)setBackgroundColor:(NSColor *)color
{
    [_backgroundColor autorelease];
    _backgroundColor = [color copy];
    [self setNeedsDisplay:YES];
}

- (NSColor *)backgroundColor { return _backgroundColor; }

- (CGFloat)scale { return _scale; }
- (void)setScale:(CGFloat)value 
{ 
    _scale = value; 
    if (_originalImage) {
        NSSize size = NSMakeSize([self scale] * CGImageGetWidth(_originalImage), [self scale] * CGImageGetHeight(_originalImage));
        CGImageRef image = FVCreateResampledImageOfSize(_originalImage, size);
        NSUInteger rectCount;
        [self setRectList:FVCopyRectListForImageWithScaledSize(_originalImage, size, &rectCount)];
        [self setRectCount:rectCount];
        [self setImage:image];
        CGImageRelease(image);
    }
}

- (NSRect *)rectList { return _rectList; }
- (void)setRectList:(NSRect *)value;
{
    NSZoneFree(NULL, _rectList);
    _rectList = value;
}

- (NSUInteger)rectCount { return _rectCount; }
- (void)setRectCount:(NSUInteger)value { _rectCount = value; }

- (BOOL)isOpaque { return NO; }

- (void)drawRect:(NSRect)rect
{
    [[NSColor lightGrayColor] setFill];
    NSRectFill([self bounds]);
    
    CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
    CGContextTranslateCTM(context, 20, 20);
    
    NSRect scaledRect = NSZeroRect;
    
    if (_originalImage) {
        CGRect iconRect = CGRectZero;
        iconRect.size = CGSizeMake(CGImageGetWidth(_originalImage), CGImageGetHeight(_originalImage));
        [[NSColor greenColor] setFill];
        NSRectFill(*(NSRect *)&iconRect);
        scaledRect.size.width = CGImageGetWidth(_originalImage) * [self scale];
        scaledRect.size.height = CGImageGetHeight(_originalImage) * [self scale];
        
        if ([self drawsOriginalImage])
            CGContextDrawImage(context, iconRect, _originalImage);
    }
    
    if (_image) {        
        CGRect iconRect = CGRectZero;
        iconRect.size = CGSizeMake(CGImageGetWidth(_image), CGImageGetHeight(_image));
        [_backgroundColor setFill];
        NSRectFill(*(NSRect *)&iconRect);
        CGContextDrawImage(context, iconRect, _image);
    }
    
    if ([self drawsGrid]) {
        NSUInteger i;
        [[NSColor blackColor] set];
        for (i = 0; i < _rectCount; i++)
            NSFrameRectWithWidth(_rectList[i], 0);
        
        [[NSColor whiteColor] set];
        NSFrameRectWithWidthUsingOperation(scaledRect, 2, NSCompositeSourceOver);
    }
}

- (void)setNewImage:(CGImageRef)image
{
    CGImageRelease(_originalImage);
    _originalImage = CGImageRetain(image);
    [self setImage:NULL];
    [self setScale:1.0];
    [self setImage:image];
}

- (CGImageRef)image { return _image; }

- (void)tile
{
    NSSize s = NSMakeSize(MAX(CGImageGetWidth(_originalImage), CGImageGetWidth(_image)), MAX(CGImageGetHeight(_originalImage), CGImageGetHeight(_image)));
    s.width += 60;
    s.height += 60;
    [self setFrameSize:s];
    [self setFrameOrigin:NSZeroPoint];
    [self setNeedsDisplay:YES];
}    

- (void)resizeWithOldSuperviewSize:(NSSize)oldBoundsSize
{
    [super resizeWithOldSuperviewSize:oldBoundsSize];
    [self tile];
}

- (void)setImage:(CGImageRef)image;
{        
    if (_image != image) {
        CGImageRelease(_image);
        _image = CGImageRetain(image);
        [self tile];
    }
}

- (void)setDrawsGrid:(BOOL)flag;
{
    _drawGrid = flag;
    [self setNeedsDisplay:YES];
}

- (BOOL)drawsGrid { return _drawGrid; }

- (void)setDrawsOriginalImage:(BOOL)flag
{
    _drawOriginalImage = flag;
    [self setNeedsDisplay:YES];
}

- (BOOL)drawsOriginalImage { return _drawOriginalImage; }

- (NSString *)pixelsHigh { return [NSString stringWithFormat:@"%lu", (long)CGImageGetHeight(_image)]; }
- (NSString *)pixelsWide { return [NSString stringWithFormat:@"%lu", (long)CGImageGetWidth(_image)]; }

@end
