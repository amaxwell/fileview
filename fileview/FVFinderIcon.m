//
//  FVFinderIcon.m
//  FileView
//
//  Created by Adam Maxwell on 10/21/07.
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

#import "FVFinderIcon.h"

// Apple seems to use JPEG2000 storage for icons, and decompressing them is a serious performance hit on the main thread (when scrolling).  Hence, we'll create the images here and burn some memory to handle the common cases.  Custom icons still get their own instance and are drawn as needed with Icon Services.
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

static CFStringRef _savedSearchUTI = NULL;

+ (void)initialize
{
    FVINITIALIZE(FVFinderIcon);
    
    // init on main thread to avoid race conditions
    [[FVMissingFinderIcon self] performSelectorOnMainThread:@selector(sharedIcon) withObject:nil waitUntilDone:NO];
    [[FVHTTPURLIcon self] performSelectorOnMainThread:@selector(sharedIcon) withObject:nil waitUntilDone:NO];
    [[FVGenericURLIcon self] performSelectorOnMainThread:@selector(sharedIcon) withObject:nil waitUntilDone:NO];
    [[FVFTPURLIcon self] performSelectorOnMainThread:@selector(sharedIcon) withObject:nil waitUntilDone:NO];
    [[FVMailURLIcon self] performSelectorOnMainThread:@selector(sharedIcon) withObject:nil waitUntilDone:NO];
    [[FVGenericFolderIcon self] performSelectorOnMainThread:@selector(sharedIcon) withObject:nil waitUntilDone:NO];
    [[FVSavedSearchIcon self] performSelectorOnMainThread:@selector(sharedIcon) withObject:nil waitUntilDone:NO];

    _savedSearchUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, CFSTR("savedSearch"), NULL);
}

