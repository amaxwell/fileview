//
//  FVPDFIcon.m
//  FileView
//
//  Created by Adam Maxwell on 10/21/07.
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

#import "FVPDFIcon.h"
#import <libkern/OSAtomic.h>

#import "_FVMappedDataProvider.h"
#import "_FVSplitSet.h"
#import "_FVDocumentDescription.h"

static OSSpinLock   _releaseLock = OS_SPINLOCK_INIT;
static _FVSplitSet *_releaseableIcons = nil;
static CGLayerRef   _pageLayer = NULL;

@implementation FVPDFIcon

+ (void)initialize
{
    FVINITIALIZE(FVPDFIcon);
    unsigned char split = [_FVMappedDataProvider maxProviderCount] / 2 - 1;
    _releaseableIcons = [[_FVSplitSet allocWithZone:[self zone]] initWithSplit:split];
    
    const CGSize layerSize = { 1, 1 };
    CGContextRef context = [FVWindowGraphicsContextWithSize(NSSizeFromCGSize(layerSize)) graphicsPort];
    _pageLayer = CGLayerCreateWithContext(context, layerSize, NULL);
    context = CGLayerGetContext(_pageLayer);
    CGFloat components[4] = { 1, 1 };
    CGColorRef color = NULL;
    if (NULL != &kCGColorWhite && NULL != CGColorGetConstantColor) {
        color = CGColorRetain(CGColorGetConstantColor(kCGColorWhite));
    }
    else {
        CGColorSpaceRef cspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericGray);
        color = CGColorCreate(cspace, components);
        CGColorSpaceRelease(cspace);
    }
    CGContextSetFillColorWithColor(context, color);
    CGColorRelease(color);
    CGRect pageRect = CGRectZero;
    pageRect.size = CGLayerGetSize(_pageLayer);
    CGContextClipToRect(context, pageRect);
    CGContextFillRect(context, pageRect);
}

/*
 Problem: what happens if we have 130 mapped providers (so +maxSizeExceeded is true),
 yet only 80 have been marked as releaseable?  If the split is 100, -oldObjects always
 returns an empty set, but it keeps getting called repeatedly.  The split value, then,
 should always be less than (MAX_MAPPED_PROVIDER_COUNT / 2) to avoid wasted calls to
 -copyOldObjects and -removeOldObjects.
*/
+ (void)_addIconForMappedRelease:(FVPDFIcon *)anIcon;
{
    OSSpinLockLock(&_releaseLock);
    [_releaseableIcons addObject:anIcon];
    NSSet *oldObjects = nil;
    // ??? is the second condition really required?
    if ([_FVMappedDataProvider maxSizeExceeded] || [_releaseableIcons count] >= [_releaseableIcons split] * 2) {
        // copy inside the lock, then perform the slower makeObjectsPerformSelector: operation outside of it
        oldObjects = [_releaseableIcons copyOldObjects];
        // remove the first 100 objects, since the recently added ones are more likely to be needed again (scrolling up and down)
        [_releaseableIcons removeOldObjects];
    }
    OSSpinLockUnlock(&_releaseLock);
    
    if ([oldObjects count])
        [oldObjects makeObjectsPerformSelector:@selector(_releaseMappedResources)];
    [oldObjects release];
}

+ (void)_removeIconForMappedRelease:(FVPDFIcon *)anIcon;
{
    OSSpinLockLock(&_releaseLock);
    [_releaseableIcons removeObject:anIcon];
    OSSpinLockUnlock(&_releaseLock);    
}

- (id)initWithURL:(NSURL *)aURL;
{
    NSParameterAssert([aURL isFileURL]);
    self = [super initWithURL:aURL];
    if (self) {
        
        // Set default sizes to a typical aspect ratio.
        _fullSize = FVDefaultPaperSize;
        _thumbnailSize = _fullSize;

        _pdfDoc = NULL;
        _isMapped = NO;
        _pdfPage = NULL;
        _thumbnail = NULL;
        _desiredSize = NSZeroSize;
        
        // must be > 1 to be valid
        _currentPage = 1;
        
        // initialize to zero so we know whether to load the PDF document
        _pageCount = 0;        
    }
    return self;
}

