//
//  FVWebViewIcon.m
//  FileView
//
//  Created by Adam Maxwell on 12/30/07.
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

#import "FVWebViewIcon.h"
#import "FVFinderIcon.h"
#import "FVMIMEIcon.h"
#import <WebKit/WebKit.h>

@interface WebView (FVExtensions)
- (BOOL)fv_isLoading;
@end

@implementation WebView (FVExtensions)

- (BOOL)fv_isLoading;
{
    // available in 10.4.11 and later
    if ([self respondsToSelector:@selector(isLoading)])
        return [self isLoading];
    
    // Modified from http://trac.webkit.org/browser/trunk/WebKit/mac/WebView/WebView.mm implementation of -[WebView _isLoading].
    WebFrame *mainFrame = [self mainFrame];
    return [[mainFrame dataSource] isLoading] || [[mainFrame provisionalDataSource] isLoading];
}

@end

@implementation FVWebViewIcon

// webview pool variables to keep memory usage down; pool size is tunable
static NSInteger       _maxWebViews = 5;
static NSMutableArray *_availableWebViews = nil;
static NSMutableArray *_activeWebViews = nil;
static NSInteger       _numberOfWebViews = 0;
static NSString * const FVWebIconWebViewAvailableNotificationName = @"FVWebIconWebViewAvailableNotificationName";

static NSSet          *_webViewSchemes = nil;

// size of the view frame; large enough to fit a reasonably sized page
static const NSSize _webViewSize = { 1000, 900 };

#define IDLE    0
#define LOADING 1
#define LOADED  2

+ (void)initialize
{
    FVINITIALIZE(FVWebViewIcon);

    NSInteger maxViews = [[NSUserDefaults standardUserDefaults] integerForKey:@"FVWebIconMaximumNumberOfWebViews"];
    if (maxViews > 0)
        _maxWebViews = maxViews;
    
    _availableWebViews = [[NSMutableArray alloc] initWithCapacity:_maxWebViews];
    _activeWebViews = [[NSMutableArray alloc] initWithCapacity:_maxWebViews];
    _webViewSchemes = [[NSSet alloc] initWithObjects:@"http", @"https", @"ftp", nil];
}

// return nil if _maxWebViews is exceeded
+ (WebView *)popWebView 
{
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));
    FVAPIAssert((NSInteger)[_availableWebViews count] + (NSInteger)[_activeWebViews count] == _numberOfWebViews, @"webview cache inconsistency");
    WebView *nextView = nil;
    if ([_availableWebViews count]) {
        nextView = [_availableWebViews lastObject];
        [_activeWebViews addObject:nextView];
        [_availableWebViews removeLastObject];
    }
    else if (_numberOfWebViews <= _maxWebViews) {
        nextView = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, _webViewSize.width, _webViewSize.height)];
        [_activeWebViews addObject:nextView];
        [nextView release];
        _numberOfWebViews++;
    }
    FVAPIAssert((NSInteger)[_availableWebViews count] + (NSInteger)[_activeWebViews count] == _numberOfWebViews, @"webview cache inconsistency");
    return nextView;
}

+ (void)pushWebView:(WebView *)aView
{
    FVAPIParameterAssert(nil != aView);
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));
    FVAPIAssert((NSInteger)[_availableWebViews count] + (NSInteger)[_activeWebViews count] == _numberOfWebViews, @"webview cache inconsistency");
    [_availableWebViews insertObject:aView atIndex:0];
    [_activeWebViews removeObject:aView];
    FVAPIAssert((NSInteger)[_availableWebViews count] + (NSInteger)[_activeWebViews count] == _numberOfWebViews, @"webview cache inconsistency");
    [[NSNotificationCenter defaultCenter] postNotificationName:FVWebIconWebViewAvailableNotificationName object:self];
}

