//
//  FVTextIcon.m
//  FileView
//
//  Created by Adam Maxwell on 10/21/07.
/*
 This software is Copyright (c) 2007-2013
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

#import "FVTextIcon.h"
#import "FVCoreTextIcon.h"
#import "FVIcon_Private.h"
#import "FVConcreteOperation.h"
#import "FVOperationQueue.h"

@interface _FVAttributedStringOperation : FVConcreteOperation
{
@private;
    NSURL                     *_fileURL;
    NSDictionary              *_documentAttributes;
    NSMutableAttributedString *_attributedString;
}

- (id)initWithURL:(NSURL *)aURL;
- (NSMutableAttributedString *)attributedString;
- (NSDictionary *)documentAttributes;

@end

@implementation FVTextIcon

static Class FVTextIconClass = Nil;
static NSMutableSet *_cachedTextSystems = nil;
static OSSpinLock _cacheLock = OS_SPINLOCK_INIT;

#define MAX_CACHED_TEXT_SYSTEMS 10
#define USE_CORE_TEXT 1

+ (void)initialize
{
    FVINITIALIZE(FVTextIcon);
    
    FVTextIconClass = self;
    // make sure we compare with pointer equality; all I really want is a bag
    _cachedTextSystems = (NSMutableSet *)CFSetCreateMutable(NULL, MAX_CACHED_TEXT_SYSTEMS, &FVNSObjectPointerSetCallBacks);
}

#if USE_CORE_TEXT && (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)
+ (id)allocWithZone:(NSZone *)aZone
{
    if (floor(NSAppKitVersionNumber > NSAppKitVersionNumber10_4) && self == FVTextIconClass)
        return [FVCoreTextIcon allocWithZone:aZone];
    else
        return [super allocWithZone:aZone];
}
#endif

+ (NSSize)_containerSize
{
    // could add in NSTextContainer's default lineFragmentPadding
    NSSize containerSize = FVDefaultPaperSize;
    containerSize.width -= 2 * FVSideMargin;
    containerSize.height -= 2* FVTopMargin;
    return containerSize;
}

// A particular layout manager/text storage combination is not thread safe, so the AppKit string drawing routines must only be used from the main thread.  We're using the thread dictionary to cache our string drawing machinery on a per-thread basis.  Update:  for the record, Aki Inoue says that NSStringDrawing is supposed to be thread safe, so the crash I experienced may be something else.
+ (NSTextStorage *)_newTextStorage;
{
    NSTextStorage *textStorage = [[NSTextStorage allocWithZone:[self zone]] init];
    NSLayoutManager *lm = [[NSLayoutManager allocWithZone:[self zone]] init];
    // don't let the layout manager use its threaded layout (see header)
    [lm setBackgroundLayoutEnabled:NO];
    [textStorage addLayoutManager:lm];
    // retained by text storage
    [lm release];
    // see header; the CircleView example sets it to NO
    [lm setUsesScreenFonts:YES];
    NSTextContainer *tc = [[NSTextContainer allocWithZone:[self zone]] initWithContainerSize:[self _containerSize]];
    [lm addTextContainer:tc];
    // retained by layout manager
    [tc release];    
    return textStorage;
}

+ (NSTextStorage *)popTextStorage
{
    OSSpinLockLock(&_cacheLock);
    NSTextStorage *textStorage = [_cachedTextSystems anyObject];
    if (textStorage) {
        [textStorage retain];
        [_cachedTextSystems removeObject:textStorage];
    }
    OSSpinLockUnlock(&_cacheLock);
    if (nil == textStorage)
        textStorage = [self _newTextStorage];
    return [textStorage autorelease];
}

+ (void)pushTextStorage:(NSTextStorage *)textStorage
{
    // no point in keeping this around in memory; deleteCharactersInRange: seems to leak an NSConcreteAttributedString
    NSAttributedString *empty = [NSAttributedString new];
    [textStorage replaceCharactersInRange:NSMakeRange(0, [textStorage length]) withAttributedString:empty];
    [empty release];

    OSSpinLockLock(&_cacheLock);
    if ([_cachedTextSystems count] < MAX_CACHED_TEXT_SYSTEMS) {
        [_cachedTextSystems addObject:textStorage];
    }
    OSSpinLockUnlock(&_cacheLock);
}

// allows a crude sniffing, so initWithTextAtURL: doesn't have to immediately instantiate an attributed string ivar and return nil if that fails

+ (NSArray *)_supportedUTIs
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
    return [NSAttributedString textUnfilteredTypes];
#else
    // new in 10.5
    if ([NSAttributedString respondsToSelector:@selector(textUnfilteredTypes)])
        return [NSAttributedString performSelector:@selector(textUnfilteredTypes)];
    
    NSMutableSet *UTIs = [NSMutableSet set];
    NSEnumerator *typeEnum = [[NSAttributedString textUnfilteredFileTypes] objectEnumerator];
    NSString *aType;
    CFStringRef aUTI;
    
    // checking OSType and extension gives lots of duplicates, but the set filters them out
    while ((aType = [typeEnum nextObject])) {
        OSType osType = NSHFSTypeCodeFromFileType(aType);
        if (0 != osType) {
            aUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassOSType, (CFStringRef)aType, NULL);
        }
        else {
            aUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (CFStringRef)aType, NULL);
        }
        if (NULL != aUTI) {
            [UTIs addObject:(id)aUTI];
            CFRelease(aUTI);
        }
    }
    return [UTIs allObjects];
#endif
}

/*
 This should be very reliable, but in practice it's only as reliable as the UTI declaration.  
 For instance, OmniGraffle declares .graffle files as public.composite-content and public.xml 
 in its Info.plist.  Since we see that it's public.xml (which is in this list), we open it as 
 text, and it will actually open with NSAttributedString...and display as binary garbage.
 */
