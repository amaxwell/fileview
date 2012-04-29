//
//  FVFinderIcon.m
//  FileView
//
//  Created by Adam Maxwell on 10/21/07.
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

#import "FVFinderIcon.h"
#import <pthread.h>

/*
 Apple seems to use JPEG2000 storage for icons, and decompressing them is a serious 
 performance hit on the main thread (when scrolling).  Hence, we'll create the images 
 here and burn some memory to handle the common cases.  Custom icons still get their 
 own instance and are drawn as needed with Icon Services.
 */
@interface FVSingletonFinderIcon : FVFinderIcon
{
@protected;
    CGImageRef _thumbnail;
    CGImageRef _fullImage;
}
+ (id)sharedIcon;
@end
@interface FVMissingFinderIcon : FVSingletonFinderIcon
@end
@interface FVHTTPURLIcon : FVSingletonFinderIcon
@end
@interface FVGenericURLIcon : FVSingletonFinderIcon
@end
@interface FVFTPURLIcon : FVSingletonFinderIcon
@end
@interface FVMailURLIcon : FVSingletonFinderIcon
@end
@interface FVGenericFolderIcon : FVSingletonFinderIcon
@end
@interface FVSavedSearchIcon : FVSingletonFinderIcon
@end

@implementation FVFinderIcon

+ (BOOL)_isSavedSearchURL:(NSURL *)aURL
{
    if ([aURL isFileURL] == NO)
        return NO;
    
    // rdar://problem/6028378 .savedSearch files have a dynamic UTI that does not conform to the UTI for a saved search
    
    CFStringRef extension = (CFStringRef)[[aURL path] pathExtension];
    CFStringRef UTIFromExtension = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, extension, NULL);
    BOOL isSavedSearch = NO;
    if (NULL != UTIFromExtension) {
        CFStringRef savedSearchUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, FVSTR("savedSearch"), NULL);
        if (savedSearchUTI) {
            isSavedSearch = UTTypeEqual(UTIFromExtension, savedSearchUTI);
            CFRelease(savedSearchUTI);
        }
        CFRelease(UTIFromExtension);
    }
    return isSavedSearch;
}

- (BOOL)needsRenderForSize:(NSSize)size
{
    return NO;
}

- (void)renderOffscreen
{
    // no-op
}

- (id)initWithURLScheme:(NSString *)scheme;
{
    NSParameterAssert(nil != scheme);
    [super dealloc];
        
    if ([scheme hasPrefix:@"http"])
        self = [[FVHTTPURLIcon sharedIcon] retain];
    else if ([scheme isEqualToString:@"ftp"])
        self = [[FVFTPURLIcon sharedIcon] retain];
    else if ([scheme rangeOfString:@"mail"].length)
        self = [[FVMailURLIcon sharedIcon] retain];
    else
        self = [[FVGenericURLIcon sharedIcon] retain];
    return self;
}

