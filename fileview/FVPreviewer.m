//
//  FVPreviewer.m
//  FileViewTest
//
//  Created by Adam Maxwell on 09/01/07.
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

#import <FileView/FVPreviewer.h>
#import "FVScaledImageView.h"
#import <Quartz/Quartz.h>
#import <QTKit/QTKit.h>
#import <WebKit/WebKit.h>
#import <pthread.h>

#define USE_LAYER_BACKING 0

@implementation FVPreviewer

+ (FVPreviewer *)sharedPreviewer;
{
    FVAPIAssert(pthread_main_np() != 0, @"FVPreviewer must only be used on the main thread");
    static id sharedInstance = nil;
    if (nil == sharedInstance)
        sharedInstance = [[self alloc] init];
    return sharedInstance;
}

- (id)init
{
    // initWithWindowNibName searches the class' bundle automatically
    self = [super initWithWindowNibName:[self windowNibName]];
    if (self) {
        // window is now loaded lazily, but we have to use a flag to avoid a hit when calling isPreviewing
        windowLoaded = NO;
    }
    return self;
}

- (BOOL)isPreviewing;
{
    return (windowLoaded && ([[self window] isVisible] || [qlTask isRunning]));
}

- (void)setWebViewContextMenuDelegate:(id)anObject;
{
    webviewContextMenuDelegate = anObject;
}

- (NSString *)windowFrameAutosaveName;
{
    return @"FileView preview window frame";
}

- (NSRect)savedFrame
{
    NSString *savedFrame = [[NSUserDefaults standardUserDefaults] objectForKey:[self windowFrameAutosaveName]];
    return (nil == savedFrame) ? NSZeroRect : NSRectFromString(savedFrame);
}

- (void)windowDidLoad
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // Finder hides QL when it loses focus, then restores when it regains it; we can't do that easily, so just get rid of it
    [nc addObserver:self selector:@selector(stopPreview:) name:NSApplicationWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(stopPreview:) name:NSApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(stopPreview:) name:NSApplicationWillTerminateNotification object:nil];
    
    windowLoaded = YES;
}

- (void)awakeFromNib
{
    // revert to the previously saved size, or whatever was set in the nib
    [self setWindowFrameAutosaveName:@""];
    [[self window] setFrameAutosaveName:@""];

    NSRect savedFrame = [self savedFrame];
    if (NSEqualRects(savedFrame, NSZeroRect))
        [[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect([[self window] frame]) forKey:[self windowFrameAutosaveName]];
    
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4) {
        [[fullScreenButton cell] setBackgroundStyle:NSBackgroundStyleDark];
        [fullScreenButton setImage:[NSImage imageNamed:NSImageNameEnterFullScreenTemplate]];
        [fullScreenButton setAlternateImage:[NSImage imageNamed:NSImageNameExitFullScreenTemplate]];
        
        // only set delegate on alpha animation, since we only need the delegate callback once
        CABasicAnimation *fadeAnimation = [CABasicAnimation animationWithKeyPath:@"alphaValue"];
        [fadeAnimation setDelegate:self];
        
        NSMutableDictionary *animations = [NSMutableDictionary dictionary];
        [animations addEntriesFromDictionary:[[self window] animations]];
        [animations setObject:fadeAnimation forKey:@"alphaValue"];
        
        [[self window] setAnimations:animations];
    }
    else {
        [fullScreenButton removeFromSuperview];
        fullScreenButton = nil;
        [contentView setFrame:[[[self window] contentView] frame]];
    }
}

- (void)windowWillClose:(NSNotification *)notification
{
    [self setWebViewContextMenuDelegate:nil];
}

- (NSWindow *)windowAnimator
{
    NSWindow *theWindow = [self window];
    return [theWindow respondsToSelector:@selector(animator)] ? [theWindow animator] : theWindow;
}

- (void)animationDidStop:(CAPropertyAnimation *)anim finished:(BOOL)flag;
{
    if (flag && [[self window] alphaValue] < 0.01) {
        [[self window] close];
    }
    else {
        [contentView selectFirstTabViewItem:nil];
        // highlight around button isn't drawn unless the window is key, which happens randomly unless we force it here
        [[self window] makeKeyAndOrderFront:nil];
        [[self window] makeFirstResponder:fullScreenButton];
    }
#if USE_LAYER_BACKING
    [[[self window] contentView] setWantsLayer:NO];
#endif
}