+ (BOOL)_isSavedSearchURL:(NSURL *)aURL
{
    if ([aURL isFileURL] == NO)
        return NO;
    
    // rdar://problem/6028378 .savedSearch files have a dynamic UTI that does not conform to the UTI for a saved search
    
    CFStringRef extension = (CFStringRef)[[aURL path] pathExtension];
    CFStringRef UTIFromExtension = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, extension, NULL);
    BOOL isSavedSearch = NO;
    if (NULL != UTIFromExtension) {
        isSavedSearch = UTTypeEqual(UTIFromExtension, _savedSearchUTI);
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

- (BOOL)tryLock { return NO; }
- (void)lock { /* do nothing */ }
- (void)unlock { /* do nothing */ }

- (id)initWithURLScheme:(NSString *)scheme;
{
    NSParameterAssert(nil != scheme);
    [self release];
        
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
        [self release];
        self = [[FVMissingFinderIcon sharedIcon] retain];
    }
    else if ([theURL isFileURL] == NO && [theURL scheme] != nil) {
        // non-file URLs
        self = [self initWithURLScheme:[theURL scheme]];
    }
    else if ((self = [super init])) {
        
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
        CFStringRef targetUTI = NULL;
        err = LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, (CFTypeRef *)&targetUTI);
                
        FSCatalogInfo catInfo;
        HFSUniStr255 name;
        err = FSGetCatalogInfo(&fileRef, kIconServicesCatalogInfoMask, &catInfo, &name, NULL, NULL);
        if (NO == _drawsLinkBadge && noErr == err && targetUTI && UTTypeEqual(targetUTI, kUTTypeFolder) && (((FolderInfo *)&catInfo.finderInfo)->finderFlags & kHasCustomIcon) == 0) {            
            [self release];
            self = [[FVGenericFolderIcon sharedIcon] retain];
        }
        else if (NO == _drawsLinkBadge && isSavedSearch) {
            [self release];
            self = [[FVSavedSearchIcon sharedIcon] retain];
        }
        else {
            
            // header doesn't specify that this increments the refcount, but the doc page does

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

static CGImageRef __FVCreateImageWithIcon(IconRef icon, size_t width, size_t height)
{
    CGContextRef ctxt = FVIconBitmapContextCreateWithSize(width, height);
    CGRect rect = CGRectZero;
    rect.size = CGSizeMake(width, height);
    CGImageRef image = NULL;
    if (noErr == PlotIconRefInContext(ctxt, &rect, kAlignAbsoluteCenter, kTransformNone, NULL, kIconServicesNoBadgeFlag, icon))
        image = CGBitmapContextCreateImage(ctxt);
    FVIconBitmapContextDispose(ctxt);
    return image;
}

static CGImageRef __FVCreateThumbnailWithIcon(IconRef icon)
{
    return __FVCreateImageWithIcon(icon, FVMaxThumbnailDimension, FVMaxThumbnailDimension);
}

static CGImageRef __FVCreateFullImageWithIcon(IconRef icon)
{
    return __FVCreateImageWithIcon(icon, FVMaxImageDimension, FVMaxImageDimension);
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

+ (id)sharedIcon
{
    static id sharedInstance = nil;
    if (nil == sharedInstance)
        sharedInstance = [[self allocWithZone:[self zone]] init];
    return sharedInstance;
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

        CGContextRef context = FVIconBitmapContextCreateWithSize(FVMaxThumbnailDimension, FVMaxThumbnailDimension);
        CGRect rect = CGRectZero;
        
        rect.size = CGSizeMake(FVMaxThumbnailDimension, FVMaxThumbnailDimension);
        if (docIcon) PlotIconRefInContext(context, &rect, kAlignAbsoluteCenter, kTransformNone, NULL, kIconServicesNoBadgeFlag, docIcon);

        rect = CGRectInset(rect, rect.size.width/4, rect.size.height/4);
        if (questionIcon) PlotIconRefInContext(context, &rect, kAlignCenterBottom, kTransformNone, NULL, kIconServicesNoBadgeFlag, questionIcon);          
        
        _thumbnail = CGBitmapContextCreateImage(context);        
        FVIconBitmapContextDispose(context);
        
        context = FVIconBitmapContextCreateWithSize(FVMaxImageDimension, FVMaxImageDimension);
        rect = CGRectZero;
        
        rect.size = CGSizeMake(FVMaxImageDimension, FVMaxImageDimension);
        if (docIcon) PlotIconRefInContext(context, &rect, kAlignAbsoluteCenter, kTransformNone, NULL, kIconServicesNoBadgeFlag, docIcon);
        
        rect = CGRectInset(rect, rect.size.width/4, rect.size.height/4);
        if (questionIcon) PlotIconRefInContext(context, &rect, kAlignCenterBottom, kTransformNone, NULL, kIconServicesNoBadgeFlag, questionIcon);          
        
        _fullImage = CGBitmapContextCreateImage(context);        
        FVIconBitmapContextDispose(context);
        
        if (questionIcon) ReleaseIconRef(questionIcon);
        if (docIcon) ReleaseIconRef(docIcon);
        
    }
    return self;
}

@end

#pragma mark HTTP URL icon

@implementation FVHTTPURLIcon

+ (id)sharedIcon
{
    static id sharedInstance = nil;
    if (nil == sharedInstance)
        sharedInstance = [[self allocWithZone:[self zone]] init];
    return sharedInstance;
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
            _thumbnail = __FVCreateThumbnailWithIcon(icon);
            _fullImage = __FVCreateFullImageWithIcon(icon);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark Generic URL icon

@implementation FVGenericURLIcon

+ (id)sharedIcon
{
    static id sharedInstance = nil;
    if (nil == sharedInstance)
        sharedInstance = [[self allocWithZone:[self zone]] init];
    return sharedInstance;
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
            _thumbnail = __FVCreateThumbnailWithIcon(icon);
            _fullImage = __FVCreateFullImageWithIcon(icon);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark FTP URL icon

@implementation FVFTPURLIcon 

+ (id)sharedIcon
{
    static id sharedInstance = nil;
    if (nil == sharedInstance)
        sharedInstance = [[self allocWithZone:[self zone]] init];
    return sharedInstance;
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
            _thumbnail = __FVCreateThumbnailWithIcon(icon);
            _fullImage = __FVCreateFullImageWithIcon(icon);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark Mail URL icon

@implementation FVMailURLIcon 

+ (id)sharedIcon
{
    static id sharedInstance = nil;
    if (nil == sharedInstance)
        sharedInstance = [[self allocWithZone:[self zone]] init];
    return sharedInstance;
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
            _thumbnail = __FVCreateThumbnailWithIcon(icon);
            _fullImage = __FVCreateFullImageWithIcon(icon);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark Generic folder icon

@implementation FVGenericFolderIcon 

+ (id)sharedIcon
{
    static id sharedInstance = nil;
    if (nil == sharedInstance)
        sharedInstance = [[self allocWithZone:[self zone]] init];
    return sharedInstance;
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
            _thumbnail = __FVCreateThumbnailWithIcon(icon);
            _fullImage = __FVCreateFullImageWithIcon(icon);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end

#pragma mark Saved search icon

@implementation FVSavedSearchIcon 

+ (id)sharedIcon
{
    static id sharedInstance = nil;
    if (nil == sharedInstance)
        sharedInstance = [[self allocWithZone:[self zone]] init];
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _drawsLinkBadge = NO;
        OSStatus err;
        _icon = NULL;
        
        IconRef icon;
        err = GetIconRefFromTypeInfo(0, 0, CFSTR("savedSearch"), NULL, kIconServicesNormalUsageFlag, &icon);
        if (noErr == err) {
            _thumbnail = __FVCreateThumbnailWithIcon(icon);
            _fullImage = __FVCreateFullImageWithIcon(icon);
            ReleaseIconRef(icon);
        }
    }
    return self;
}

@end