- (id)initWithURL:(NSURL *)theURL;
{
    // missing file icon
    if (nil == theURL) {
        [super dealloc];
        self = [[FVMissingFinderIcon sharedIcon] retain];
    }
    else if ([theURL isFileURL] == NO && [theURL scheme] != nil) {
        // non-file URLs
        self = [self initWithURLScheme:[theURL scheme]];
    }
    else if ((self = [self init])) {
        
        // this has to be a file icon, though the file itself may not exist
        _icon = NULL;
        
        NSURL *targetURL;
        _drawsLinkBadge = [[self class] _shouldDrawBadgeForURL:theURL copyTargetURL:&targetURL];        
        
        OSStatus err;
        FSRef fileRef;
        if (FALSE == CFURLGetFSRef((CFURLRef)targetURL, &fileRef))
            err = fnfErr;
        else
            err = noErr;

        BOOL isSavedSearch = [FVFinderIcon _isSavedSearchURL:targetURL];
        [targetURL release];
                
        // see if this is a plain folder; we don't want to show FVGenericFolderIcon for a package/app/custom icon
        CFTypeRef targetUTI = NULL;
        if (noErr == err)
            err = LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, &targetUTI);
                
        FSCatalogInfo catInfo;
        HFSUniStr255 name;
        if (noErr == err)
            err = FSGetCatalogInfo(&fileRef, kIconServicesCatalogInfoMask, &catInfo, &name, NULL, NULL);
        
        if (NO == _drawsLinkBadge && noErr == err && targetUTI && UTTypeEqual(targetUTI, kUTTypeFolder) && (((FolderInfo *)&catInfo.finderInfo)->finderFlags & kHasCustomIcon) == 0) {            
            [super dealloc];
/*
 There's a stupid warning about self not being assigned to [super init] or [self init],
 and the only way I can see to silence it is return early (and leak targetUTI, which
 isn't reported as a leak!), or just disable analyzer.  Incredibly, it doesn't complain
 about returning a garbage pointer here, which is what self would be after calling
 -dealloc.  Who comes up with this crap, Apple, C++ programmers?
 */
#ifndef __clang_analyzer__
            self = [[FVGenericFolderIcon sharedIcon] retain];
#endif
        }
        else if (NO == _drawsLinkBadge && isSavedSearch) {
            [super dealloc];
#ifndef __clang_analyzer__
            self = [[FVSavedSearchIcon sharedIcon] retain];
#endif
        }
        else {
            
            // header doesn't specify that this increments the refcount, but the doc page does

            if (noErr == err)
                err = GetIconRefFromFileInfo(&fileRef, name.length, name.unicode, kIconServicesCatalogInfoMask, &catInfo, kIconServicesNoBadgeFlag, &_icon, NULL);
            
            // file likely doesn't exist; can't just return FVMissingFinderIcon since we may need a link badge
            if (noErr != err)
                _icon = NULL;
        }
        
        if (targetUTI) CFRelease(targetUTI);
    }
    return self;   
}

- (void)releaseResources
{
    // do nothing
}

- (void)dealloc
{
    if (_icon) ReleaseIconRef(_icon);
    [super dealloc];
}

- (NSSize)size { return NSMakeSize(FVMaxThumbnailDimension, FVMaxThumbnailDimension); }

- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{    
    if (NULL == _icon) {
        [[FVMissingFinderIcon sharedIcon] drawInRect:dstRect ofContext:context];
    }
    else {
        CGRect rect = [self _drawingRectWithRect:dstRect];
        CGContextSaveGState(context);
        // get rid of any shadow, as the image draws it
        CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
        PlotIconRefInContext(context, &rect, kAlignAbsoluteCenter, kTransformNone, NULL, kIconServicesNoBadgeFlag, _icon);
        CGContextRestoreGState(context);
    }
    
    // We could use Icon Services to draw the badge, but it draws pure alpha with a centered badge at large sizes.  It also results in an offset image relative to the grid.
    if (_drawsLinkBadge)
        [self _badgeIconInRect:dstRect ofContext:context];
}

@end

#pragma mark Base singleton

/*
 The outContext pointer allows additional drawing on the image, but the returned
 reference is 
    a) not owned by the caller,
    b) does not neccessarily mutate the CGImage
 
 Only returns NULL if context creation fails, which shouldn't happen unless we run
 out of address space.
 */
static CGImageRef __FVCreateImageWithIcon(IconRef icon, size_t width, size_t height, CGContextRef *outContext)
{
    CGContextRef ctxt = [[FVBitmapContext bitmapContextWithSize:NSMakeSize(width, height)] graphicsPort];
    if (outContext) *outContext = ctxt;
    // should never happen; might be better to abort here...
    if (NULL == ctxt) return NULL;
    CGRect rect = CGRectZero;
    rect.size = CGSizeMake(width, height);
    CGContextClearRect(ctxt, rect);
    CGImageRef image = NULL;
    if (icon) PlotIconRefInContext(ctxt, &rect, kAlignAbsoluteCenter, kTransformNone, NULL, kIconServicesNoBadgeFlag, icon);
    image = CGBitmapContextCreateImage(ctxt);
    return image;
}

static CGImageRef __FVCreateThumbnailWithIcon(IconRef icon, CGContextRef *outContext)
{
    return __FVCreateImageWithIcon(icon, FVMaxThumbnailDimension, FVMaxThumbnailDimension, outContext);
}

