//
//  FVSlider.m
//  FileView
//
//  Created by Adam Maxwell on 2/17/08.
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

#import "FVSlider.h"
#import "FVUtilities.h"

NSString * const FVSliderMouseExitedNotificationName = @"FVSliderMouseExitedNotificationName";

@interface FVSliderCell : NSSliderCell
@end

@implementation FVSliderCell

- (BOOL)_usesCustomTrackImage { return YES; }

- (void)drawBarInside:(NSRect)aRect flipped:(BOOL)flipped
{
    [NSGraphicsContext saveGraphicsState];
    
    [[NSColor clearColor] setFill];
    NSRectFill(aRect);
    
    // draw a dark background
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.5] setFill];
    CGFloat radius = NSHeight(aRect) / 2;
    NSBezierPath *path = [NSBezierPath fv_bezierPathWithRoundRect:aRect xRadius:radius yRadius:radius];
    [path addClip];
    [path fill];
    
    // border highlight
    [[NSColor darkGrayColor] setStroke];
    [path setLineWidth:1.5];
    [path stroke];
    
    // draw a white outline for the track
    [[NSColor whiteColor] setStroke];
    NSRect track = NSInsetRect(aRect, NSHeight(aRect)/3, NSHeight(aRect)/3);
    path = [NSBezierPath fv_bezierPathWithRoundRect:track xRadius:3 yRadius:3];
    [path addClip];
    [path setLineWidth:1.5];
    [path stroke];
    
    // if we don't save/restore, the knob gets clipped
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawKnob:(NSRect)knobRect
{
    CGFloat inset = MAX(NSWidth(knobRect) / 6, NSHeight(knobRect) / 6);
    knobRect = NSInsetRect(knobRect, inset, inset);
    if ([[self controlView] lockFocusIfCanDraw]) {
        [NSGraphicsContext saveGraphicsState];
        [[NSColor whiteColor] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:knobRect] fill];
        [NSGraphicsContext restoreGraphicsState];
        [[self controlView] unlockFocus];
    }
}

- (id)init
{
    self = [super init];
    [self setControlSize:NSMiniControlSize];
    return self;
}

@end

@implementation FVSlider

+ (Class)cellClass { return [FVSliderCell self]; }

- (id)initWithFrame:(NSRect)aRect
{
    self = [super initWithFrame:aRect];
    if (self)
        _trackingTag = -1;
    return self;
}

- (void)drawRect:(NSRect)aRect
{
    if (-1 != _trackingTag)
        [self removeTrackingRect:_trackingTag];
    _trackingTag = [self addTrackingRect:[self bounds] owner:self userData:nil assumeInside:YES];  
    [super drawRect:aRect];
}

- (void)mouseExited:(NSEvent *)event
{
    [super mouseExited:event];
    [[NSNotificationCenter defaultCenter] postNotificationName:FVSliderMouseExitedNotificationName object:self];
}

@end

@implementation FVSliderWindow

- (id)init
{
    self = [super initWithContentRect:NSMakeRect(0,0,10,10) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:YES];
    if (self) {
        [self setReleasedWhenClosed:NO];
        [self setBackgroundColor:[NSColor clearColor]];
        [self setOpaque:NO];
        [self setHasShadow:YES];
        _slider = [[FVSlider alloc] initWithFrame:NSMakeRect(0,0,10,10)];
        [_slider setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
        [[self contentView] addSubview:_slider];
        [_slider release];
    }
    return self;
}

- (FVSlider *)slider { return _slider; }

- (id)animator
{
    return [[FVSliderWindow superclass] instancesRespondToSelector:_cmd] ? [super animator] : self;
}

// window may have been reattached by the time we get this message
- (void)safeOrderOut
{
    if (nil == [self parentWindow])
        [self orderOut:nil];
}

- (void)fadeOut
{
    NSAssert(nil == [self parentWindow], @"attempt to fade active child window");
    [[self animator] setAlphaValue:0.0];
    [self performSelector:@selector(safeOrderOut) withObject:nil afterDelay:0.5];
}

@end
