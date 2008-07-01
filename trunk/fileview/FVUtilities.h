//
//  FVUtilities.h
//  FileView
//
//  Created by Adam Maxwell on 2/6/08.
/*
 This software is Copyright (c) 2007-2008
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

FV_PRIVATE_EXTERN const CFDictionaryKeyCallBacks FVIntegerKeyDictionaryCallBacks;
FV_PRIVATE_EXTERN const CFDictionaryValueCallBacks FVIntegerValueDictionaryCallBacks;
FV_PRIVATE_EXTERN const CFSetCallBacks FVNSObjectSetCallBacks;
FV_PRIVATE_EXTERN const CFSetCallBacks FVNSObjectPointerSetCallBacks;

// creates a timer that does not retain its target; does not schedule the timer
// selector should accept a single argument of type CFRunLoopTimerRef, as - (void)timerFired:(CFRunLoopTimerRef)tm
FV_PRIVATE_EXTERN CFRunLoopTimerRef 
FVCreateWeakTimerWithTimeInterval(CFAbsoluteTime interval, CFAbsoluteTime fireTime, id target, SEL selector);

// log to stdout without the date/app/pid gunk that NSLog appends
FV_PRIVATE_EXTERN void FVLogv(NSString *format, va_list argList);
FV_PRIVATE_EXTERN void FVLog(NSString *format, ...);

// treat an NSPasteboard as a Carbon PasteboardRef
FV_PRIVATE_EXTERN BOOL FVPasteboardHasURL(NSPasteboard *pboard);
FV_PRIVATE_EXTERN NSArray *FVURLSFromPasteboard(NSPasteboard *pboard);
FV_PRIVATE_EXTERN BOOL FVWriteURLsToPasteboard(NSArray *URLs, NSPasteboard *pboard);

// use this in +initialize when +[NSGraphicsContext currentContext] may be nil
FV_PRIVATE_EXTERN NSGraphicsContext *FVWindowGraphicsContextWithSize(NSSize size);

// returns true if it's safe to mmap() the file
FV_PRIVATE_EXTERN bool FVCanMapFileAtURL(NSURL *fileURL);

// draw round rects; NB: on Tiger, yRadius is set equal to xRadius
@interface NSBezierPath (RoundRect)
+ (NSBezierPath*)fv_bezierPathWithRoundRect:(NSRect)rect xRadius:(CGFloat)xRadius yRadius:(CGFloat)yRadius;
@end
