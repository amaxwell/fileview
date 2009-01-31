//
//  FVViewController.m
//  FileView
//
//  Created by Adam Maxwell on 3/26/08.
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

#import "FVViewController.h"
#import "FVIcon.h"
#import "FVOperationQueue.h"
#import "FVIconOperation.h"
#import <FileView/FileView.h>
#import "FVUtilities.h"
#import "FVDownload.h"
#import <WebKit/WebKit.h>
#import <FileView/FVFinderLabel.h>

// don't bother removing icons from the cache if there are fewer than this value
#define ZOMBIE_CACHE_THRESHOLD 100L

// check the icon cache every minute and get rid of stale icons
#define ZOMBIE_TIMER_INTERVAL 60.0


// time interval for indeterminate download progress indicator updates
#define PROGRESS_TIMER_INTERVAL 0.1

@interface _FVURLInfo : NSObject
{
@public;
    NSString   *_name;
    NSUInteger  _label;
}
- (id)initWithURL:(NSURL *)aURL;
@end


@implementation FVViewController

- (id)initWithView:(FileView *)view
{
    self = [super init];
    if (self) {
        
        _view = view;
        _dataSource = [_view dataSource];
        
        // Arrays associate FVIcon <--> NSURL in view order.  This is primarily because NSURL is a slow and expensive key for NSDictionary since it copies strings to compute -hash instead of storing it inline; as a consequence, calling [_iconCache objectForKey:[_datasource URLAtIndex:]] is a memory and CPU hog.  We use parallel arrays instead of one array filled with NSDictionaries because there will only be two, and this is less memory and fewer calls.
        _orderedIcons = [NSMutableArray new];
        
        // created lazily in case it's needed (only if using a datasource)
        _orderedURLs = nil;
        _isBound = NO;
        
        // only created when datasource is set
        _orderedSubtitles = nil;
        
        // Icons keyed by URL; may contain icons that are no longer displayed.  Keeping this as primary storage means that rearranging/reloading is relatively cheap, since we don't recreate all FVIcon instances.
        _iconCache = [NSMutableDictionary new];
        
        // This avoids doing file operations on every URL while drawing, just to get the name and label.  This table is purged by -reload, so we can use pointer keys and avoid hashing CFURL instances (and avoid copying keys...be sure to use CF to add values!).
        const CFDictionaryKeyCallBacks pointerKeyCallBacks = { 0, kCFTypeDictionaryKeyCallBacks.retain, kCFTypeDictionaryKeyCallBacks.release,
                                                                kCFTypeDictionaryKeyCallBacks.copyDescription, NULL, NULL };
        _infoTable = CFDictionaryCreateMutable(NULL, 0, &pointerKeyCallBacks, &kCFTypeDictionaryValueCallBacks);        
                
        // runloop will retain this timer, but we'll retain it too and release in -dealloc
        CFAbsoluteTime fireTime = CFAbsoluteTimeGetCurrent() + ZOMBIE_TIMER_INTERVAL;
        _zombieTimer = FVCreateWeakTimerWithTimeInterval(ZOMBIE_TIMER_INTERVAL, fireTime, self, @selector(_zombieTimerFired:));
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), _zombieTimer, kCFRunLoopDefaultMode);
        _operationQueue = [FVOperationQueue new];
        
        // array of FVDownload instances
        _downloads = [NSMutableArray new];
        
        // timer to update the view when a download's length is indeterminate
        _progressTimer = NULL;
        
    }

    // make sure all ivars are set up before calling this
    [self reload];

    return self;
}

- (void)dealloc
{
    [self cancelDownloads];
    [_iconCache release];
    CFRunLoopTimerInvalidate(_zombieTimer);
    CFRelease(_zombieTimer);
    [_orderedIcons release];
    [_orderedURLs release];
    [_orderedSubtitles release];
    CFRelease(_infoTable);
    [_operationQueue terminate];
    [_operationQueue release];
    [_downloads release];
    [super dealloc];
}

- (void)setBound:(BOOL)flag;
{
    _isBound = flag;
}

- (void)setIconURLs:(NSArray *)array
{
    if (_orderedURLs != array) {
        [_orderedURLs release];
        
        // The array parameter will typically be an NSArrayController proxy object.  The view observes mutations to the collection and calls -reload, so we can retain instead of copying (which creates an NSCFArray).
        _orderedURLs = [array retain];
    }    
}