- (BOOL)windowShouldClose:(id)sender
{
    [[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect([[self window] frame]) forKey:[self windowFrameAutosaveName]];
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4) {
        // make sure it doesn't respond to keystrokes while fading out
        [[self window] makeFirstResponder:nil];
        // image is now possibly out of sync due to scrolling/resizing
        NSView *currentView = [[contentView tabViewItemAtIndex:0] view];
        NSBitmapImageRep *imageRep = [currentView bitmapImageRepForCachingDisplayInRect:[currentView bounds]];
        [currentView cacheDisplayInRect:[currentView bounds] toBitmapImageRep:imageRep];
        NSImage *image = [[NSImage alloc] initWithSize:[imageRep size]];
        [image addRepresentation:imageRep];
        [animationView setImage:image];
        [image release];
        [contentView selectLastTabViewItem:nil];
#if USE_LAYER_BACKING
        [[[self window] contentView] setWantsLayer:YES];
        [[self window] display];
#endif
        [NSAnimationContext beginGrouping];
        [[self windowAnimator] setAlphaValue:0.0];
        // shrink back to the icon frame
        if (NSIsEmptyRect(previousIconFrame) == NO)
            [[self windowAnimator] setFrame:previousIconFrame display:YES];
        [NSAnimationContext endGrouping];
        return NO;
    }
    return YES;
}

- (void)_killTask
{
    [qlTask terminate];
    // wait until the task actually exits, or we can end up launching a new task before this one quits (happened when duplicate KVO notifications were sent)
    [qlTask waitUntilExit];
    [qlTask release];
    qlTask = nil;    
}

- (void)stopPreviewing;
{
    [self _killTask];

    if (windowLoaded && [[self window] isVisible]) {
        
        if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4 && [[[self window] contentView] isInFullScreenMode]) {
            [[[self window] contentView] exitFullScreenModeWithOptions:nil];
            [[fullScreenButton cell] setBackgroundStyle:NSBackgroundStyleDark];
        }
        
        // performClose: invokes windowShouldClose: and then closes the window, so state gets saved
        [[self window] performClose:nil];
        [self setWebViewContextMenuDelegate:nil];
    }    
}

- (void)stopPreview:(NSNotification *)note
{
    [self stopPreviewing];
}

- (NSString *)windowNibName { return @"FVPreviewer"; }

static NSData *PDFDataWithPostScriptDataAtURL(NSURL *aURL)
{
    NSData *psData = [[NSData alloc] initWithContentsOfURL:aURL options:NSMappedRead error:NULL];
    CGPSConverterCallbacks converterCallbacks = { 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL };
    CGPSConverterRef converter = CGPSConverterCreate(NULL, &converterCallbacks, NULL);
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)psData);
    [psData release];
    
    CFMutableDataRef pdfData = CFDataCreateMutable(CFGetAllocator((CFDataRef)psData), 0);
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(pdfData);
    Boolean success = CGPSConverterConvert(converter, provider, consumer, NULL);
    
    CGDataProviderRelease(provider);
    CGDataConsumerRelease(consumer);
    CFRelease(converter);
    
    if(success == FALSE){
        CFRelease(pdfData);
        pdfData = nil;
    }
    
    return [(id)pdfData autorelease];
}

- (void)_loadAttributedString:(NSAttributedString *)string documentAttributes:(NSDictionary *)attrs inView:(NSTextView *)theView
{
    NSTextStorage *textStorage = [theView textStorage];
    [textStorage setAttributedString:string];
    NSColor *backgroundColor = nil;
    if (nil == attrs || [[attrs objectForKey:NSDocumentTypeDocumentAttribute] isEqualToString:NSPlainTextDocumentType]) {
        NSFont *plainFont = [NSFont userFixedPitchFontOfSize:10.0f];
        [textStorage addAttribute:NSFontAttributeName value:plainFont range:NSMakeRange(0, [textStorage length])];
    }
    else {
        backgroundColor = [attrs objectForKey:NSBackgroundColorDocumentAttribute];
    }
    if (nil == backgroundColor)
        backgroundColor = [NSColor whiteColor];
    [theView setBackgroundColor:backgroundColor];    
}

