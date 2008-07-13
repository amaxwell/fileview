//
//  FVQuickLookIcon.m
//  FileViewTest
//
//  Created by Adam Maxwell on 09/16/07.
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

#import "FVQuickLookIcon.h"
#import "FVFinderIcon.h"
#import <QuickLook/QLThumbnailImage.h>

// see http://www.cocoabuilder.com/archive/message/cocoa/2005/6/15/138943 for linking; need to use bundle_loader flag to allow the linker to resolve our superclass

@implementation FVQuickLookIcon

static BOOL FVQLIconDisabled = NO;

+ (void)initialize
{
    FVINITIALIZE(FVQuickLookIcon);
    FVQLIconDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"FVQLIconDisabled"];
}

+ (void)_getBackgroundColor:(CGFloat [])color forURL:(NSURL *)aURL
{
    FSRef fileRef;
    if (CFURLGetFSRef((CFURLRef)aURL, &fileRef)) {
        
        CFStringRef theUTI = NULL;
        LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, (CFTypeRef *)&theUTI);
        
        // just set pure alpha for now
        if (theUTI && (UTTypeConformsTo(theUTI, kUTTypeMovie) || UTTypeConformsTo(theUTI, kUTTypeAudiovisualContent))) {
            color[0] = 0;
            color[1] = 0;
            color[2] = 0;
            color[3] = 0;
        }
        if (theUTI) CFRelease(theUTI);
    }
}

- (id)initWithURL:(NSURL *)theURL;
{
    NSURL *originalURL = [theURL retain];
    if (FVQLIconDisabled) {
        [self release];
        self = nil;
    }
    else if ((self = [super initWithURL:theURL])) {
        // QL seems to fail a large percentage of the time on my system, and it's also pretty slow.  Since FVFinderIcon is now fast and relatively low overhead, preallocate the fallback icon to avoid waiting for QL to return NULL.
        _fallbackIcon = [[FVFinderIcon allocWithZone:[self zone]] initWithURL:originalURL];
        _fullImage = NULL;
        _thumbnailSize = NSZeroSize;
        _desiredSize = NSZeroSize;
        _quickLookFailed = NO;
        _backgroundColor[0] = 1;
        _backgroundColor[1] = 1;
        _backgroundColor[2] = 1;
        _backgroundColor[3] = 1;
        [[self class] _getBackgroundColor:_backgroundColor forURL:_fileURL];
    }
    [originalURL release];
    return self;
}

- (void)dealloc
{
    CGImageRelease(_fullImage);
    CGImageRelease(_thumbnail);
    [_fallbackIcon release];
    [super dealloc];
}

- (BOOL)canReleaseResources;
{
    return (NULL != _fullImage);
}

- (void)releaseResources
{
    [self lock];
    CGImageRelease(_fullImage);
    _fullImage = NULL;
    [_fallbackIcon releaseResources];
    [self unlock];
}

- (NSSize)size { return _thumbnailSize; }

static inline bool __FVQLShouldDrawFullImageWithSize(NSSize desiredSize, NSSize currentSize)
{
    NSUInteger targetMax = MAX(desiredSize.width, desiredSize.height);
    NSUInteger currentMax = MAX(currentSize.height, currentSize.width);
    return (ABS(targetMax - currentMax) > 0.2 * targetMax);
}

- (BOOL)needsRenderForSize:(NSSize)size
{
    BOOL needsRender = NO;
    if ([self tryLock]) {
        if (NO == _quickLookFailed) {
            // The _fullSize is zero or whatever quicklook returned last time, which may be something odd like 78x46.  Since we ask QL for a size but it constrains the size it actually returns based on the icon's aspect ratio, we have to check height and width.  Just checking height in this was causing an endless loop asking for a size it won't return.
            if (FVShouldDrawFullImageWithThumbnailSize(size, _thumbnailSize))
                needsRender = (NULL == _fullImage || __FVQLShouldDrawFullImageWithSize(size, FVCGImageSize(_fullImage)));
            else
                needsRender = (NULL == _thumbnail);
        }
        else {
            needsRender = [_fallbackIcon needsRenderForSize:size];
        }
        _desiredSize = size;
        [self unlock];
    }
    return needsRender;
}

