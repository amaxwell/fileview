//
//  FVPreviewer.h
//  FileViewTest
//
//  Created by Adam Maxwell on 09/01/07.
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

@class FVScaledImageView, QTMovieView, PDFView, WebView;

@interface FVPreviewer : NSWindowController {
@private;
    IBOutlet NSTabView         *contentView;
    IBOutlet NSImageView       *animationView;
    IBOutlet QTMovieView       *movieView;
    IBOutlet PDFView           *pdfView;
    IBOutlet NSScrollView      *textView;
    IBOutlet WebView           *webView;
    IBOutlet FVScaledImageView *imageView;
    IBOutlet NSButton          *fullScreenButton;
    NSProgressIndicator        *spinner;
    id                         webviewContextMenuDelegate;
    NSRect                     previousIconFrame;
    
    NSTask                     *qlTask;
}

+ (id)sharedPreviewer;

// this uses Quick Look as a fallback on 10.5, and uses our pseudo-Quick Look the rest of the time (which allows copy-paste)
- (void)previewURL:(NSURL *)absoluteURL DEPRECATED_ATTRIBUTE;

// on 10.5, this uses Quick Look unconditionally to preview all items, so you get the cool slideshow features (but no copy-paste)
// on 10.4, it just previews the first URL in the list
// non file: URLs are ignored in either case
- (void)previewFileURLs:(NSArray *)absoluteURLs;

// returns YES if QL preview is on screen or the custom preview window is showing
- (BOOL)isPreviewing;
// implemented to send -stopPreviewing if previewer window is the first responder
- (void)previewAction:(id)sender;
// may need to send this manually if the QL preview is showing (-isPreviewing returns YES)
- (void)stopPreviewing;
- (void)setWebViewContextMenuDelegate:(id)anObject;

- (void)previewURL:(NSURL *)absoluteURL forIconInRect:(NSRect)screenRect;

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
- (void)toggleFullscreen:(id)sender;
#endif

@end