- (void)dealloc
{
    [[self class] _removeIconForMappedRelease:self];
    if (_pdfDoc && _isMapped) [_FVMappedDataProvider releaseProviderForURL:_fileURL];
    CGImageRelease(_thumbnail);
    CGPDFDocumentRelease(_pdfDoc);
    [super dealloc];
}

- (NSSize)size { return _fullSize; }

- (BOOL)canReleaseResources;
{
    return (NULL != _thumbnail || NULL != _pdfPage);
}

- (void)_releaseMappedResources
{
    if ([self tryLock]) {
    
        if (NULL != _pdfDoc) {
            _pdfPage = NULL;
            if (_isMapped) [_FVMappedDataProvider releaseProviderForURL:_fileURL];
            CGPDFDocumentRelease(_pdfDoc);
            _pdfDoc = NULL;
        }
        [self unlock];
    }
}

- (void)releaseResources 
{
    // don't lock for this since it may call _releaseMappedResources immediately and deadlock (and the lock isn't needed anyway)
    if (_pdfDoc) 
        [[self class] _addIconForMappedRelease:self];
    
    if ([self tryLock]) {
        CGImageRelease(_thumbnail);
        _thumbnail = NULL;
        [self unlock];
    }
}

- (void)recache;
{
    [FVIconCache invalidateCachesForKey:_cacheKey];
    [self lock];
    CGImageRelease(_thumbnail);
    _thumbnail = NULL;
    [self unlock];
}

- (NSUInteger)pageCount { return _pageCount; }

- (NSUInteger)currentPageIndex { return _currentPage; }

- (void)showNextPage;
{
    [self lock];
    _currentPage = MIN(_currentPage + 1, _pageCount);
    _pdfPage = NULL;
    CGImageRelease(_thumbnail);
    _thumbnail = NULL;
    [self unlock];
}

- (void)showPreviousPage;
{
    [self lock];
    _currentPage = _currentPage > 1 ? _currentPage - 1 : 1;
    _pdfPage = NULL;
    CGImageRelease(_thumbnail);
    _thumbnail = NULL;
    [self unlock];
}

// roughly 50% of a typical page minimum dimension
#define FVMaxPDFThumbnailDimension 310

// used to constrain thumbnail size for huge pages
static bool __FVPDFIconLimitThumbnailSize(NSSize *size)
{
    CGFloat dimension = MAX(size->width, size->height);
    if (dimension <= FVMaxPDFThumbnailDimension)
        return false;
    
    while (dimension > FVMaxPDFThumbnailDimension) {
        size->width *= 0.9;
        size->height *= 0.9;
        dimension = MAX(size->width, size->height);
    }
    return true;
}

- (CGPDFDocumentRef)_newPDFDocument
{
    CGPDFDocumentRef document = NULL;
    if (FVCanMapFileAtURL(_fileURL))
        document = CGPDFDocumentCreateWithProvider([_FVMappedDataProvider newDataProviderForURL:_fileURL]);
    
    if (document) {
        _isMapped = YES;
    }
    else {
        _isMapped = NO;
        document = CGPDFDocumentCreateWithURL((CFURLRef)_fileURL);
    }
    return document;
}

// Draw a lock badge for encrypted PDF documents.  If drawing the PDF page fails, pdf_error() logs "failed to create default crypt filter." to the console each time (and doesn't draw anything).  Documents that just have restricted copy/print permissions will draw just fine (so shouldn't have the badge).
- (void)_drawLockBadgeInRect:(CGRect)pageRect ofContext:(CGContextRef)ctxt
{
    IconRef lockIcon;
    OSStatus err;
    // kLockedBadgeIcon looks much better than kLockedIcon, which gets jagged quickly
    err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kLockedBadgeIcon, &lockIcon);
    // square, unscaled rectangle since this is a badge icon
    CGRect lockRect;
    lockRect.size.width = MIN(pageRect.size.width, pageRect.size.height);
    lockRect.size.height = lockRect.size.width;
    lockRect.origin.x = CGRectGetMidX(pageRect) - 0.5 * lockRect.size.width;
    lockRect.origin.y = CGRectGetMidY(pageRect) - 0.5 * lockRect.size.height;
    if (noErr == err)
        (void)PlotIconRefInContext(ctxt, &lockRect, kAlignAbsoluteCenter, kTransformNone, NULL, kPlotIconRefNormalFlags, lockIcon);
    if (noErr == err)
        (void)ReleaseIconRef(lockIcon);
}