- (NSView *)contentViewForURL:(NSURL *)representedURL shouldUseQuickLook:(BOOL *)shouldUseQuickLook;
{
    // general case
    *shouldUseQuickLook = NO;
    
    // early return
    NSSet *webviewSchemes = [NSSet setWithObjects:@"http", @"https", @"ftp", nil];
    if ([representedURL scheme] && [webviewSchemes containsObject:[representedURL scheme]]) {
        [webView setFrameLoadDelegate:self];
        
        // wth? why doesn't WebView accept an NSURL?
        if ([webView respondsToSelector:@selector(setMainFrameURL:)]) {
            [webView setMainFrameURL:[representedURL absoluteString]];
        }
        else {
            [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:representedURL]];
        }

        return webView;
    }
    
    // everything from here on safely assumes a file URL
    
    OSStatus err = noErr;
    
    FSRef fileRef;
    
    // return nil if we can't resolve the path
    if (FALSE == CFURLGetFSRef((CFURLRef)representedURL, &fileRef))
        err = fnfErr;
    
    // kLSItemContentType returns a CFStringRef, according to the header
    CFTypeRef theUTI = NULL;
    if (noErr == err)
        err = LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, &theUTI);
    [(id)theUTI autorelease];
    
    NSView *theView = nil;
    
    // we get this for e.g. doi or unrecognized schemes; let FVIcon handle those
    if (fnfErr == err) {
        theView = imageView;
        [(FVScaledImageView *)theView displayImageAtURL:representedURL];
    }
    else if (nil == theUTI || UTTypeEqual(theUTI, kUTTypeData)) {
        theView = textView;
        NSDictionary *attrs;
        NSAttributedString *string = [[NSAttributedString alloc] initWithURL:representedURL documentAttributes:&attrs];
        if (string)
            [self _loadAttributedString:string documentAttributes:attrs inView:[textView documentView]];
        else
            theView = nil;
        [string release]; 
    }
    else if (UTTypeConformsTo(theUTI, kUTTypePDF)) {
        theView = pdfView;
        PDFDocument *pdfDoc = [[PDFDocument alloc] initWithURL:representedURL];
        [pdfView setDocument:pdfDoc];
        [pdfDoc release];
    }
    else if (UTTypeConformsTo(theUTI, FVSTR("com.adobe.postscript"))) {
        theView = pdfView;
        PDFDocument *pdfDoc = [[PDFDocument alloc] initWithData:PDFDataWithPostScriptDataAtURL(representedURL)];
        [pdfView setDocument:pdfDoc];
        [pdfDoc release];         
    }
    else if (UTTypeConformsTo(theUTI, kUTTypeImage)) {
        theView = imageView;
        [(FVScaledImageView *)theView displayImageAtURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypeAudiovisualContent)) {
        // use A/V content instead of just movie, since audio is fair game for the preview
        QTMovie *movie = [[QTMovie alloc] initWithURL:representedURL error:NULL];
        if (nil != movie) {
            theView = movieView;
            [movieView setMovie:movie];
            [movie release];
        }
    }
    else if (UTTypeConformsTo(theUTI, FVSTR("public.composite-content")) || UTTypeConformsTo(theUTI, kUTTypeText)) {
        theView = textView;
        NSDictionary *attrs;
        NSAttributedString *string = [[NSAttributedString alloc] initWithURL:representedURL documentAttributes:&attrs];
        if (string)
            [self _loadAttributedString:string documentAttributes:attrs inView:[textView documentView]];
        else
            theView = nil;
        [string release]; 
    }
    
    // probably just a Finder icon, but NSWorkspace returns a crappy little icon (so use Quick Look if possible)
    if (nil == theView) {
        theView = imageView;
        [(FVScaledImageView *)theView displayIconForURL:representedURL];
        *shouldUseQuickLook = YES;
    }

    return theView;
    
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    [spinner stopAnimation:nil];
    [spinner removeFromSuperview];
}

- (void)webView:(WebView *)sender didStartProvisionalLoadForFrame:(WebFrame *)frame
{
    const CGFloat spinnerSideLength = 32;
    WebFrame *mainFrame = [webView mainFrame];
    if (nil == spinner) {
        spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, spinnerSideLength, spinnerSideLength)];
        [spinner setStyle:NSProgressIndicatorSpinningStyle];
        [spinner setUsesThreadedAnimation:YES];
        [spinner setDisplayedWhenStopped:NO];
        [spinner setControlSize:NSRegularControlSize];
    }
    if ([spinner isDescendantOf:[mainFrame frameView]] == NO) {
        [spinner removeFromSuperview];
        NSRect wvFrame = [[mainFrame frameView] frame];
        NSRect spFrame;
        spFrame.origin.x = wvFrame.origin.x + (wvFrame.size.width - spinnerSideLength) / 2;
        spFrame.origin.y = wvFrame.origin.y + (wvFrame.size.height - spinnerSideLength) / 2;
        spFrame.size = NSMakeSize(spinnerSideLength, spinnerSideLength);
        [spinner setFrame:spFrame];
        [spinner setAutoresizingMask:(NSViewMinXMargin|NSViewMinYMargin|NSViewMaxXMargin|NSViewMaxYMargin)];
        [[mainFrame frameView] addSubview:spinner];
    }
    [spinner startAnimation:nil];
}