static CGImageRef __FVCreateFullImageWithIcon(IconRef icon, CGContextRef *outContext)
{
    size_t dim = FVMaxImageDimension;
    /*
     Crash under _ISGetCGImageRefForISImageRef as of 10.7.3.  This seems to avoid the crash,
     but I've no idea if it's a truly good workaround.  Apply to all 10.7.x systems for now.
     rdar://problem/10809538 
     */
    if (floor(NSAppKitVersionNumber) >= 1138)
        dim = 200;
    return __FVCreateImageWithIcon(icon, dim, dim, outContext);
}

@implementation FVSingletonFinderIcon

+ (id)sharedIcon {  FVAPIAssert(0, @"subclasses must implement +sharedIcon and provide static storage"); return nil; }

- (void)dealloc
{
    FVAPIAssert1(0, @"attempt to deallocate %@", self);
    [super dealloc];
}

- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{    
    CGContextSaveGState(context);
    // get rid of any shadow, as the image draws it
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    
    if (FVShouldDrawFullImageWithThumbnailSize(dstRect.size, FVCGImageSize(_thumbnail)))
        CGContextDrawImage(context, [self _drawingRectWithRect:dstRect], _fullImage);
    else
        CGContextDrawImage(context, [self _drawingRectWithRect:dstRect], _thumbnail);
        
    CGContextRestoreGState(context);
}

@end

#pragma mark Missing file icon

@implementation FVMissingFinderIcon

static id _missingFinderIcon = nil;
static void __FVMissingFinderIconInit() { _missingFinderIcon = [FVMissingFinderIcon new]; }

+ (id)sharedIcon
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __FVMissingFinderIconInit);
    return _missingFinderIcon;
}

- (id)init
{
    self = [super init];
    if (self) {
        _drawsLinkBadge = NO;
        OSStatus err;
        _icon = NULL;
        
        IconRef questionIcon;
        err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kQuestionMarkIcon, &questionIcon);
        if (err) questionIcon = NULL;
        
        IconRef docIcon;
        err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kGenericDocumentIcon, &docIcon);
        if (err) docIcon = NULL;

        CGContextRef context;
        CGImageRef tempImage;
        
        tempImage = __FVCreateThumbnailWithIcon(docIcon, &context);
        CGRect rect = CGRectZero;
        rect.size = CGSizeMake(CGBitmapContextGetWidth(context), CGBitmapContextGetWidth(context));
        rect = CGRectInset(rect, rect.size.width/4, rect.size.height/4);
        if (questionIcon) PlotIconRefInContext(context, &rect, kAlignCenterBottom, kTransformNone, NULL, kIconServicesNoBadgeFlag, questionIcon);
        
        // create another image with the current state of the context
        _thumbnail = CGBitmapContextCreateImage(context);
        CGImageRelease(tempImage);
                
        tempImage = __FVCreateFullImageWithIcon(docIcon, &context);
        rect = CGRectZero;
        rect.size = CGSizeMake(CGBitmapContextGetWidth(context), CGBitmapContextGetWidth(context));        
        rect = CGRectInset(rect, rect.size.width/4, rect.size.height/4);
        if (questionIcon) PlotIconRefInContext(context, &rect, kAlignCenterBottom, kTransformNone, NULL, kIconServicesNoBadgeFlag, questionIcon);      
        
        _fullImage = CGBitmapContextCreateImage(context);
        CGImageRelease(tempImage);
                
        if (questionIcon) ReleaseIconRef(questionIcon);
        if (docIcon) ReleaseIconRef(docIcon);
        
    }
    return self;
}

@end

#pragma mark HTTP URL icon

@implementation FVHTTPURLIcon

static id _HTTPURLIcon = nil;
static void __FVHTTPURLIconInit() { _HTTPURLIcon = [FVHTTPURLIcon new]; }

+ (id)sharedIcon
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __FVHTTPURLIconInit);
    return _HTTPURLIcon;
}