- (id)initWithURL:(NSURL *)aURL;
{    
    NSParameterAssert(nil != [aURL scheme]);
    
    // if this is not an http or file URL, return a finder icon instead
    if (NO == [_webViewSchemes containsObject:[aURL scheme]] && NO == [aURL isFileURL]) {
        NSZone *zone = [self zone];
        [super dealloc];
        self = [[FVFinderIcon allocWithZone:zone] initWithURL:aURL];
    }
    else if ((self = [super init])) {
        _httpURL = [aURL copyWithZone:[self zone]];
        _fullImage = NULL;
        _thumbnail = NULL;
        _viewImage = NULL;
        _fallbackIcon = nil;
        
        // we can predict these sizes ahead of time since we have a fixed aspect ratio
        _thumbnailSize = _webViewSize;
        FVIconLimitThumbnailSize(&_thumbnailSize);
        _fullImageSize = _webViewSize;
        FVIconLimitFullImageSize(&_fullImageSize);
        _desiredSize = NSZeroSize;
        
        _cacheKey = [FVIconCache newKeyForURL:_httpURL];
        _condLock = [[NSConditionLock alloc] initWithCondition:IDLE];
    }
    return self;
}

- (void)_releaseWebView
{
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));
    // in case we get -releaseResources or -dealloc while waiting for another webview
    [[NSNotificationCenter defaultCenter] removeObserver:self name:FVWebIconWebViewAvailableNotificationName object:[self class]];
    if (nil != _webView) {
        [_webView setPolicyDelegate:nil];
        [_webView setFrameLoadDelegate:nil];
        [_webView stopLoading:nil];
        FVAPIAssert([_webView downloadDelegate] == nil, @"downloadDelegate non-nil");
        FVAPIAssert([_webView UIDelegate] == nil, @"UIDelegate non-nil");
        FVAPIAssert([_webView resourceLoadDelegate] == nil, @"resourceLoadDelegate non-nil");
        [[self class] pushWebView:_webView];
        _webView = nil;
    }
}

- (void)dealloc
{
    // typically on the main thread here, but not guaranteed
    OSMemoryBarrier();
    if (nil != _webView)
        [self performSelectorOnMainThread:@selector(_releaseWebView) withObject:nil waitUntilDone:YES modes:[NSArray arrayWithObject:(id)kCFRunLoopCommonModes]];
    [_condLock release];
    CGImageRelease(_viewImage);
    CGImageRelease(_fullImage);
    CGImageRelease(_thumbnail);
    [_httpURL release];
    [_fallbackIcon release];
    [_cacheKey release];
    [super dealloc];
}

- (BOOL)canReleaseResources;
{
    return (nil != _webView || NULL != _fullImage || NULL != _thumbnail || [_fallbackIcon canReleaseResources]);
}

- (void)releaseResources
{     
    // Cancel any pending loads
    OSMemoryBarrier();
    if (nil != _webView)
        [self performSelectorOnMainThread:@selector(_releaseWebView) withObject:nil waitUntilDone:YES modes:[NSArray arrayWithObject:(id)kCFRunLoopCommonModes]];

    // allow current waiters on LOADING to exit
    if ([_condLock tryLockWhenCondition:LOADING])
        [_condLock unlockWithCondition:LOADED];
    
    // block until IDLE is set, so current waiters don't get hosed by resetting the condition to IDLE
    [_condLock lockWhenCondition:IDLE];
    
    CGImageRelease(_fullImage);
    _fullImage = NULL;
    CGImageRelease(_thumbnail);
    _thumbnail = NULL;
    
    // currently a noop
    [_fallbackIcon releaseResources];
        
    // reset condition so -renderOffscreen will complete if it's called again
    [_condLock unlockWithCondition:IDLE];    
}

- (void)recache;
{
    [FVIconCache invalidateCachesForKey:_cacheKey];
    [self releaseResources];
}

- (BOOL)tryLock { return [_condLock tryLock]; }
- (void)lock { [_condLock lock]; }
- (void)unlock { [_condLock unlock]; }

// size of the _fullImage
- (NSSize)size { return _fullImageSize; }

// actual size of the webview
- (NSSize)_webviewSize { return _webViewSize; }

// size of the _thumbnail (1/5 of webview size)
- (NSSize)_thumbnailSize { return _thumbnailSize; }

