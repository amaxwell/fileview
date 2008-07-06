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
/** FVPreviewer displays and manages a single-window preview.
 
 Quick Look is one of the great new features in Mac OS X Leopard.  Unfortunately, it doesn't allow copy-paste from text windows (including PDF).  While understandable in some respects, it's a serious limitation.  FVPreviewer uses Quick Look as a fallback on 10.5, and uses a pseudo-Quick Look the rest of the time (which allows copy-paste).  The list of supported types is essentially the union of all types supported by FVIcon and all types supported by Quick Look.
 
 Note that using FVPreviewer implies some risk due to using qlmanage to display the previewer window, also: http://lists.apple.com/archives/quicklook-dev/2008/Jun/msg00020.html gives some reasons for not doing this.  In the absence of a real API, it's presently the best workaround, since I do not consider linking against a private framework an acceptable alternative. */
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

/** Shared instance.
 
 @warning FVPreviewer may only be used on the main thread, due to usage of various Cocoa views. */
+ (id)sharedPreviewer;

/** Display a preview of multiple URLs.
 
 On 10.5, this uses Quick Look unconditionally to preview all items, so you get the cool slideshow features (but no copy-paste).  On 10.4, it just previews the first URL in the list.
 @param absoluteURLs A list of URLs to display.  Non-file: URLs are ignored. */
- (void)previewFileURLs:(NSArray *)absoluteURLs;

/** Test to see if the previewer is active.
 @return YES if QL preview is on screen or the custom preview window is showing. */
- (BOOL)isPreviewing;

/** Override of FileView::previewAction:
 This is implemented to send FVPreviewer::stopPreviewing: if the previewer window is the first responder.  You should never call this method directly. */
- (void)previewAction:(id)sender;

/** Close the previewer window.
 You may need to send this manually if the Quick Look preview is showing (i.e. FVPreviewer::isPreviewing returns YES). */
- (void)stopPreviewing;

/** Set a WebView contextual menu delegate.
 Delegate methods for the WebView context menu will be forwarded to this object, which may be useful for e.g. custom downloading. 
 @param anObject Not retained. */
- (void)setWebViewContextMenuDelegate:(id)anObject;

/** Primary API for displaying the preview window.
 
 This is the primary interface for previewing a single URL.  It correctly (FSVO correctly) handles transitions between icon rects and view animations.  It also chooses the appropriate view for the given URL.
 @param absoluteURL Any URL that can be displayed (see FVPreviewer class notes).
 @param screenRect The rect of the icon to display, in screen coordinates. */
- (void)previewURL:(NSURL *)absoluteURL forIconInRect:(NSRect)screenRect;

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
/** For Interface Builder only.
 @warning Do not call directly. */
- (void)toggleFullscreen:(id)sender;
#endif

@end
