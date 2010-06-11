//
//  _FVPreviewerWindow.m
//  FileView
//
//  Created by Adam R. Maxwell on 12/15/09.
/*
 This software is Copyright (c) 2009-2010
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

#import "_FVPreviewerWindow.h"
#import "FVUtilities.h"
#import <IOKit/hidsystem/event_status_driver.h>

@implementation _FVPreviewerWindow

static CGEventRef __FVPreviewWindowMouseDown(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    _FVPreviewerWindow *self = refcon;
    
    if (CGRectContainsPoint(NSRectToCGRect([self frame]), CGEventGetUnflippedLocation(event))) {
        
        // See header for GetDblTime.  Getting kCGMouseEventClickState didn't work.
        NXEventHandle handle = NXOpenEventStatus();
        double clickTime = NXClickTime(handle);
        NXCloseEventStatus(handle);

        NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
        /*
         If the first two clicks represent a double-click, treat it as a request to open
         the file.  Otherwise, assume that this event and all subsequent events are for
         text selection.
         */
        if (1 == self->_clickCount && (currentTime - self->_lastClickTime) <= clickTime) {

            NSCParameterAssert([[self delegate] respondsToSelector:@selector(doubleClickedPreviewWindow)]);
            [[self delegate] performSelector:@selector(doubleClickedPreviewWindow)];

        }
        else if (0 == self->_clickCount) {
                        
            // this allows selection to work immediately
            [self makeKeyAndOrderFront:nil];
        }
        self->_lastClickTime = currentTime;
        self->_clickCount += 1;

    }
    return event;
}

- (void)listenForMouseDown
{
    if (NULL == _mouseDownSource) {
        assert(NULL == _mouseDownTap);
        ProcessSerialNumber psn;
        GetProcessForPID(getpid(), &psn);
        
        _lastClickTime = 0;
        _clickCount = 0;
        
        _mouseDownTap = CGEventTapCreateForPSN(&psn, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, kCGEventLeftMouseDown|kCGEventRightMouseDown|kCGEventOtherMouseDown, __FVPreviewWindowMouseDown, self);
        _mouseDownSource = CFMachPortCreateRunLoopSource(CFAllocatorGetDefault(), _mouseDownTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), _mouseDownSource, kCFRunLoopDefaultMode);
    }
}

- (void)stopListening
{
    if (_mouseDownSource) {
        CFRunLoopSourceInvalidate(_mouseDownSource);
        CFRelease(_mouseDownSource);
        _mouseDownSource = NULL;
    }
    
    if (_mouseDownTap) {
        CFMachPortInvalidate(_mouseDownTap);
        CFRelease(_mouseDownTap);
        _mouseDownTap = NULL;
    }
}

- (void)resetKeyStatus;
{
    // keep listening; window's content has just changed
    _clickCount = 0;
}

- (void)close
{
    [self resetKeyStatus];
    [self stopListening];
    [super close];
}

- (void)dealloc
{
    [self stopListening];
    [super dealloc];
}

- (BOOL)canBecomeKeyWindow { return _clickCount; }

- (BOOL)makeFirstResponder:(NSResponder *)aResponder 
{ 
    BOOL ret = [super makeFirstResponder:aResponder];
    if (ret) [self listenForMouseDown]; 
    return ret;
}

@end