- (void)renderOffscreen
{        
    [self lock];
    
    if ([NSThread instancesRespondToSelector:@selector(setName:)] && pthread_main_np() == 0)
        [[NSThread currentThread] setName:[_fileURL path]];

    if (NO == _quickLookFailed) {
        
        CGSize requestedSize = (CGSize) { FVMaxThumbnailDimension, FVMaxThumbnailDimension };
        
        if (NULL == _thumbnail)
            _thumbnail = QLThumbnailImageCreate(NULL, (CFURLRef)_fileURL, requestedSize, NULL);
        
        if (NULL == _thumbnail)
            _quickLookFailed = YES;
        
        // always initialize sizes
        _thumbnailSize = _thumbnail ? FVCGImageSize(_thumbnail) : NSZeroSize;

        if (NSEqualSizes(NSZeroSize, _thumbnailSize) == NO && FVShouldDrawFullImageWithThumbnailSize(_desiredSize, _thumbnailSize)) {
            
            if (NULL != _fullImage && __FVQLShouldDrawFullImageWithSize(_desiredSize, FVCGImageSize(_fullImage))) {                
                CGImageRelease(_fullImage);
                _fullImage = NULL;
            }
            
            if (NULL == _fullImage) {
                requestedSize = *(CGSize *)&_desiredSize;
                _fullImage = QLThumbnailImageCreate(NULL, (CFURLRef)_fileURL, requestedSize, NULL);
            }
            
            if (NULL == _fullImage)
                _quickLookFailed = YES;
        }
    }
    
    // preceding calls may have set the failure flag
    if (_quickLookFailed) {
        if ([_fallbackIcon needsRenderForSize:_desiredSize])
            [_fallbackIcon renderOffscreen];
    }
    
    [self unlock];
}    

// doesn't touch ivars; caller acquires lock first
- (void)_drawBackgroundAndImage:(CGImageRef)image inRect:(NSRect)dstRect ofContext:(CGContextRef)context
{
    CGRect drawRect = [self _drawingRectWithRect:dstRect];
    // Apple's QL plugins for multiple page types (.pages, .plist, .xls etc) draw text right up to the margin of the icon, so we'll add a small margin.  The decoration option will do this for us, but it also draws with a dog-ear, and I don't want that because it's inconsistent with our other thumbnail classes.
    CGContextSaveGState(context);
    CGContextSetRGBFillColor(context, _backgroundColor[0], _backgroundColor[1], _backgroundColor[2], _backgroundColor[3]);
    CGContextFillRect(context, drawRect);
    // clear any shadow before drawing the image; clipping won't eliminate it
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    drawRect = CGRectInset(drawRect, CGRectGetWidth(drawRect) / 20, CGRectGetHeight(drawRect) / 20);
    CGContextClipToRect(context, drawRect);
    CGContextDrawImage(context, drawRect, image);
    CGContextRestoreGState(context);
}

- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{
    BOOL didLock = ([self tryLock]);
    if (didLock && (NULL != _thumbnail || NULL != _fullImage)) {
                    
        CGImageRef image;
        // always fall back on the thumbnail
        if (FVShouldDrawFullImageWithThumbnailSize(dstRect.size, _thumbnailSize) && _fullImage)
            image = _fullImage;
        else
            image = _thumbnail;

        [self _drawBackgroundAndImage:image inRect:dstRect ofContext:context];
        
        if (_drawsLinkBadge)
            [self _badgeIconInRect:dstRect ofContext:context];
        
        [self unlock];
    }
    else if (NO == didLock && NULL != _thumbnail) {
        // no lock for thumbnail; if it exists, it's never released
        [self _drawBackgroundAndImage:_thumbnail inRect:dstRect ofContext:context];
        if (_drawsLinkBadge)
            [self _badgeIconInRect:dstRect ofContext:context];
    }
    else if (_quickLookFailed && nil != _fallbackIcon) {
        [_fallbackIcon drawInRect:dstRect ofContext:context];
    }
    else {
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
    if (didLock) [self unlock];
}

@end