- (NSArray *)iconURLs
{
    return _orderedURLs;
}

- (void)setDataSource:(id)obj
{ 
    _dataSource = obj; 
    [_operationQueue cancel];
    
    [self cancelDownloads];

    [_orderedSubtitles release];
    if ([obj respondsToSelector:@selector(fileView:subtitleAtIndex:)]) {
        _orderedSubtitles = [NSMutableArray new];
    }
    else {
        _orderedSubtitles = nil;
    }
    
    // convenient time to do this, although the timer would also handle it
    [_iconCache removeAllObjects];

    // mainly to clean out the arrays
    [self reload];
}

- (FVIcon *)iconAtIndex:(NSUInteger)anIndex { 
    FVAPIAssert(anIndex < [_orderedIcons count], @"invalid icon index requested; likely missing a call to -reloadIcons");
    return [_orderedIcons objectAtIndex:anIndex]; 
}

- (NSString *)subtitleAtIndex:(NSUInteger)anIndex { 
    // _orderedSubtitles is nil if the datasource doesn't implement the optional method
    if (_orderedSubtitles) FVAPIAssert(anIndex < [_orderedSubtitles count], @"invalid subtitle index requested; likely missing a call to -reloadIcons");
    return [_orderedSubtitles objectAtIndex:anIndex]; 
}

- (NSArray *)iconsAtIndexes:(NSIndexSet *)indexes { 
    FVAPIAssert([indexes lastIndex] < [self numberOfIcons], @"invalid number of icons requested; likely missing a call to -reloadIcons");
    return [_orderedIcons objectsAtIndexes:indexes]; 
}

#pragma mark -

/*
 Wrap datasource/bindings and return [FVIcon missingFileURL] when the datasource or bound array 
 returns nil or NSNull, or else we end up with exceptions everywhere.
 */

// public methods must be consistent at all times
- (NSURL *)URLAtIndex:(NSUInteger)anIndex {
    NSParameterAssert(anIndex < [self numberOfIcons]);
    NSURL *aURL = [_orderedURLs objectAtIndex:anIndex];
    if (__builtin_expect(nil == aURL || [NSNull null] == (id)aURL, 0))
        aURL = [FVIcon missingFileURL];
    return aURL;
}

- (NSUInteger)numberOfIcons { return [_orderedURLs count]; }

// only used by -reload; always returns a value independent of cached state
- (NSURL *)_URLAtIndex:(NSUInteger)anIndex { 
    NSURL *aURL = _isBound ? [_orderedURLs objectAtIndex:anIndex] : [_dataSource fileView:_view URLAtIndex:anIndex];
    if (__builtin_expect(nil == aURL || [NSNull null] == (id)aURL, 0))
        aURL = [FVIcon missingFileURL];
    return aURL;
}

// only used by -reload; always returns a value independent of cached state
- (NSUInteger)_numberOfIcons { return _isBound ? [_orderedURLs count] : [_dataSource numberOfIconsInFileView:_view]; }

- (void)reload;
{
    // if we're using bindings, there's no need to cache all the URLs
    if (NO == _isBound) {
        
        if (nil == _orderedURLs)
            _orderedURLs = [NSMutableArray new];
        else
            [_orderedURLs removeAllObjects];
    }
    
    [_orderedIcons removeAllObjects];
    [_orderedSubtitles removeAllObjects];
    
    CFDictionaryRemoveAllValues(_infoTable);
    
    // -[FVViewController _cachedIconForURL:]
    id (*cachedIcon)(id, SEL, id);
    cachedIcon = (id (*)(id, SEL, id))[self methodForSelector:@selector(_cachedIconForURL:)];
    
    // -[FVViewController URLAtIndex:] guaranteed non-nil/non-NSNULL
    id (*_URLAtIndex)(id, SEL, NSUInteger);
    _URLAtIndex = (id (*)(id, SEL, NSUInteger))[self methodForSelector:@selector(_URLAtIndex:)];
    
    // -[NSCFArray insertObject:atIndex:] (do /not/ use +[NSMutableArray instanceMethodForSelector:]!)
    SEL insertSel = @selector(insertObject:atIndex:);
    void (*insertObjectAtIndex)(id, SEL, id, NSUInteger);
    insertObjectAtIndex = (void (*)(id, SEL, id, NSUInteger))[_orderedIcons methodForSelector:insertSel];
    
    // datasource subtitle method; may result in a NULL IMP (in which case _orderedSubtitles is nil)
    SEL subtitleSel = @selector(fileView:subtitleAtIndex:);
    id (*subtitleAtIndex)(id, SEL, id, NSUInteger);
    subtitleAtIndex = (id (*)(id, SEL, id, NSUInteger))[_dataSource methodForSelector:subtitleSel];
    
    NSUInteger i, iMax = [self _numberOfIcons];
    
    for (i = 0; i < iMax; i++) {
        NSURL *aURL = _URLAtIndex(self, @selector(_URLAtIndex:), i);
        NSParameterAssert(nil != aURL && [NSNull null] != (id)aURL);
        FVIcon *icon = cachedIcon(self, @selector(_cachedIconForURL:), aURL);
        NSParameterAssert(nil != icon);
        if (NO == _isBound)
            insertObjectAtIndex(_orderedURLs, insertSel, aURL, i);
        insertObjectAtIndex(_orderedIcons, insertSel, icon, i);
        if (_orderedSubtitles)
            insertObjectAtIndex(_orderedSubtitles, insertSel, subtitleAtIndex(_dataSource, subtitleSel, _view, i), i);
    }  
}