+ (BOOL)canInitWithUTI:(NSString *)aUTI
{
    static NSArray *types = nil;
    if (nil == types) {
        NSMutableArray *a = [NSMutableArray arrayWithArray:[self _supportedUTIs]];
        // avoid threading issues on 10.4; this class should never be asked to render HTML anyway, since that's now handled by FVWebViewIcon
        if (floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_4) {
            [a removeObject:(id)kUTTypeHTML];
            [a removeObject:(id)kUTTypeWebArchive];
        }
        types = [a copyWithZone:[self zone]];
    }

    NSUInteger cnt = [types count];
    while (cnt--)
        if (UTTypeConformsTo((CFStringRef)aUTI, (CFStringRef)[types objectAtIndex:cnt]))
            return YES;
    return NO;
}

// This is mainly useful to prove that the file cannot be opened; as in the case of OmniGraffle files (see comment above), it returns YES.
+ (BOOL)canInitWithURL:(NSURL *)aURL;
{
    /*
     If on the main thread, NSHTMLReader will run the main thread's runloop in the default
     mode.  This can have really bad side effects, such as forcing the FileView to redraw
     while it's trying to create an icon.  Way to use the runloop, Apple.  See the
     _fvFlags.reloadingController bit in FileView for the workaround, since I don't really
     want to lose this check.
     
     Excluding HTML from the +canInitWithUTI: test is not sufficient to avoid this problem,
     since +canInitWithURL: is called for extensionless files.
     */
    NSAttributedString *attributedString = [[NSAttributedString allocWithZone:[self zone]] initWithURL:aURL documentAttributes:NULL];
    BOOL canInit = (nil != attributedString);
    [attributedString release];
    return canInit;
}

- (id)initWithURL:(NSURL *)aURL isPlainText:(BOOL)isPlainText
{
    self = [super initWithURL:aURL];
    if (self) {
        _fullSize = FVDefaultPaperSize;
        _thumbnailSize = FVDefaultPaperSize;
        // first approximation
        FVIconLimitThumbnailSize(&_thumbnailSize);
        _desiredSize = NSZeroSize;
        _fullImage = NULL;
        _thumbnail = NULL;
        _isPlainText = isPlainText;
    }
    return self;
}

- (id)initWithURL:(NSURL *)aURL;
{
    return [self initWithURL:aURL isPlainText:NO];
}

- (void)dealloc
{
    CGImageRelease(_fullImage);
    CGImageRelease(_thumbnail);
    [super dealloc];
}

- (NSSize)size { return _fullSize; }

- (BOOL)needsRenderForSize:(NSSize)size { 
    BOOL needsRender = NO;
    // if we can't lock we're already rendering, which will give us both icons (so no render required)
    if ([self tryLock]) {
        _desiredSize = size;
        if (FVShouldDrawFullImageWithThumbnailSize(size, _thumbnailSize))
            needsRender = (NULL == _fullImage);
        else
            needsRender = (NULL == _thumbnail);
        [self unlock];
    }
    return needsRender;
}

