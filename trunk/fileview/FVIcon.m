//
//  FVIcon.m
//  FileViewTest
//
//  Created by Adam Maxwell on 08/31/07.
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

#import "FVIcon.h"
#import "FVImageIcon.h"
#import "FVFinderIcon.h"
#import "FVPDFIcon.h"
#import "FVTextIcon.h"
#import "FVQuickLookIcon.h"
#import "FVWebViewIcon.h"
#import "FVMovieIcon.h"
#import "FVIcon_Private.h"

#pragma mark FVIcon abstract class

/* 
 Placeholder class to allow correct allocation behavior with multiple zones.
 */
@interface FVPlaceholderIcon : FVIcon 
@end

// FVIcon abstract class stuff
static Class FVIconClass = Nil;
static Class FVPlaceholderIconClass = Nil;
static Class FVQLIconClass = Nil;
static NSURL *_missingFileURL = nil;

static NSMapTable *_placeholders = NULL;
static FVPlaceholderIcon *_defaultPlaceholderIcon = nil;

@implementation FVPlaceholderIcon
/*
 Allocate the actual object in the default zone.  If the zone is recycled and its pointer is reused as a zone, 
 the map table will still have a valid placeholder for the zone (which is all we need it for).
 */
+ (id)allocWithZone:(NSZone *)aZone 
{
    FVPlaceholderIcon *icon = NSAllocateObject(FVPlaceholderIconClass, sizeof(NSZone *), NSDefaultMallocZone());
    NSZone **storage = object_getIndexedIvars(icon);
    storage[0] = aZone;
    return icon;
}
+ (id)alloc { [NSException raise:NSInvalidArgumentException format:@"Must use allocWithZone: and a valid NSZone"]; return nil; }
/* 
 This will not be equivalent to malloc_zone_from_ptr(), except in the case of the default zone.
 Since NSDeallocateObject() is never called, this should not be a problem; it's just a convenience for the replacement initializer.  */
- (NSZone *)zone { return *(NSZone **)object_getIndexedIvars(self); }
- (void)dealloc { /* do nothing */ if (0) [super dealloc]; }
- (NSString *)description { return [NSString stringWithFormat:@"%@: placeholder for zone %@", [super description], NSZoneName([self zone])]; }
@end


@implementation FVIcon

+ (void)initialize
{
    FVINITIALIZE(FVIcon);
    
    FVIconClass = self;
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4)
        FVQLIconClass = [FVQuickLookIcon self];
    
    // Non-owned callbacks allow a negligible leak if multithreaded, but avoids locking.
    _placeholders = NSCreateMapTableWithZone(NSNonOwnedPointerMapKeyCallBacks, NSNonRetainedObjectMapValueCallBacks, 4, NSDefaultMallocZone());
    // Set up a fast path for the default zone
    FVPlaceholderIconClass = [FVPlaceholderIcon self];
    _defaultPlaceholderIcon = [FVPlaceholderIcon allocWithZone:NSDefaultMallocZone()];
    _missingFileURL = [[NSURL alloc] initWithScheme:@"x-fileview" host:@"localhost" path:@"/missing"];
    [self _initializeCategory];
}

static inline id _placeholderForZone(NSZone *aZone)
{
    FVPlaceholderIcon * placeholder;

    if (NULL == aZone || aZone == NSDefaultMallocZone()) {
        placeholder = _defaultPlaceholderIcon;
    }
    else {
        placeholder = NSMapGet(_placeholders, aZone);
        if (NULL == placeholder) {
            placeholder = [FVPlaceholderIcon allocWithZone:aZone];
            NSMapInsert(_placeholders, aZone, placeholder);
            NSCParameterAssert(NULL != placeholder);
        }
    }
    return placeholder;
}

+ (id)allocWithZone:(NSZone *)aZone
{
    return FVIconClass == self ? _placeholderForZone(aZone) : NSAllocateObject(self, 0, aZone);
}

// ensure that alloc always calls through to allocWithZone:
+ (id)alloc
{
    return [self allocWithZone:NULL];
}

+ (NSURL *)missingFileURL;
{
    return _missingFileURL;
}