- (BOOL)needsRenderForSize:(NSSize)size
{
    BOOL needsRender = NO;
    if ([_condLock tryLockWhenCondition:IDLE]) {
        
        /*
         1) if we know the web view failed, the only thing we can use is the fallback icon
         2) if we're drawing a large icon and the web view hasn't failed (yet), we depend on _fullImage (which may be in disk cache)
         3) if we're drawing a small icon and the web view hasn't failed (yet), we depend on _thumbnail (so webview needs to load)
         */
        _desiredSize = size;
        
        if (nil != _fallbackIcon)
            needsRender = [_fallbackIcon needsRenderForSize:size];
        else if (FVShouldDrawFullImageWithThumbnailSize(size, [self _thumbnailSize]))
            needsRender = (NULL == _fullImage);
        else
            needsRender = (NULL == _thumbnail);
        [self unlock];
    }
    return needsRender;
}

- (void)_handleWebView:(WebView *)sender loadError:(NSError *)error forFrame:(WebFrame *)frame;
{
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));
    FVAPIParameterAssert([sender isEqual:_webView]);
    
    // if a frame fails to load and the webview isn't loading anything else, bail out
    if (NO == [_webView fv_isLoading]) {
        [self _releaseWebView];
        [self lock];
        // return to -renderOffscreen to handle the failure
        [_condLock unlockWithCondition:LOADED];
    }    
}

- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame;
{
    [self _handleWebView:sender loadError:error forFrame:frame];
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame;
{
    [self _handleWebView:sender loadError:error forFrame:frame];
}

- (void)_pageDidFinishLoading
{
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));
    FVAPIParameterAssert(NO == [_webView fv_isLoading]);

    [self lock];
    
    // display the main frame's view directly to avoid showing the scrollers
    WebFrameView *view = [[_webView mainFrame] frameView];
    [view setAllowsScrolling:NO];
    
    NSSize size = [self _webviewSize];
    CGContextRef context = FVIconBitmapContextCreateWithSize(size.width, size.height);
    CGContextClearRect(context, CGRectMake(0, 0, size.width, size.height));
    NSGraphicsContext *nsContext = [NSGraphicsContext graphicsContextWithGraphicsPort:context flipped:[view isFlipped]];
    
    [NSGraphicsContext saveGraphicsState];
    
    [NSGraphicsContext setCurrentContext:nsContext];
    [nsContext saveGraphicsState];
    [[NSColor whiteColor] setFill];
    NSRect rect = NSMakeRect(0, 0, size.width, size.height);
    [[NSBezierPath fv_bezierPathWithRoundRect:rect xRadius:5 yRadius:5] fill];
    [nsContext restoreGraphicsState];

    [_webView setFrame:NSInsetRect(rect, 10, 10)];
    
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 10, 10);
    [view displayRectIgnoringOpacity:[view bounds] inContext:nsContext];
    CGContextRestoreGState(context);
    
    [NSGraphicsContext restoreGraphicsState];
    
    // temporary CGImage from the full webview
    CGImageRelease(_viewImage);
    _viewImage = CGBitmapContextCreateImage(context);
    
    FVIconBitmapContextDispose(context);
    
    // clear out the webview, since we won't need it again
    [self _releaseWebView];
    [_condLock unlockWithCondition:LOADED];
    
    // return to -renderOffscreen for scaling and caching
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));
    FVAPIParameterAssert([sender isEqual:_webView]);
    
    // wait until all frames are loaded
    if (NO == [_webView fv_isLoading])
        [self _pageDidFinishLoading];
}