- (void)renderOffscreen
{  
    [[self class] _startRenderingForKey:_cacheKey];
    // hold the lock while initializing these variables, so we don't waste time trying to render again, since we may be returning YES from needsRender
    [self lock];
    
    if ([NSThread instancesRespondToSelector:@selector(setName:)] && pthread_main_np() == 0)
        [[NSThread currentThread] setName:[_fileURL path]];
    
    // only the first page is cached to disk; ignore this branch if we should be drawing a later page or if the size has changed
    
    // handle the case where multiple render tasks were pushed into the queue before renderOffscreen was called
    if ((NULL != _thumbnail || NULL != _pdfDoc) && 1 == _currentPage) {
        
        BOOL exitEarly;
        // if _thumbnail is non-NULL, we're guaranteed that _thumbnailSize has been initialized correctly
        
        // always want _thumbnail for the fast drawing path
        if (FVShouldDrawFullImageWithThumbnailSize(_desiredSize, _thumbnailSize))
            exitEarly = (NULL != _pdfDoc && NULL != _pdfPage && NULL != _thumbnail);
        else
            exitEarly = (NULL != _thumbnail);

        // !!! early return
        if (exitEarly) {
            [self unlock];
            [[self class] _stopRenderingForKey:_cacheKey];
            return;
        }
    }
    
    if (NULL == _thumbnail && 1 == _currentPage) {
        
        _thumbnail = [FVIconCache newThumbnailForKey:_cacheKey];
        BOOL exitEarly = NO;
        
        // This is an optimization to avoid loading the PDF document unless absolutely necessary.  If the icon was cached by a different FVPDFIcon instance, _pageCount won't be correct and we have to continue on and load the PDF document.  In that case, our sizes will be overwritten, but the thumbnail won't be recreated.  If we need to render something that's larger than the thumbnail by 20%, we have to continue on and make sure the PDF doc is loaded as well.
        
        if (NULL != _thumbnail) {
            _thumbnailSize = FVCGImageSize(_thumbnail);
            // retain since there's a possible race here if another thread inserts a description (although multiple instances shouldn't be rendering for the same cache key)
            _FVDocumentDescription *desc = [[_FVDocumentDescription descriptionForKey:_cacheKey] retain];
            if (desc) {
                _pageCount = desc->_pageCount;
                _fullSize = desc->_fullSize;
            }
            [desc release];
            NSParameterAssert(_thumbnailSize.width > 0 && _thumbnailSize.height > 0);
            exitEarly = NO == FVShouldDrawFullImageWithThumbnailSize(_desiredSize, _thumbnailSize) && _pageCount > 0;
        }
                
        // !!! early return
        if (exitEarly) {
            [self unlock];
            [[self class] _stopRenderingForKey:_cacheKey];
            return;
        }
    }    
    
    if (NULL == _pdfPage) {
        
        if (NULL == _pdfDoc) {
            _pdfDoc = [self _newPDFDocument];
            _pageCount = CGPDFDocumentGetNumberOfPages(_pdfDoc);
        }
        
        // The file had to exist when the icon was created, but loading the document can fail if the underlying file was moved out from under us afterwards (e.g. by BibDesk's autofile).  NB: CGPDFDocument uses 1-based indexing.
        if (_pdfDoc)
            _pdfPage = _pageCount ? CGPDFDocumentGetPage(_pdfDoc, _currentPage) : NULL;
        
        // won't be able to display this document if it can't be unlocked with the empty string
        if (_pdfDoc && CGPDFDocumentIsEncrypted(_pdfDoc) && CGPDFDocumentUnlockWithPassword(_pdfDoc, "") == false)
            _pageCount = 1;
        
        if (_pdfPage) {
            CGRect pageRect = CGPDFPageGetBoxRect(_pdfPage, kCGPDFCropBox);
            
            // these may have been bogus before
            int rotation = CGPDFPageGetRotationAngle(_pdfPage);
            if (0 == rotation || 180 == rotation)
                _fullSize = NSRectFromCGRect(pageRect).size;
            else
                _fullSize = NSMakeSize(pageRect.size.height, pageRect.size.width);
            
            _FVDocumentDescription *desc = [_FVDocumentDescription new];
            desc->_pageCount = _pageCount;
            desc->_fullSize = _fullSize;
            [_FVDocumentDescription setDescription:desc forKey:_cacheKey];
            [desc release];
            
            // scale appropriately; small PDF images, for instance, don't need scaling
            _thumbnailSize = _fullSize;   
            
            // !!! should probably keep multiple rasters instead of this hack, just as for other icons; drawing medium-sized PDF thumbnails gives lousy scrolling performance
           __FVPDFIconLimitThumbnailSize(&_thumbnailSize);
        }
    }

    // local ref for caching to disk
    CGImageRef thumbnail = NULL;

    // don't bother redrawing this if it already exists, since that's a big waste of time
    
    if (NULL == _thumbnail) {
        
        FVBitmapContextRef ctxt = FVIconBitmapContextCreateWithSize(_thumbnailSize.width, _thumbnailSize.height);
        
        // set a white page background
        CGRect pageRect = CGRectMake(0, 0, _thumbnailSize.width, _thumbnailSize.height);
        CGContextDrawLayerInRect(ctxt, pageRect, _pageLayer);
        
        if (_pdfPage) {
            
            if (CGPDFDocumentIsUnlocked(_pdfDoc)) {
                // always downscaling, so CGPDFPageGetDrawingTransform is okay to use here
                CGAffineTransform t = CGPDFPageGetDrawingTransform(_pdfPage, kCGPDFCropBox, pageRect, 0, true);
                CGContextSaveGState(ctxt);
                CGContextConcatCTM(ctxt, t);
                CGContextClipToRect(ctxt, CGPDFPageGetBoxRect(_pdfPage, kCGPDFCropBox));
                CGContextDrawPDFPage(ctxt, _pdfPage);
                CGContextRestoreGState(ctxt);
            }
            else {
                [self _drawLockBadgeInRect:pageRect ofContext:ctxt];
            }
        }
        
        CGImageRelease(_thumbnail);
        _thumbnail = CGBitmapContextCreateImage(ctxt);
        
        // okay to call cacheImage:forKey: even if the image is already cached
        if (1 == _currentPage && NULL != _thumbnail)
            thumbnail = CGImageRetain(_thumbnail);
        
        FVIconBitmapContextRelease(ctxt);
    }
    [self unlock];
    
    // okay to draw, but now cache to disk before allowing others to read from disk
    if (thumbnail) [FVIconCache cacheThumbnail:thumbnail forKey:_cacheKey];
    CGImageRelease(thumbnail);

    [[self class] _stopRenderingForKey:_cacheKey];
}