+ (id)iconWithURL:(NSURL *)representedURL;
{
    return [[[self allocWithZone:NULL] initWithURL:representedURL] autorelease];
}

- (id)initWithURL:(NSURL *)representedURL;
{
    // CFURLGetFSRef won't like a nil URL
    NSParameterAssert(nil != representedURL);
    // Subclassers must not call super, or we'd end up with an endless loop
    FVAPIAssert2([self isMemberOfClass:FVPlaceholderIconClass], @"Invalid to invoke %@ on object of class %@", NSStringFromSelector(_cmd), [self class]);
    NSZone *zone = [self zone];
    
    NSString *scheme = [representedURL scheme];
    
    // initWithURLScheme requires a scheme, so there's not much we can do without it
    if ([representedURL isEqual:_missingFileURL] || nil == scheme) {
        return [[FVFinderIcon allocWithZone:zone] initWithURL:nil];
    }
    else if (NO == [representedURL isFileURL]) {
        return [[FVWebViewIcon allocWithZone:zone] initWithURL:representedURL];
    }
    
    OSStatus err = noErr;
    
    FSRef fileRef;
    
    // convert to an FSRef without resolving symlinks, to get the UTI of the actual URL
    const UInt8 *fsPath = (void *)[[representedURL path] fileSystemRepresentation];
    err = FSPathMakeRefWithOptions(fsPath, kFSPathMakeRefDoNotFollowLeafSymlink, &fileRef, NULL);
    
    // return missing file icon if we can't convert the path to an FSRef
    if (noErr != err)
        return [[FVFinderIcon allocWithZone:zone] initWithURL:nil];    
    
    // kLSItemContentType returns a CFStringRef, according to the header
    CFTypeRef theUTI = NULL;
    // theUTI will be NULL if this fails
    if (noErr == err)
        LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, &theUTI);
    
    /*
     For a link/alias, get the target's UTI in order to determine which concrete subclass to create.  
     Subclasses that are file-based need to check the URL to see if it should be badged using 
     _shouldDrawBadgeForURL, and then call _resolvedURLWithURL in order to actually load the file's content.
     */
    
    // aliases and symlinks are kUTTypeResolvable, so the alias manager should handle either of them
    if (NULL != theUTI && UTTypeConformsTo(theUTI, kUTTypeResolvable)) {
        Boolean isFolder, wasAliased;
        err = FSResolveAliasFileWithMountFlags(&fileRef, TRUE, &isFolder, &wasAliased, kResolveAliasFileNoUI);
        // don't change the UTI if it couldn't be resolved; in that case, we should just show a finder icon
        if (noErr == err) {
            CFRelease(theUTI);
            theUTI = NULL;
            // theUTI will be NULL if this fails
            LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, &theUTI);
        }
    }
    
    
    // limit FVTextIcon to < 20 MB files; layout is really slow with large files
    const UInt64 maximumTextDataSize = 20 * 1024 * 1024;
    
    /*
     Limit FVImageIcon to < 250 MB files; resampling is expensive (using CG to resample requires a 
     limit of ~50 MB, but we can get away with larger sizes using vImage and tiling).
     */
    const UInt64 maximumImageDataSize = 250 * 1024 * 1024;
    
    FSCatalogInfo catInfo;
    UInt64 dataPhysicalSize = 0;
    err = FSGetCatalogInfo(&fileRef, kFSCatInfoNodeFlags | kFSCatInfoDataSizes, &catInfo, NULL, NULL, NULL);
    if (noErr == err && (catInfo.nodeFlags & kFSNodeIsDirectoryMask) == 0)
        dataPhysicalSize = catInfo.dataPhysicalSize;
    
    FVIcon *anIcon = nil;
    
    /*
     Problems here.  TextMate claims a lot of plain text types but doesn't declare a UTI for any of them, 
     so I end up with a dynamic UTI, and Spotlight/Quick Look ignore the files since they have no idea of
     conformance to plain text.  That's broken behavior on TextMate's part, and it sucks for my purposes. 
     Additionally, files that are named "README" are public.data, but actually plain text files.  Since 
     LS doesn't sniff types, we'll just try to open anything that's equal (not conforming) to public.data.
     */
    if ((NULL == theUTI || UTTypeEqual(theUTI, kUTTypeData)) && dataPhysicalSize < maximumTextDataSize && [FVTextIcon canInitWithURL:representedURL]) {
        anIcon = [[FVTextIcon allocWithZone:zone] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypePDF)) {
        anIcon = [[FVPDFIcon allocWithZone:zone] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, FVSTR("com.adobe.postscript"))) {
        anIcon = [[FVPostScriptIcon allocWithZone:zone] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, FVSTR("net.sourceforge.skim-app.pdfd"))) {
        anIcon = [[FVPDFDIcon allocWithZone:zone] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypeImage) && dataPhysicalSize < maximumImageDataSize && [FVImageIcon canInitWithUTI:theUTI]) {
        // Acorn's type conforms to public.image but can't be opened by ImageIO, so have to make an additional check for cases like this.
        anIcon = [[FVImageIcon allocWithZone:zone] initWithURL:representedURL];
    }
    else if (UTTypeEqual(theUTI, FVSTR("com.microsoft.windows-media-wmv")) && Nil != FVQLIconClass) {
        /* 
         Flip4Mac WMV plugin puts up a stupid progress bar and calls into WebCore, and it gives nothing 
         if you uncheck "Open local files immediately" in its pref pane.  Bypass it entirely if we have 
         Quick Look.  No idea if this is a QT bug or Flip4Mac bug, so I suppose I should file something...
         */
        anIcon = [[FVQLIconClass allocWithZone:zone] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypeMovie) && [FVMovieIcon canInitWithURL:representedURL]) {
        anIcon = [[FVMovieIcon allocWithZone:zone] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypeHTML) || UTTypeConformsTo(theUTI, kUTTypeWebArchive)) {
        anIcon = [[FVWebViewIcon allocWithZone:zone] initWithURL:representedURL];
    }
    else if (dataPhysicalSize < maximumTextDataSize && [FVTextIcon canInitWithUTI:(NSString *)theUTI]) {
        anIcon = [[FVTextIcon allocWithZone:zone] initWithURL:representedURL isPlainText:(UTTypeConformsTo(theUTI, kUTTypePlainText))];
    }
    else if (Nil != FVQLIconClass) {
        anIcon = [[FVQLIconClass allocWithZone:zone] initWithURL:representedURL];
    }
    
    // In case some subclass returns nil, fall back to Quick Look.  If disabled, it returns nil.
    if (nil == anIcon && Nil != FVQLIconClass)
        anIcon = [[FVQLIconClass allocWithZone:zone] initWithURL:representedURL];
    
    // In case all subclasses failed, fall back to a Finder icon.
    if (nil == anIcon)
        anIcon = [[FVFinderIcon allocWithZone:zone] initWithURL:representedURL];
    
    [(id)theUTI release];
    
    return anIcon;    
}