- (void)webView:(WebView *)sender decidePolicyForMIMEType:(NSString *)type request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id < WebPolicyDecisionListener >)listener
{
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));
    FVAPIParameterAssert([sender isEqual:_webView]);
    
    // !!! Better to just load text/html and ignore everything else?  The point of implementing this method is to ignore PDF.  It doesn't show up in the thumbnail and it's slow to load, so there's no point in loading it.  Plugins are disabled, so stuff like Flash should be ignored anyway, and WebKit doesn't try to display PostScript AFAIK.
    
    // Documentation says the default implementation checks "If request is not a directory", which is...odd.
    // See http://trac.webkit.org/projects/webkit/browser/trunk/WebKit/mac/DefaultDelegates/WebDefaultPolicyDelegate.m
    
    CFStringRef theUTI = type == nil ? NULL : UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (CFStringRef)type, NULL);
    
    // FVWebViewIcon handles .webarchive files, so implement the standard file: URL handler
    if ([[request URL] isFileURL]) {
        BOOL isDirectory = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:[[request URL] path] isDirectory:&isDirectory];
        if (isDirectory) {
            [listener ignore];
        } else if ([[sender class] canShowMIMEType:type]) {
            [listener use];
        } else {
            [listener ignore];
        }
    }
    else if (NULL != theUTI && FALSE == UTTypeConformsTo(theUTI, kUTTypeText)) {
        [self lock];
        NSParameterAssert([_condLock condition] == LOADING);
        [_fallbackIcon release];
        _fallbackIcon = [[FVMIMEIcon allocWithZone:[self zone]] initWithMIMEType:type];
        [self unlock];
        // this triggers webView:didFailProvisionalLoadWithError:forFrame:
        [listener ignore];        
    }
    else if ([[sender class] canShowMIMEType:type]) {
        [listener use];
    }
    else {
        [listener ignore];
    }
    
    if (theUTI) CFRelease(theUTI);
}

- (void)renderOffscreenOnMainThread 
{ 
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));   
    // !!! Was seeing occasional assertion failures here with the new operation queue setup; it's likely to be a race with releaseResources:.  Should be eliminated with the new condition lock scheme.
    NSAssert(nil == _webView, @"*** Render error *** renderOffscreenOnMainThread called when _webView already exists");
    
    if (nil == _webView)
        _webView = [[self class] popWebView];

    if (nil == _webView) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleWebViewAvailableNotification:) name:FVWebIconWebViewAvailableNotificationName object:[self class]];
    }
    else {
        // always use the WebKit cache, and use the default timeout
        NSURLRequest *request = [NSURLRequest requestWithURL:_httpURL cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:60.0];
        
        // See also http://lists.apple.com/archives/quicklook-dev/2007/Nov/msg00047.html
        // Note: changed from blocking to non-blocking; we now just keep state and rely on the delegate methods.
        
        Class cls = [self class];
        NSString *prefIdentifier = [NSString stringWithFormat:@"%@.%@", [[NSBundle bundleForClass:cls] bundleIdentifier], cls];
        [_webView setPreferencesIdentifier:prefIdentifier];
        
        WebPreferences *prefs = [_webView preferences];
        [prefs setPlugInsEnabled:NO];
        [prefs setJavaEnabled:NO];
        [prefs setJavaScriptCanOpenWindowsAutomatically:NO];
        [prefs setJavaScriptEnabled:NO];
        [prefs setAllowsAnimatedImages:NO];
        
        // most memory-efficient setting; remote resources are still cached to disk
        if ([prefs respondsToSelector:@selector(setCacheModel:)])
            [prefs setCacheModel:WebCacheModelDocumentViewer];
        
        [_webView setFrameLoadDelegate:self];
        [_webView setPolicyDelegate:self];
        [[_webView mainFrame] loadRequest:request];        
    }
}

- (void)_handleWebViewAvailableNotification:(NSNotification *)aNotification
{
    FVAPIAssert2(pthread_main_np() != 0, @"*** threading violation *** -[%@ %@] requires main thread", [self class], NSStringFromSelector(_cmd));
    [[NSNotificationCenter defaultCenter] removeObserver:self name:FVWebIconWebViewAvailableNotificationName object:[self class]];
    [self renderOffscreenOnMainThread];
}

- (NSString *)debugDescription
{
    NSAssert1([self tryLock], @"*** threading violation *** failed to lock before %@", NSStringFromSelector(_cmd));
    return [NSString stringWithFormat:@"%@: { \n\tURL = %@\n\tWebView = %@\n\tFull image = %@\n\tThumbnail = %@\n }", [self description], _httpURL, _webView, _fullImage, _thumbnail];
}
    
