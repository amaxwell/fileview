//
//  FVArrowButtonCell.m
//  FileViewTest
//
//  Created by Adam Maxwell on 09/21/07.
/*
 This software is Copyright (c) 2007-2009
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

#import "FVArrowButtonCell.h"


@implementation FVArrowButtonCell

+ (BOOL)prefersTrackingUntilMouseUp { return YES; }

- (id)initTextCell:(NSString *)aString {
    return [self initWithArrowDirection:FVArrowRight];
}

- (id)initWithArrowDirection:(FVArrowDirection)anArrowDirection {
    self = [super initImageCell:nil];
    if (self) {
        [self setHighlightsBy:NSNoCellMask];
        [self setImagePosition:NSImageOnly];
        [self setBezelStyle:NSRegularSquareBezelStyle];
        [self setBordered:NO];
        _arrowDirection = anArrowDirection;
    }
    return self;
}

- (NSBezierPath *)arrowBezierPathWithSize:(NSSize)size;
{
    CGFloat w = size.width / 16.0, h = size.height / 16.0;
    CGFloat tip = _arrowDirection == FVArrowRight ? 14.0*w : 2.0*w;
    CGFloat base = _arrowDirection == FVArrowRight ? 3.0*w : 13.0*w;
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    
    [arrow moveToPoint:NSMakePoint(base, 6.0*h)];
    [arrow lineToPoint:NSMakePoint(base, 10.0*h)];
    [arrow lineToPoint:NSMakePoint(8.0*w, 10.0*h)];
    
    // top point of triangle
    [arrow lineToPoint:NSMakePoint(8.0*w, 13.0*h)];
    // right point of triangle
    [arrow lineToPoint:NSMakePoint(tip, 8.0*h)];
    // bottom point of triangle
    [arrow lineToPoint:NSMakePoint(8.0*w, 3.0*h)];
    
    [arrow lineToPoint:NSMakePoint(8.0*w, 6.0*h)];
    [arrow closePath];
    
    return arrow;
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)controlView;
{
    [self drawWithFrame:frame inView:controlView alpha:1.0];
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)controlView alpha:(CGFloat)alpha;
{
    // NSCell's highlight drawing does not look correct against a dark background, so override it completely
    NSColor *bgColor = nil;
    NSColor *arrowColor = nil;
    if ([self isEnabled] == NO) {
        bgColor = [NSColor colorWithCalibratedWhite:0.3 alpha:0.5];
        arrowColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.9];
    } else if ([self isHighlighted]) {
        bgColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.8];
        arrowColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.9];
    } else {
        bgColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.7];
        arrowColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.9];
    }
        
    NSRect circleFrame = NSInsetRect(frame, 2.0, 2.0);
    NSBezierPath *circlePath = [NSBezierPath bezierPathWithOvalInRect:circleFrame];
    NSShadow *buttonShadow = [[NSShadow new] autorelease];
    [buttonShadow setShadowBlurRadius:1.5];
    [buttonShadow setShadowColor:[NSColor blackColor]];

    CGContextRef ctxt = [[NSGraphicsContext currentContext] graphicsPort];
    CGContextSaveGState(ctxt);

    CGContextSetAlpha(ctxt, alpha);
    NSRectClip(frame);
    [buttonShadow set];
    [bgColor setFill];
    [circlePath fill];
    [arrowColor setStroke];
    [circlePath setLineWidth:1.0];
    [circlePath stroke];

    CGContextTranslateCTM(ctxt, NSMinX(circleFrame), NSMinY(circleFrame));
    [arrowColor setFill];
    [[self arrowBezierPathWithSize:circleFrame.size] fill];
    
    CGContextRestoreGState(ctxt);
}

- (BOOL)trackMouse:(NSEvent *)theEvent inRect:(NSRect)cellFrame ofView:(NSView *)controlView untilMouseUp:(BOOL)untilMouseUp {
    NSPoint mouseLoc = [controlView convertPoint:[theEvent locationInWindow] fromView:nil];
    BOOL isInside = NSMouseInRect(mouseLoc, cellFrame, [controlView isFlipped]);
    if (isInside) {
		BOOL keepOn = YES;
		while (keepOn) {
            if (isInside) {
                // NSButtonCell does not highlight itself, it tracks until a click or the mouse exits
                [self highlight:YES withFrame:cellFrame inView:controlView];
                isInside = [super trackMouse:theEvent inRect:cellFrame ofView:controlView untilMouseUp:NO];
                [self highlight:NO withFrame:cellFrame inView:controlView];
                keepOn = isInside ? NO : untilMouseUp;
            }
            if (keepOn) {
                // we're dragging outside the button, wait for a mouseup or move back inside
                theEvent = [[controlView window] nextEventMatchingMask: NSLeftMouseUpMask | NSLeftMouseDraggedMask];
                mouseLoc = [controlView convertPoint:[theEvent locationInWindow] fromView:nil];
                isInside = NSMouseInRect(mouseLoc, cellFrame, [controlView isFlipped]);
                keepOn = ([theEvent type] == NSLeftMouseDragged);
            }
		}
        return isInside;
    } else 
        return NO;
}

@end