// we only want to encode the public superclass
- (Class)classForCoder { return FVIconClass; }

// we don't implement NSCoding, so always return a distant object (unused)
- (id)replacementObjectForPortCoder:(NSPortCoder *)encoder
{
    return [NSDistantObject proxyWithLocal:self connection:[encoder connection]];
}

// these methods are all required
- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context { [self doesNotRecognizeSelector:_cmd]; }
- (void)renderOffscreen { [self doesNotRecognizeSelector:_cmd]; }

// not all subclasses can release resources, and others may not be fully initialized
- (BOOL)canReleaseResources { return NO; }

// implement trivially so these are safe to call on the abstract class
- (void)releaseResources { /* do nothing */ }
- (BOOL)needsRenderForSize:(NSSize)size { return NO; }
- (void)recache { /* do nothing */ }

// this method is optional; some subclasses may not have a fast path
- (void)fastDrawInRect:(NSRect)dstRect ofContext:(CGContextRef)context { [self drawInRect:dstRect ofContext:context]; }

@end

@implementation FVIcon (Pages)

- (NSUInteger)pageCount { return 1; }
- (NSUInteger)currentPageIndex { return 1; }
- (void)showNextPage { /* do nothing */ }
- (void)showPreviousPage { /* do nothing */ }

@end