- (void)renderOffscreen
{
    [[self class] _startRenderingForKey:_cacheKey];

    [_condLock lockWhenCondition:IDLE];
    
    if ([NSThread instancesRespondToSelector:@selector(setName:)] && pthread_main_np() == 0)
        [[NSThread currentThread] setName:[_httpURL absoluteString]];

    // check the disk cache first
    
    // note that _fullImage may be non-NULL if we were added to the FVOperationQueue multiple times before renderOffscreen was called
    if (NULL == _fullImage && FVShouldDrawFullImageWithThumbnailSize(_desiredSize, [self _thumbnailSize]))
        _fullImage = [FVIconCache newImageForKey:_cacheKey];
    
    // always load for the fast drawing path
    if (NULL == _thumbnail)
        _thumbnail = [FVIconCache newThumbnailForKey:_cacheKey];

    // unlock before calling performSelectorOnMainThread:... since it could cause a callout that tries to acquire the lock (one of the delegate methods)
    
    if (NULL == _thumbnail && NULL == _fullImage) {
        
        // make sure needsRenderForSize: knows that we're actively rendering, so renderOffscreen doesn't get called again
        [_condLock unlockWithCondition:LOADING];
        [self performSelectorOnMainThread:@selector(renderOffscreenOnMainThread) withObject:nil waitUntilDone:NO modes:[NSArray arrayWithObject:(id)kCFRunLoopCommonModes]];        
        [_condLock lockWhenCondition:LOADED];
        
        CGImageRef fullImage = NULL, thumbnail = NULL;
        
        if (NULL != _viewImage) {
            
            CGImageRelease(_fullImage);
            _fullImage = FVCreateResampledFullImage(_viewImage);
            
            // resample to a thumbnail size that will draw quickly
            CGImageRelease(_thumbnail);
            _thumbnail = FVCreateResampledThumbnail(_viewImage);
            
            // get rid of the original image
            CGImageRelease(_viewImage);
            _viewImage = NULL;
            
            // keep local references for caching, so we can unlock and notify observers for drawing (can't draw if we're holding the lock)
            fullImage = CGImageRetain(_fullImage);
            thumbnail = CGImageRetain(_thumbnail);
        }
        else if (nil == _fallbackIcon) {
            _fallbackIcon = [[FVFinderIcon allocWithZone:[self zone]] initWithURL:_httpURL];
        }
        
        // unlock before caching images so drawing can take place
        [_condLock unlockWithCondition:IDLE];
        
        if (fullImage) [FVIconCache cacheImage:fullImage forKey:_cacheKey];
        if (thumbnail) [FVIconCache cacheThumbnail:thumbnail forKey:_cacheKey];
        
        CGImageRelease(fullImage);
        CGImageRelease(thumbnail);
    }
    else {
        [_condLock unlockWithCondition:IDLE];
    }
    
    [[self class] _stopRenderingForKey:_cacheKey];
}

- (void)fastDrawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{
    if ([_condLock tryLockWhenCondition:IDLE]) {
        if (_thumbnail) {
            CGContextDrawImage(context, [self _drawingRectWithRect:dstRect], _thumbnail);
            [self unlock];
        }
        else {
            [self unlock];
            // let drawInRect: handle the rect conversion
            [self drawInRect:dstRect ofContext:context];
        }
    }
    else {
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
}

- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context 
{ 
    if ([_condLock tryLockWhenCondition:IDLE]) {
        
        CGRect drawRect = [self _drawingRectWithRect:dstRect];
        
        BOOL shouldDrawFullImage = FVShouldDrawFullImageWithThumbnailSize(dstRect.size, [self _thumbnailSize]);
        // if we have _fullImage, we're guaranteed to have _thumbnail
        if (_fullImage && shouldDrawFullImage)
            CGContextDrawImage(context, drawRect, _fullImage);
        else if (_thumbnail)
            CGContextDrawImage(context, drawRect, _thumbnail);
        else if (nil == _fallbackIcon)
            [self _drawPlaceholderInRect:dstRect ofContext:context];
        else
            [_fallbackIcon drawInRect:dstRect ofContext:context];
        
        [self unlock];
    }
    else {
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
}

@end