- (id)init
{
    self = [super init];
    if (self) {
        _drawsLinkBadge = NO;
        OSStatus err;
        _icon = NULL;
        
        IconRef icon;
        err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kInternetLocationHTTPIcon, &icon);
        if (noErr == err) {
            _thumbnail = __FVCreateThumbnailWithIcon(icon, NULL);
            _fullImage = __FVCreateFullImageWithIcon(icon, NULL);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark Generic URL icon

@implementation FVGenericURLIcon

static id _genericURLIcon = nil;
static void __FVGenericURLIconInit() { _genericURLIcon = [FVGenericURLIcon new]; }

+ (id)sharedIcon
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __FVGenericURLIconInit);
    return _genericURLIcon;
}

- (id)init
{
    self = [super init];
    if (self) {
        _drawsLinkBadge = NO;
        OSStatus err;
        _icon = NULL;
        
        IconRef icon;
        err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kGenericURLIcon, &icon);
        if (noErr == err) {
            _thumbnail = __FVCreateThumbnailWithIcon(icon, NULL);
            _fullImage = __FVCreateFullImageWithIcon(icon, NULL);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark FTP URL icon

@implementation FVFTPURLIcon 

static id _FTPURLIcon = nil;
static void __FVFTPURLIconInit() { _FTPURLIcon = [FVFTPURLIcon new]; }

+ (id)sharedIcon
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __FVFTPURLIconInit);
    return _FTPURLIcon;
}

- (id)init
{
    self = [super init];
    if (self) {
        _drawsLinkBadge = NO;
        OSStatus err;
        _icon = NULL;
        
        IconRef icon;
        err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kInternetLocationFTPIcon, &icon);
        if (noErr == err) {
            _thumbnail = __FVCreateThumbnailWithIcon(icon, NULL);
            _fullImage = __FVCreateFullImageWithIcon(icon, NULL);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark Mail URL icon

@implementation FVMailURLIcon 

static id _mailURLIcon = nil;
static void __FVMailURLIconInit() { _mailURLIcon = [FVMailURLIcon new]; }

+ (id)sharedIcon
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __FVMailURLIconInit);
    return _mailURLIcon;
}

- (id)init
{
    self = [super init];
    if (self) {
        _drawsLinkBadge = NO;
        OSStatus err;
        _icon = NULL;
        
        IconRef icon;
        err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kInternetLocationMailIcon, &icon);
        if (noErr == err) {
            _thumbnail = __FVCreateThumbnailWithIcon(icon, NULL);
            _fullImage = __FVCreateFullImageWithIcon(icon, NULL);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark Generic folder icon

@implementation FVGenericFolderIcon 

static id _genericFolderIcon = nil;
static void __FVGenericFolderIconInit() { _genericFolderIcon = [FVGenericFolderIcon new]; }

+ (id)sharedIcon
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __FVGenericFolderIconInit);
    return _genericFolderIcon;
}

- (id)init
{
    self = [super init];
    if (self) {
        _drawsLinkBadge = NO;
        OSStatus err;
        _icon = NULL;
        
        IconRef icon;
        err = GetIconRef(kOnSystemDisk, kSystemIconsCreator, kGenericFolderIcon, &icon);
        if (noErr == err) {
            _thumbnail = __FVCreateThumbnailWithIcon(icon, NULL);
            _fullImage = __FVCreateFullImageWithIcon(icon, NULL);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark Saved search icon

@implementation FVSavedSearchIcon 

static id _savedSearchIcon = nil;
static void __FVSavedSearchIconInit() { _savedSearchIcon = [FVSavedSearchIcon new]; }

+ (id)sharedIcon
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __FVSavedSearchIconInit);
    return _savedSearchIcon;
}

- (id)init
{
    self = [super init];
    if (self) {
        _drawsLinkBadge = NO;
        OSStatus err;
        _icon = NULL;
        
        IconRef icon;
        err = GetIconRefFromTypeInfo(0, 0, FVSTR("savedSearch"), NULL, kIconServicesNormalUsageFlag, &icon);
        if (noErr == err) {
            _thumbnail = __FVCreateThumbnailWithIcon(icon, NULL);
            _fullImage = __FVCreateFullImageWithIcon(icon, NULL);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end