- (BOOL)needsRenderForSize:(NSSize)size 
{
    [[self class] _removeIconForMappedRelease:self];
    BOOL needsRender = NO;
    if ([self tryLock]) {
        // tells the render method if work is needed
        _desiredSize = size;
        
        // If we're drawing full size, don't bother loading the thumbnail if we have a PDFPage.  It can be quicker just to draw the page if the document is already loaded, rather than loading the thumbnail from cache.
        if (FVShouldDrawFullImageWithThumbnailSize(size, _thumbnailSize))
            needsRender = (NULL == _pdfPage);
        else
            needsRender = (NULL == _thumbnail);
        [self unlock];
    }
    return needsRender;
}

/*
 For PDF/PS icons, we always use trylock and draw a blank page if that fails.  Otherwise the drawing thread will wait for rendering to relinquish the lock (which can be really slow for PDF).  This is a major problem when scrolling.
 */

- (void)fastDrawInRect:(NSRect)dstRect ofContext:(CGContextRef)context
{    
    // draw thumbnail if present, regardless of the size requested, then try the page
    if (NO == [self tryLock]) {
        // no lock, so just draw the blank page and bail out
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
    else if (NULL != _thumbnail) {
        CGContextDrawImage(context, [self _drawingRectWithRect:dstRect], _thumbnail);
        [self unlock];
        if (_drawsLinkBadge)
            [self _badgeIconInRect:dstRect ofContext:context];
    }
    else if (NULL != _pdfPage) {
        [self unlock];
        [self drawInRect:dstRect ofContext:context];
    }
    else {
        [self unlock];
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
}

- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{    
    if (NO == [self tryLock]) {
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
    else {
        
        CGRect drawRect = [self _drawingRectWithRect:dstRect];
        
        // draw the thumbnail if the rect is small or we have no PDF document (yet)...if we have neither, draw a blank page
        
        if (FVShouldDrawFullImageWithThumbnailSize(dstRect.size, _thumbnailSize) && NULL != _pdfDoc) {
            
            // don't clip, because the caller has a shadow set
            CGContextDrawLayerInRect(context, drawRect, _pageLayer);

            // get rid of any shadow, or we may draw a text shadow if the page is transparent
            CGContextSaveGState(context);
            CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
            
            // unlocked with empty password at creation
            if (CGPDFDocumentIsUnlocked(_pdfDoc)) {
                // CGPDFPageGetDrawingTransform only downscales PDF, so we have to set up the CTM manually
                // http://lists.apple.com/archives/Quartz-dev/2005/Mar/msg00118.html
                CGRect cropBox = CGPDFPageGetBoxRect(_pdfPage, kCGPDFCropBox);
                CGContextTranslateCTM(context, drawRect.origin.x, drawRect.origin.y);
                int rotation = CGPDFPageGetRotationAngle(_pdfPage);
                // only tested 0 and 90 degree rotation
                switch (rotation) {
                    case 0:
                        CGContextScaleCTM(context, drawRect.size.width / cropBox.size.width, drawRect.size.height / cropBox.size.height);
                        CGContextTranslateCTM(context, -CGRectGetMinX(cropBox), -CGRectGetMinY(cropBox));
                        break;
                    case 90:
                        CGContextScaleCTM(context, drawRect.size.width / cropBox.size.height, drawRect.size.height / cropBox.size.width);
                        CGContextRotateCTM(context, -M_PI / 2);
                        CGContextTranslateCTM(context, -CGRectGetMaxX(cropBox), -CGRectGetMinY(cropBox));
                        break;
                    case 180:
                        CGContextScaleCTM(context, drawRect.size.width / cropBox.size.width, drawRect.size.height / cropBox.size.height);
                        CGContextRotateCTM(context, M_PI);
                        CGContextTranslateCTM(context, -CGRectGetMaxX(cropBox), -CGRectGetMaxY(cropBox));
                        break;
                    case 270:
                        CGContextScaleCTM(context, drawRect.size.width / cropBox.size.height, drawRect.size.height / cropBox.size.width);
                        CGContextRotateCTM(context, M_PI / 2);
                        CGContextTranslateCTM(context, -CGRectGetMinX(cropBox), -CGRectGetMaxY(cropBox));
                        break;
                }
                CGContextClipToRect(context, cropBox);
                CGContextDrawPDFPage(context, _pdfPage);
            }
            else {
                [self _drawLockBadgeInRect:drawRect ofContext:context];
            }
            if (_drawsLinkBadge)
                [self _badgeIconInRect:dstRect ofContext:context];
            
            // restore shadow and possibly the CTM
            CGContextRestoreGState(context);
        }
        else if (NULL != _thumbnail) {
            CGContextDrawImage(context, drawRect, _thumbnail);
            if (_drawsLinkBadge)
                [self _badgeIconInRect:dstRect ofContext:context];
        }
        else {
            // no doc and no thumbnail
            [self _drawPlaceholderInRect:dstRect ofContext:context];
        }
        [self unlock];
    }
}

- (NSURL *)_fileURL { return _fileURL; }

- (void)_setFileURL:(NSURL *)aURL
{
    [_fileURL autorelease];
    _fileURL = [aURL copyWithZone:[self zone]];
}

@end

@implementation FVPDFDIcon

static NSURL * __FVCreatePDFURLForPDFBundleURL(NSURL *aURL)
{
    NSCParameterAssert(pthread_main_np() != 0);
    NSString *filePath = [aURL path];
    NSArray *files = [[NSFileManager defaultManager] subpathsAtPath:filePath];
    NSString *fileName = [[[filePath lastPathComponent] stringByDeletingPathExtension] stringByAppendingPathExtension:@"pdf"];
    NSString *pdfFile = nil;
    
    if ([files containsObject:fileName]) {
        pdfFile = fileName;
    } else {
        NSUInteger idx = [[files valueForKeyPath:@"pathExtension.lowercaseString"] indexOfObject:@"pdf"];
        if (idx != NSNotFound)
            pdfFile = [files objectAtIndex:idx];
    }
    if (pdfFile)
        pdfFile = [filePath stringByAppendingPathComponent:pdfFile];
    return pdfFile ? [[NSURL alloc] initFileURLWithPath:pdfFile] : nil;
}

// return the same thing as PDF; just a container for the URL, until actually asked to render the PDF file
- (id)initWithURL:(NSURL *)aURL;
{
    NSParameterAssert([aURL isFileURL]);
    self = [super initWithURL:aURL];
    if (self) {
        aURL = __FVCreatePDFURLForPDFBundleURL([self _fileURL]);
        if (aURL) {
            [self _setFileURL:aURL];
        } else {
            [super dealloc];
            self = nil;
        }
    }
    return self;
}

@end

@implementation FVPostScriptIcon

static NSMutableDictionary *_convertedKeys = nil;
static NSLock              *_convertedKeysLock = nil;

+ (void)initialize
{
    FVINITIALIZE(FVPostScriptIcon);
    _convertedKeys = [NSMutableDictionary new];
    _convertedKeysLock = [NSLock new];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppTerminate:) name:NSApplicationWillTerminateNotification object:nil];

}

+ (void)handleAppTerminate:(NSNotification *)aNote
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_convertedKeysLock lock];
    
    // keys are based on original file, and values are the temp PDF file(s) we created, so unlink all those files
    NSEnumerator *tempURLEnum = [[_convertedKeys allValues] objectEnumerator];  
    NSURL *aURL;
    while ((aURL = [tempURLEnum nextObject]) != nil)
        unlink([[aURL path] fileSystemRepresentation]);
    
    [_convertedKeys release];
    _convertedKeys = nil;
    [_convertedKeysLock unlock];
}