// It turns out to be fairly important to draw small text icons if possible, since the bitmaps have a pretty huge memory footprint (if we draw _fullImage all the time, dragging in the view is unbearably slow if there are more than a couple of text icons).  Using trylock for drawing to avoid stalling the main thread while rendering; there are some degenerate cases where rendering is really slow (e.g. a huge ASCII grid file).
- (void)fastDrawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{
    // draw thumbnail if present, regardless of the size requested
    if (NO == [self tryLock]) {
        // no lock, so just draw the blank page and bail out
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
    else if (NULL == _thumbnail) {
        [self unlock];
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
    else if (_thumbnail) {
        CGContextDrawImage(context, [self _drawingRectWithRect:dstRect], _thumbnail);
        [self unlock];
        if (_drawsLinkBadge)
            [self _badgeIconInRect:dstRect ofContext:context];
    }
    else {
        [self unlock];
        // let drawInRect: handle the rect conversion
        [self drawInRect:dstRect ofContext:context];
    }
}

- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{
    if (NO == [self tryLock]) {
        [self _drawPlaceholderInRect:dstRect ofContext:context];
    }
    else {
        CGRect drawRect = [self _drawingRectWithRect:dstRect];
        CGImageRef toDraw = _thumbnail;
        
        if (FVShouldDrawFullImageWithThumbnailSize(dstRect.size, _thumbnailSize))
            toDraw = _fullImage;
        
        // draw the image if it's been created, or just draw a dummy icon
        if (toDraw) {
            CGContextDrawImage(context, drawRect, toDraw);
            [self unlock];
            if (_drawsLinkBadge)
                [self _badgeIconInRect:dstRect ofContext:context];
        }
        else {
            [self unlock];
            [self _drawPlaceholderInRect:dstRect ofContext:context];
        }
    }
}

- (BOOL)canReleaseResources;
{
    return (NULL != _fullImage || NULL != _thumbnail);
}

- (void)releaseResources
{
    [self lock];
    CGImageRelease(_fullImage);
    _fullImage = NULL;
    CGImageRelease(_thumbnail);
    _thumbnail = NULL;
    [self unlock];
}

- (void)recache;
{
    [FVCGImageCache invalidateCachesForKey:_cacheKey];
    [self releaseResources];
}

- (CGImageRef)_newImageWithAttributedString:(NSMutableAttributedString *)attrString documentAttributes:(NSDictionary *)documentAttributes
{
    NSParameterAssert(attrString);
    CGContextRef ctxt = [[FVBitmapContext bitmapContextWithSize:FVDefaultPaperSize] graphicsPort];

    // set up default page layout parameters
    CGAffineTransform t1 = CGAffineTransformMakeTranslation(FVSideMargin, FVDefaultPaperSize.height - FVTopMargin);
    CGAffineTransform t2 = CGAffineTransformMakeScale(1, -1);
    CGAffineTransform pageTransform = CGAffineTransformConcat(t2, t1);    
    NSSize containerSize = [[self class] _containerSize];
    NSSize paperSize = FVDefaultPaperSize;
    
    // default to white background
    CGFloat backgroundComps[4] = { 1.0, 1.0, 1.0, 1.0 };

    // use a monospaced font for plain text
    if (nil == documentAttributes || [[documentAttributes objectForKey:NSDocumentTypeDocumentAttribute] isEqualToString:NSPlainTextDocumentType]) {
        NSFont *plainFont = [NSFont userFixedPitchFontOfSize:10.0f];
        [attrString addAttribute:NSFontAttributeName value:plainFont range:NSMakeRange(0, [attrString length])];
    }
    else if (nil != documentAttributes) {
        
        CGFloat left, right, top, bottom;
        
        left = [[documentAttributes objectForKey:NSLeftMarginDocumentAttribute] floatValue];
        right = [[documentAttributes objectForKey:NSRightMarginDocumentAttribute] floatValue];
        top = [[documentAttributes objectForKey:NSTopMarginDocumentAttribute] floatValue];
        bottom = [[documentAttributes objectForKey:NSBottomMarginDocumentAttribute] floatValue];
        paperSize = [[documentAttributes objectForKey:NSPaperSizeDocumentAttribute] sizeValue];
        
        t1 = CGAffineTransformMakeTranslation(0, paperSize.height);
        t2 = CGAffineTransformMakeScale(1, -1);
        pageTransform = CGAffineTransformConcat(t2, t1);
        t1 = CGAffineTransformMakeTranslation(left, -bottom);
        pageTransform = CGAffineTransformConcat(pageTransform, t1);
        containerSize.width = paperSize.width - left - right;
        containerSize.height = paperSize.height - top - bottom;
        
        NSColor *nsColor = [documentAttributes objectForKey:NSBackgroundColorDocumentAttribute];
        nsColor = [nsColor colorUsingColorSpaceName:NSDeviceRGBColorSpace];  
        [nsColor getRed:&backgroundComps[0] green:&backgroundComps[1] blue:&backgroundComps[2] alpha:&backgroundComps[3]];
    }
        
    NSRect stringRect = NSZeroRect;
    stringRect.size = paperSize;
    
    CGContextSaveGState(ctxt);
    
    CGContextSetRGBFillColor(ctxt, backgroundComps[0], backgroundComps[1], backgroundComps[2], backgroundComps[3]);
    CGContextFillRect(ctxt, NSRectToCGRect(stringRect));
    
    CGContextConcatCTM(ctxt, pageTransform);
    
    // we flipped the CTM in our bitmap context since NSLayoutManager expects a flipped context
    NSGraphicsContext *nsCtxt = [NSGraphicsContext graphicsContextWithGraphicsPort:ctxt flipped:YES];
    
    // save whatever is current on this thread, since we're going to use setCurrentContext:
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nsCtxt];
    
    NSTextStorage *textStorage = [FVTextIcon popTextStorage];
    [textStorage setAttributedString:attrString];
    
    // objectAtIndex:0 is safe, since we added these to the text storage (so there's at least one)
    NSLayoutManager *lm = [[textStorage layoutManagers] objectAtIndex:0];
    NSTextContainer *tc = [[lm textContainers] objectAtIndex:0];
    [tc setContainerSize:containerSize];
        
    // we now have a properly flipped graphics context, so force layout and then draw the text
    NSRange glyphRange = [lm glyphRangeForBoundingRect:stringRect inTextContainer:tc];
    NSRect usedRect = [lm usedRectForTextContainer:tc];
    
    // NSRunStorage raises if we try drawing a zero length range (happens if you have an empty text file)
    if (glyphRange.length > 0) {
        [lm drawBackgroundForGlyphRange:glyphRange atPoint:usedRect.origin];
        [lm drawGlyphsForGlyphRange:glyphRange atPoint:usedRect.origin];
    }
    
    // text is drawn, so we're done with this
    [FVTextIcon pushTextStorage:textStorage];
    
    // restore the previous context
    [NSGraphicsContext restoreGraphicsState];
    
    // restore the bitmap context's state (although it's gone after this operation)
    CGContextRestoreGState(ctxt);
    
    CGImageRef image = CGBitmapContextCreateImage(ctxt);
    
    return image;
    
}    

- (void)renderOffscreen
{
    [[self class] _startRenderingForKey:_cacheKey];

    // hold the lock to let needsRenderForSize: know that this icon doesn't need rendering
    [self lock];
    
    if ([NSThread instancesRespondToSelector:@selector(setName:)] && pthread_main_np() == 0)
        [[NSThread currentThread] setName:[_fileURL path]];
    
    // !!! two early returns here after a cache check

    if (NULL != _fullImage) {
        // note that _fullImage may be non-NULL if we were added to the FVOperationQueue multiple times before renderOffscreen was called
        [self unlock];
        [[self class] _stopRenderingForKey:_cacheKey];
        return;
    } 
    else {
        
        if (NULL == _thumbnail) {
            _thumbnail = [FVCGImageCache newThumbnailForKey:_cacheKey];
            _thumbnailSize = FVCGImageSize(_thumbnail);
        }
        
        if (_thumbnail && FVShouldDrawFullImageWithThumbnailSize(_desiredSize, _thumbnailSize)) {
            _fullImage = [FVCGImageCache newImageForKey:_cacheKey];
            if (NULL != _fullImage) {
                [self unlock];
                [[self class] _stopRenderingForKey:_cacheKey];
                return;
            }
        }
        
        if (NULL != _thumbnail) {
            [self unlock];
            [[self class] _stopRenderingForKey:_cacheKey];
            return;
        }
    }

    /*
     At this point, neither icon should be present, unless ImageIO failed previously or caching failed.  
     However, if multiple views are caching icons at the same time, we can end up here with a thumbnail 
     but no full image.
     */
    NSParameterAssert(NULL == _fullImage);
        
    // originally kept the attributed string as an ivar, but it's not worth it in most cases
    
    // no need to lock for -fileURL since it's invariant
    NSDictionary *documentAttributes = nil;
    NSMutableAttributedString *attrString = nil;
    
    /* 
     This is a minor optimization: NSAttributedString creates a bunch of temporary objects for pasteboard 
     translation when reading a file, but we avoid that by loading with NSString directly.  Interestingly, 
     this also appears to be at least a partial workaround for rdar://problem/5775728 (CoreGraphics memory leaks), 
     since Instruments shows I'm only leaking a single NSConcreteAttributedString here now.
     */
    if (_isPlainText) {
        NSStringEncoding enc;
        NSString *text = [[NSString allocWithZone:[self zone]] initWithContentsOfURL:_fileURL usedEncoding:&enc error:NULL];
        if (nil == text)
            text = [[NSString allocWithZone:[self zone]] initWithContentsOfURL:_fileURL encoding:NSMacOSRomanStringEncoding error:NULL];
        
        if (text) {
            attrString = [[NSMutableAttributedString allocWithZone:[self zone]] initWithString:text];
            [text release];
        }
    }

    // not plain text, so try to load with NSAttributedString
    if (nil == attrString) {
        /*
         Occasionally NSAttributedString might end up calling NSHTMLReader/WebKit to load a file, which raises 
         an exception and crashes on 10.4.  The workaround is to always load on the main thread on 10.4.
         */
        if (floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_4) {
            [attrString release];
            _FVAttributedStringOperation *operation = [[_FVAttributedStringOperation allocWithZone:[self zone]] initWithURL:_fileURL];
            [[FVOperationQueue mainQueue] addOperation:operation];
            while (NO == [operation isFinished])
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, TRUE);
            attrString = [[operation attributedString] retain];
            documentAttributes = [[[operation documentAttributes] retain] autorelease];
            [operation release];
        }
        else {
            attrString = [[NSMutableAttributedString allocWithZone:[self zone]] initWithURL:_fileURL documentAttributes:&documentAttributes];
        }
    }
    
    // plain text failed and so did NSAttributedString, so display a mildly unhelpful error message
    if (nil == attrString) {
        NSBundle *bundle = [NSBundle bundleForClass:[FVTextIcon class]];        
        NSString *err = [NSLocalizedStringFromTableInBundle(@"Unable to read text file ", @"FileView", bundle, @"error message with single trailing space") stringByAppendingString:[_fileURL path]];
        attrString = [[NSMutableAttributedString alloc] initWithString:err];
    }
    FVAPIParameterAssert(nil != attrString);
    
    CGImageRelease(_fullImage);
    _fullImage = [self _newImageWithAttributedString:attrString documentAttributes:documentAttributes];
    [attrString release];
        
    if (NULL != _fullImage) {        
        // reset size while we have the lock, since it may be different now that we've read the string
        _fullSize = FVCGImageSize(_fullImage);
    }
        
    // resample the existing bitmap to create a thumbnail image
    if (NULL == _thumbnail)
        _thumbnail = FVCreateResampledThumbnail(_fullImage);
        
    // local copies for caching
    CGImageRef fullImage = CGImageRetain(_fullImage), thumbnail = CGImageRetain(_thumbnail);

    if (NULL != _thumbnail) 
        _thumbnailSize = FVCGImageSize(_thumbnail);
    
    // get rid of this to save memory if we aren't drawing it right away
    if (FVShouldDrawFullImageWithThumbnailSize(_desiredSize, _thumbnailSize) == NO) {
        CGImageRelease(_fullImage);
        _fullImage = NULL;
    }
    
    // can draw now
    [self unlock];    
    
    // cache and release
    if (fullImage) [FVCGImageCache cacheImage:fullImage forKey:_cacheKey];
    CGImageRelease(fullImage);
    if (thumbnail) [FVCGImageCache cacheThumbnail:thumbnail forKey:_cacheKey];
    CGImageRelease(thumbnail);

    [[self class] _stopRenderingForKey:_cacheKey];
}

@end

@implementation _FVAttributedStringOperation

- (id)initWithURL:(NSURL *)aURL;
{
    self = [super init];
    if (self) {
        _fileURL = [aURL copyWithZone:[self zone]];
        [self setConcurrent:NO];
    }
    return self;
}

- (void)dealloc
{
    [_fileURL release];
    [_documentAttributes release];
    [_attributedString release];
    [super dealloc];
}

- (void)main
{
    NSAssert(pthread_main_np() != 0, @"incorrect thread for _FVAttributedStringOperation");        
    NSDictionary *documentAttributes;
    _attributedString = [[NSMutableAttributedString allocWithZone:[self zone]] initWithURL:_fileURL documentAttributes:&documentAttributes];
    _documentAttributes = [documentAttributes copyWithZone:[self zone]];
    [self finished];
}

- (NSMutableAttributedString *)attributedString { return _attributedString; }
- (NSDictionary *)documentAttributes { return _documentAttributes; }

@end