- (void)getDisplayName:(NSString **)name andLabel:(NSUInteger *)label forURL:(NSURL *)aURL;
{
    _FVURLInfo *info = [(id)_infoTable objectForKey:aURL];
    if (nil == info) {
        info = [[_FVURLInfo allocWithZone:[self zone]] initWithURL:aURL];
        CFDictionarySetValue(_infoTable, (CFURLRef)aURL, info);
        [info release];
    }
    if (name) *name = info->_name;
    if (label) *label = info->_label;
}

#pragma mark -

- (void)cancelQueuedOperations;
{
    [_operationQueue cancel];
}

- (void)enqueueReleaseOperationForIcons:(NSArray *)icons;
{    
    NSUInteger i, iMax = [icons count];
    NSMutableArray *operations = [[NSMutableArray alloc] initWithCapacity:iMax];
    FVIcon *icon;
    for (i = 0; i < iMax; i++) {
        icon = [icons objectAtIndex:i];
        if ([icon canReleaseResources]) {
            FVReleaseOperation *op = [[FVReleaseOperation alloc] initWithIcon:icon view:nil];
            [op setQueuePriority:FVOperationQueuePriorityLow];
            [operations addObject:op];
            [op release];
        }
    }
    if ([operations count])
        [_operationQueue addOperations:operations];
    [operations release];
}

- (void)enqueueRenderOperationForIcons:(NSArray *)icons checkSize:(NSSize)iconSize;
{    
    NSUInteger i, iMax = [icons count];
    NSMutableArray *operations = [[NSMutableArray alloc] initWithCapacity:iMax];
    FVIcon *icon;
    for (i = 0; i < iMax; i++) {
        icon = [icons objectAtIndex:i];
        if ([icon needsRenderForSize:iconSize]) {
            FVRenderOperation *op = [[FVRenderOperation alloc] initWithIcon:icon view:_view];
            [op setQueuePriority:FVOperationQueuePriorityHigh];
            [operations addObject:op];
            [op release];
        }
    }
    if ([operations count])
        [_operationQueue addOperations:operations];
    [operations release];
}

#pragma mark -

// This method instantiates icons as needed
- (FVIcon *)_cachedIconForURL:(NSURL *)aURL;
{
    NSParameterAssert([aURL isKindOfClass:[NSURL class]]);
    FVIcon *icon = [_iconCache objectForKey:aURL];
    if (nil == icon) {
        icon = [[FVIcon allocWithZone:NULL] initWithURL:aURL];
        [_iconCache setObject:icon forKey:aURL];
        [icon release];
    }
    return icon;
}

// -[FileView drawRect:] uses -releaseResources on icons that aren't visible but present in the datasource, so we just need a way to cull icons that are cached but not currently in the datasource
- (void)_zombieTimerFired:(CFRunLoopTimerRef)timer
{    
    // don't do anything unless there's a meaningful discrepancy between the number of items reported by the datasource and our cache
    if (([self numberOfIcons] + ZOMBIE_CACHE_THRESHOLD) < [_iconCache count]) {
        
        NSMutableSet *iconURLsToKeep = [NSMutableSet setWithArray:_orderedURLs];        
        NSMutableSet *toRemove = [NSMutableSet setWithArray:[_iconCache allKeys]];
        [toRemove minusSet:iconURLsToKeep];
        
        // anything remaining in toRemove is not present in the dataSource, so remove it from the cache
        NSEnumerator *keyEnum = [toRemove objectEnumerator];
        NSURL *aURL;
        while ((aURL = [keyEnum nextObject]))
            [_iconCache removeObjectForKey:aURL];
    }
}