- (id)initWithURL:(NSURL *)aURL
{
    self = [super initWithURL:aURL];
    if (self) {
        _converted = NO;
    }
    return self;
}

+ (NSURL *)_temporaryPDFURL
{
    CFUUIDRef uuid = CFUUIDCreate(CFAllocatorGetDefault());
    NSString *uniqueString = (NSString *)CFUUIDCreateString(CFGetAllocator(uuid), uuid);
    CFRelease(uuid);
    NSString *newPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:uniqueString] stringByAppendingPathExtension:@"pdf"];
    NSURL *newURL = [NSURL fileURLWithPath:newPath];
    [uniqueString release];
    return newURL;
}

- (CGPDFDocumentRef)_newPDFDocument
{   
    if (NO == _converted) {
        
        [_convertedKeysLock lock];
        
        // key is based on /original/ file URL
        id key = [[FVIconCache newKeyForURL:[self _fileURL]] autorelease];
        NSURL *newURL = [_convertedKeys objectForKey:key];

        if (nil != newURL) {
            [self _setFileURL:newURL];
        }
        else {
        
            CGPSConverterCallbacks converterCallbacks = { 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL };
            CGPSConverterRef converter = CGPSConverterCreate(NULL, &converterCallbacks, NULL);    
            CGDataProviderRef provider = CGDataProviderCreateWithURL((CFURLRef)[self _fileURL]);        
            
            newURL = [FVPostScriptIcon _temporaryPDFURL];
            CGDataConsumerRef consumer = CGDataConsumerCreateWithURL((CFURLRef)newURL);
            
            // NB: the first call to CGPSConverterConvert() seems to cache ~16 MB of memory
            _converted = (NULL != provider && NULL != consumer) ? CGPSConverterConvert(converter, provider, consumer, NULL) : NO;
            CGDataProviderRelease(provider);
            CGDataConsumerRelease(consumer);
            CFRelease(converter);
            
            // Originally just kept the PDF data in-memory since conversion is so slow, but data can easily be a few MB in size for a single PS file.  Hence, we'll write the converted data to disk as a temporary PDF file, point the file URL to the temp file, and then use super's implementation.  This leaves us with a minor turd to clean up at exit or dealloc time, and duplicate PS URLs will be converted/saved each time.  A map of original->temp URL could be used if PS files are used heavily.
            if (_converted) {
                [_convertedKeys setObject:newURL forKey:key];
                [self _setFileURL:newURL];
            }
            else {
                NSLog(@"Failed to convert PostScript file %@", [[self _fileURL] path]);   
            }
        }
        [_convertedKeysLock unlock];

    }
    
    // lock in case the URL is blown away in app terminate before a mapped provider is opened
    [_convertedKeysLock lock];
    CGPDFDocumentRef pdfDoc = [super _newPDFDocument];
    [_convertedKeysLock unlock];
    
    return pdfDoc;
}


@end

