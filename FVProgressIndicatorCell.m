//
//  FVProgressIndicatorCell.m
//  FileView
//
//  Created by Adam Maxwell on 2/15/08.
/*
 This software is Copyright (c) 2008-2013
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

#import "FVProgressIndicatorCell.h"


@implementation FVProgressIndicatorCell

+ (CGColorRef)_newFillColor
{
    CGColorSpaceRef cspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    CGFloat components[4];
    NSColor *nsColor = [[NSColor selectedControlColor] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    [nsColor getComponents:components];
    // make it slightly transparent
    components[3] = 0.8;
    CGColorRef fillColor = CGColorCreate(cspace, components);
    CGColorSpaceRelease(cspace);
    return fillColor;
}

+ (CGColorRef)_newStrokeColor
{
    CGColorSpaceRef cspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    CGFloat components[4];
    NSColor *nsColor = [[NSColor alternateSelectedControlColor] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    [nsColor getComponents:components];
    CGColorRef strokeColor = CGColorCreate(cspace, components);
    CGColorSpaceRelease(cspace);
    return strokeColor;
}

- (id)init
{
    self = [super init];
    if (self) {
        _currentProgress = 0;
        _currentRotation = 0;
        _style = FVProgressIndicatorDeterminate;
        _fillColor = [[self class] _newFillColor];
        _strokeColor = [[self class] _newStrokeColor];
    }
    return self;
}

- (void)dealloc
{
    CGColorRelease(_fillColor);
    CGColorRelease(_strokeColor);
    [super dealloc];
}

- (void)setCurrentProgress:(CGFloat)progress { _currentProgress = progress; }
- (CGFloat)currentProgress { return _currentProgress; }
- (void)setStyle:(FVProgressIndicatorStyle)style { _style = style; }

- (void)drawWithFrame:(NSRect)aRect inView:(NSView *)aView
{
    CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
    CGContextSaveGState(context);
    CGRect progressRect = NSRectToCGRect(aRect);    
    CGPoint ctr = CGPointMake(CGRectGetMidX(progressRect), CGRectGetMidY(progressRect));
    
    // indeterminate download length
    if (_style == FVProgressIndicatorIndeterminate) {
        // fixed value of 1/3
        _currentProgress = 0.333;
        _currentRotation += M_PI / (CGFloat)10;
        // rotate the 1/3 sector until the download is complete (see _updateProgressIndicators:)
        CGContextTranslateCTM(context, ctr.x, ctr.y);
        CGContextRotateCTM(context, _currentRotation);
        CGContextTranslateCTM(context, -ctr.x, -ctr.y);
    }
    
    if (0 < _currentProgress && _currentProgress < 1) {
        CGContextSetFillColorWithColor(context, _fillColor);
        CGContextSetStrokeColorWithColor(context, _strokeColor);
        CGContextBeginPath(context);
        CGFloat radius = CGRectGetWidth(progressRect) / 2;
        CGContextMoveToPoint(context, ctr.x, ctr.y);
        CGPoint arcStart = CGPointMake(CGRectGetMaxX(progressRect), CGRectGetMidY(progressRect));
        CGContextAddLineToPoint(context, arcStart.x, arcStart.y);
        CGFloat angle = 2 * M_PI * _currentProgress;
        CGContextAddArc(context, ctr.x, ctr.y, radius, 0, angle, false);    
        CGContextClosePath(context);
        CGContextDrawPath(context, kCGPathFillStroke);
    }
    CGContextRestoreGState(context);
}

@end