- (NSArray *)webView:(WebView *)sender contextMenuItemsForElement:(NSDictionary *)element defaultMenuItems:(NSArray *)defaultMenuItems
{
    if ([webviewContextMenuDelegate respondsToSelector:_cmd]) {
        return [webviewContextMenuDelegate webView:sender contextMenuItemsForElement:element defaultMenuItems:defaultMenuItems];
    } else {
        NSMutableArray *items = [NSMutableArray array];
        NSEnumerator *itemEnum = [defaultMenuItems objectEnumerator];
        NSMenuItem *item;
        while ((item = [itemEnum nextObject])) {
            NSInteger tag = [item tag];
            if (tag == WebMenuItemTagCopyLinkToClipboard || tag == WebMenuItemTagCopyImageToClipboard || tag == WebMenuItemTagCopy || tag == WebMenuItemTagGoBack || tag == WebMenuItemTagGoForward || tag == WebMenuItemTagStop || tag == WebMenuItemTagReload || tag == WebMenuItemTagOther)
                [items addObject:item];
        }
        return items;
    }
}

- (void)previewFileURLs:(NSArray *)absoluteURLs;
{
    previousIconFrame = NSZeroRect;
    
    [self _killTask];
    
    NSMutableArray *paths = [NSMutableArray array];
    NSUInteger cnt = [absoluteURLs count];
    
    // ignore non-file URLs; this isn't technically necessary for our pseudo-Quick Look, but it's consistent
    while (cnt--) {
        if ([[absoluteURLs objectAtIndex:cnt] isFileURL])
            [paths insertObject:[[absoluteURLs objectAtIndex:cnt] path] atIndex:0];
    }
    
    if ([paths count] && [[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/bin/qlmanage"]) {
        
        NSMutableArray *args = paths;
        [args insertObject:@"-p" atIndex:0];
        NSParameterAssert(nil == qlTask);
        qlTask = [[NSTask alloc] init];
        @try {
            [qlTask setLaunchPath:@"/usr/bin/qlmanage"];
            [qlTask setArguments:args];
            // qlmanage is really verbose, so don't fill the log with its spew
            [qlTask setStandardError:[NSFileHandle fileHandleWithNullDevice]];
            [qlTask setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
            [qlTask launch];
        }
        @catch(id exception) {
            NSLog(@"Unable to run qlmanage: %@", exception);
        }
    }
    else if([paths count]) {
        [self previewURL:[NSURL fileURLWithPath:[paths objectAtIndex:0]] forIconInRect:[[self window] frame]];
    }
}

- (void)_previewURL:(NSURL *)absoluteURL animateFrame:(BOOL)shouldAnimate
{
    [self _killTask];
        
    BOOL shouldUseQuickLook;
    NSView *newView = [self contentViewForURL:absoluteURL shouldUseQuickLook:&shouldUseQuickLook];
    
    // Quick Look (qlmanage) handles more types than our setup, but you can't copy any content from PDF/text sources, which sucks; hence, we only use it as a fallback (basically a replacement for FVScaledImageView).  There are some slight behavior mismatches, and we lose fullscreen (I think), but that's minor in comparison.
    if (shouldUseQuickLook && [absoluteURL isFileURL] && [[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/bin/qlmanage"]) {
        
        if ([[self window] isVisible])
            [[self window] performClose:self];
        
        NSParameterAssert(nil == qlTask);
        qlTask = [[NSTask alloc] init];
        @try {
            [qlTask setLaunchPath:@"/usr/bin/qlmanage"];
            [qlTask setArguments:[NSArray arrayWithObjects:@"-p", [absoluteURL path], nil]];
            // qlmanage is really verbose, so don't fill the log with its spew
            [qlTask setStandardError:[NSFileHandle fileHandleWithNullDevice]];
            [qlTask setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
            [qlTask launch];
        }
        @catch(id exception) {
            NSLog(@"Unable to run qlmanage: %@", exception);
        }
    }
    else {
        NSWindow *theWindow = [self window];
        
        if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4)
            [theWindow setAlphaValue:0.0];
        [[contentView tabViewItemAtIndex:0] setView:newView];

        // it's annoying to recenter if this is just in response to a selection change or something
        if (NO == [theWindow isVisible] && NO == shouldAnimate)
            [theWindow center];
        
        if ([absoluteURL isFileURL]) {
            [theWindow setTitleWithRepresentedFilename:[absoluteURL path]];
        }
        else {
            // raises on nil
            [theWindow setTitleWithRepresentedFilename:@""];
        }

        // don't reset the window frame if it's already on-screen
        NSRect newWindowFrame = [theWindow isVisible] ? [theWindow frame] : [self savedFrame];
        if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4) {
            
            [[self window] makeKeyAndOrderFront:nil];

            if (shouldAnimate && NO == NSEqualRects(newWindowFrame, NSZeroRect)) {
                // select the new view and set the window's frame in order to get the view's new frame
                [contentView selectFirstTabViewItem:nil];
                NSRect oldWindowFrame = [[self window] frame];
                [[self window] setFrame:newWindowFrame display:YES];
                
                // cache the new view to an image
                NSBitmapImageRep *imageRep = [newView bitmapImageRepForCachingDisplayInRect:[newView bounds]];
                [newView cacheDisplayInRect:[newView bounds] toBitmapImageRep:imageRep];
                [[self window] setFrame:oldWindowFrame display:NO];
                NSImage *image = [[NSImage alloc] initWithSize:[imageRep size]];
                [image addRepresentation:imageRep];
                [animationView setImage:image];
                [image release];

#if USE_LAYER_BACKING
                // now select the animation view and start animating
                [[[self window] contentView] setWantsLayer:YES];
                [(NSView *)[[self window] contentView] display];
#endif
                [contentView selectLastTabViewItem:nil];

                [NSAnimationContext beginGrouping];
                [[self windowAnimator] setFrame:newWindowFrame display:YES];
                [[self windowAnimator] setAlphaValue:1.0];
                [NSAnimationContext endGrouping];
            }
            else {
                // no animation or frame was set to zero rect (if not previously in defaults database)
                [[self windowAnimator] setAlphaValue:1.0];
            }
        }
        else {
            [[self window] setFrame:newWindowFrame display:YES animate:shouldAnimate];
            [self showWindow:self];
        }
    }
}

- (void)previewURL:(NSURL *)absoluteURL forIconInRect:(NSRect)screenRect
{
    FVAPIParameterAssert(nil != absoluteURL);
    BOOL animate = YES;
    
    if (NSEqualRects(screenRect, NSZeroRect)) {
        // set up a rect in the middle of the main screen for a default value
        previousIconFrame = NSZeroRect;
        screenRect.size = NSMakeSize(128, 128);
        NSRect visibleFrame = [[NSScreen mainScreen] visibleFrame];
        screenRect.origin = NSMakePoint(NSMidX(visibleFrame) - NSWidth(screenRect) / 2, NSMidY(visibleFrame) - NSHeight(screenRect) / 2);
        animate = NO;
    }
    else if (NSHeight(screenRect) < 128 || NSWidth(screenRect) < 128) {
        screenRect.size.height = 128;
        screenRect.size.width = 128;
    }
    previousIconFrame = screenRect;
    [[self window] setFrame:screenRect display:NO];
    [self _previewURL:absoluteURL animateFrame:animate];
}

- (void)previewURL:(NSURL *)absoluteURL;
{
    FVAPIParameterAssert(nil != absoluteURL);
    [self previewURL:absoluteURL forIconInRect:NSZeroRect];
}

- (void)previewAction:(id)sender 
{
    [self stopPreview:nil];
}

- (void)toggleFullscreen:(id)sender
{
    FVAPIAssert(floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4, @"Full screen is only available on 10.5 and later");
    if ([[[self window] contentView] isInFullScreenMode]) {
        [[[self window] contentView] exitFullScreenModeWithOptions:nil];
        [[fullScreenButton cell] setBackgroundStyle:NSBackgroundStyleDark];
    }
    else {
        [[[self window] contentView] enterFullScreenMode:[[self window] screen] withOptions:nil];
        [[fullScreenButton cell] setBackgroundStyle:NSBackgroundStyleLight];
    }
}

// esc is typically bound to complete: instead of cancel: in a textview
- (BOOL)textView:(NSTextView *)aTextView doCommandBySelector:(SEL)aSelector
{
    if (@selector(cancel:) == aSelector || @selector(complete:) == aSelector) {
        [self stopPreviewing];
        return YES;
    }
    return NO;
}

// end up getting this via the responder chain for most views
- (void)cancel:(id)sender
{
    [self stopPreviewing];
}    


@end
