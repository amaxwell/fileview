//
//  _FVPreviewerWindow.h
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

#import <Cocoa/Cocoa.h>

/** @internal @brief Window subclass for the previewer.
 
 The Quick Look panel allows the controlling responder/view to remain key, practically.  The best
 way to handle this in the custom preview is to return NO from NSWindow::canBecomeKeyWindow, but
 that breaks text selection in views.  Since text selection is the only reason for using this as
 a substitute for the real thing on 10.5 and later, we need to allow text selection.
 
 This class installs a CGEventTap listening for mouse down events in its process, and returns YES
 for NSWindow::canBecomeKeyWindow after a mouse down.  The controller needs to reset this periodically,
 as a change in content without dismissing the window should also reset the canBecomeKeyWindow flag.
 
 I originally tried saving and restoring NSApp::keyWindow when showing the panel, but that required
 a delay to work around the animation, which makes the fullscreen button first responder after the
 animation completes (regardless of NSButton::refusesFirstResponder returning NO).
 */
@interface _FVPreviewerWindow : NSPanel
{
@private
    BOOL               _didClickWindow;
    CFRunLoopSourceRef _mouseDownSource;
    CFMachPortRef      _mouseDownTap;
}

/** @internal Call as needed to return NO for NSWindow::canBecomeKeyWindow. */
- (void)resetKeyStatus;

@end
