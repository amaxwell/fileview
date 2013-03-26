//
//  FVPreviewer.h
//  FileViewTest
//
//  Created by Adam Maxwell on 09/01/07.
/*
 This software is Copyright (c) 2007-2012
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
#import <Quartz/Quartz.h>

/** Notification posted when the window closes.
 @warning This is a temporary hack for FileView internals, and must not be relied on! */
FV_PRIVATE_EXTERN NSString * const FVPreviewerWillCloseNotification FV_HIDDEN;

@class FVScaledImageView, QTMovieView, PDFView, WebView;
/** FVPreviewer displays and manages a single-window preview.
 
 Quick Look is one of the great new features in Mac OS X Leopard.  Unfortunately, it doesn't allow copy-paste from text windows (including PDF).  While understandable in some respects, it's a serious limitation.  FVPreviewer uses Quick Look as a fallback on 10.5, and uses a pseudo-Quick Look the rest of the time (which allows copy-paste).  The list of supported types is essentially the union of all types supported by FVIcon and all types supported by Quick Look.
 
 Note that using FVPreviewer implies some risk due to using qlmanage to display the previewer window, also: http://lists.apple.com/archives/quicklook-dev/2008/Jun/msg00020.html gives some reasons for not doing this.  In the absence of a real API, it's presently the best workaround, since I do not consider linking against a private framework an acceptable alternative. 
 
 Note for 10.6: now that the Quick Look panel has a real API, qlmanage should only be used on 10.5.  Messing with the responder chain in FVPreviewer was too problematic to use it for control of the QLPreviewPanel, and the delegate/datasource implementation was much better suited to FileView itself.  Hence, FVPreviewer now has the role of a fallback viewer only.
 
 */

#if MAC_OS_X_VERSION_10_6 && (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6)
@interface FVPreviewer : NSWindowController <NSAnimationDelegate> {
#else
@interface FVPreviewer : NSWindowController <NSAnimationDelegate> {
#endif
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
    BOOL                       windowLoaded;
    NSTask                     *qlTask;
    NSURL                      *currentURL;
    BOOL                        closeAfterAnimation;
}

/** Shared instance.
 
 @warning FVPreviewer may only be used on the main thread, due to usage of various Cocoa views. */
+ (FVPreviewer *)sharedPreviewer;

/** Determine if Quick Look will/should be used.
 
 Currently returns NO for non-file: URLs, and documents that can be loaded in PDFView or NSTextView, since those views allow copying whereas Quick Look's raster preview does not.  Returns YES for all other types.  Use this in a controller to determine if FVPreviewer or QLPreviewPanel should be used (on 10.4 and 10.5, FVPreviewer should always be used).  FVPreviewer will still function on 10.6, as well, regardless of what this method returns.
 
 @return YES if FVPreviewer would use qlmanage for previewing. */
+ (BOOL)useQuickLookForURL:(NSURL *)aURL;

/** Display a preview for a single URL.
 @deprecated Clients should use FVPreviewer::previewURL:forIconInRect: instead, passing NSZeroRect for @a screenRect.
 @param absoluteURL Any URL that can be displayed (see FVPreviewer class notes). */
- (void)previewURL:(NSURL *)absoluteURL DEPRECATED_ATTRIBUTE;

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
 @param screenRect The rect of the icon to display, in screen coordinates.  Pass NSZeroRect to use the center of the main screen. */
- (void)previewURL:(NSURL *)absoluteURL forIconInRect:(NSRect)screenRect;

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
/** For Interface Builder only.
 @warning Do not call directly. */
- (void)toggleFullscreen:(id)sender;
#endif

/** Cancel preview or fullscreen.
 
 If full screen window is displayed, will transition to normal window.  If normal window is displayed, will close previewer. */
- (void)cancel:(id)sender;

@end