#pragma mark Download support

- (NSArray *)downloads { return _downloads; }

- (void)_invalidateProgressTimer
{
    if (_progressTimer) {
        CFRunLoopTimerInvalidate(_progressTimer);
        CFRelease(_progressTimer);
        _progressTimer = NULL;
    }
}

- (void)downloadURLAtIndex:(NSUInteger)anIndex;
{
    NSURL *theURL = [self URLAtIndex:anIndex];
    FVDownload *download = [[FVDownload alloc] initWithDownloadURL:theURL indexInView:anIndex];     
    [_downloads addObject:download];
    [download release];
    [download setDelegate:self];
    [download start];
}

- (void)downloadFailed:(FVDownload *)download
{
    [_downloads removeObject:download];
    if ([_downloads count] == 0)
        [self _invalidateProgressTimer];
    [_view setNeedsDisplay:YES];
}

- (void)downloadFinished:(FVDownload *)download
{
    NSUInteger idx = [download indexInView];
    NSURL *currentURL = [self URLAtIndex:idx];
    NSURL *dest = [download fileURL];
    // things could have been rearranged since the download was started, so don't replace the wrong one
    if (nil != dest && [currentURL isEqual:[download downloadURL]])
        [[_view dataSource] fileView:_view replaceURLsAtIndexes:[NSIndexSet indexSetWithIndex:idx] withURLs:[NSArray arrayWithObject:dest]];
    
    [_downloads removeObject:download];
    if ([_downloads count] == 0)
        [self _invalidateProgressTimer];
    [_view setNeedsDisplay:YES];
}

- (void)downloadUpdated:(FVDownload *)download
{    
    
    if (NSURLResponseUnknownLength == [download expectedLength] && NULL == _progressTimer) {
        // runloop will retain this timer, but we'll retain it too and release in -dealloc
        _progressTimer = FVCreateWeakTimerWithTimeInterval(PROGRESS_TIMER_INTERVAL, CFAbsoluteTimeGetCurrent() + PROGRESS_TIMER_INTERVAL, self, @selector(_progressTimerFired:));
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), _progressTimer, kCFRunLoopDefaultMode);
    }
    [_view setNeedsDisplay:YES];
}

- (void)download:(FVDownload *)download setDestinationWithSuggestedFilename:(NSString *)filename;
{
    NSString *fullPath = nil;
    if ([[_view delegate] respondsToSelector:@selector(fileView:downloadDestinationWithSuggestedFilename:)])
        fullPath = [[[_view delegate] fileView:_view downloadDestinationWithSuggestedFilename:filename] path];
    
    if (nil == fullPath)
        fullPath = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
    
    [download setFileURL:[NSURL fileURLWithPath:fullPath]];
}

- (void)_progressTimerFired:(CFRunLoopTimerRef)timer
{
    [_view setNeedsDisplay:YES];
}

- (NSWindow *)downloadWindowForAuthenticationSheet:(WebDownload *)download
{
    return [_view window];
}

- (void)cancelDownloads;
{
    [_downloads makeObjectsPerformSelector:@selector(cancel)];
    [_downloads removeAllObjects];
    [self _invalidateProgressTimer];
    [_view setNeedsDisplay:YES];
}

@end

@implementation _FVURLInfo

- (id)initWithURL:(NSURL *)aURL;
{
    self = [super init];
    if (self) {
        
        if ([aURL isFileURL]) {
            CFStringRef name;
            if (noErr != LSCopyDisplayNameForURL((CFURLRef)aURL, &name))
                _name = [[[aURL path] lastPathComponent] copyWithZone:[self zone]];
            else
                _name = (NSString *)name;
        } else {
            _name = [[aURL absoluteString] copyWithZone:[self zone]];
        }
        _label = [FVFinderLabel finderLabelForURL:aURL];
    }
    return self;
}

- (void)dealloc
{
    [_name release];
    [super dealloc];
}

@end

