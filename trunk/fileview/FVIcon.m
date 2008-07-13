//
//  FVIcon.m
//  FileViewTest
//
//  Created by Adam Maxwell on 08/31/07.
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

// FVIcon abstract class stuff
static FVIcon *defaultPlaceholderIcon = nil;
static Class FVIconClass = Nil;
static Class FVQLIconClass = Nil;
static NSURL *missingFileURL = nil;

@implementation FVIcon

+ (void)initialize
{
    FVINITIALIZE(FVIcon);
    
    FVIconClass = self;
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4) {
        NSBundle *frameworkBundle = [NSBundle bundleForClass:FVIconClass];
        [[NSBundle bundleWithPath:[frameworkBundle pathForResource:@"FileView-Leopard" ofType:@"bundle"]] load];
        FVQLIconClass = NSClassFromString(@"FVQuickLookIcon");
    }
    defaultPlaceholderIcon = (FVIcon *)NSAllocateObject(FVIconClass, 0, [self zone]);
    missingFileURL = [[NSURL alloc] initWithScheme:@"x-fileview" host:@"localhost" path:@"/missing"];
    [self _initializeCategory];
}

+ (id)allocWithZone:(NSZone *)aZone
{
    return FVIconClass == self ? defaultPlaceholderIcon : NSAllocateObject(self, 0, aZone);
}

// ensure that alloc always calls through to allocWithZone:
+ (id)alloc
{
    return [self allocWithZone:NULL];
}

- (void)dealloc
{
    if ([self class] != FVIconClass)
        [super dealloc];
}

+ (NSURL *)missingFileURL;
{
    return missingFileURL;
}

+ (id)iconWithURL:(NSURL *)representedURL;
{
    // CFURLGetFSRef won't like a nil URL
    NSParameterAssert(nil != representedURL);
    
    NSString *scheme = [representedURL scheme];
    
    // initWithURLScheme requires a scheme, so there's not much we can do without it
    if ([representedURL isEqual:missingFileURL] || nil == scheme) {
        return [[[FVFinderIcon allocWithZone:[self zone]] initWithURL:nil] autorelease];
    }
    else if (NO == [representedURL isFileURL]) {
        return [[[FVWebViewIcon allocWithZone:[self zone]] initWithURL:representedURL] autorelease];
    }
    
    OSStatus err = noErr;
    
    FSRef fileRef;
    
    // convert to an FSRef without resolving symlinks, to get the UTI of the actual URL
    const UInt8 *fsPath = (void *)[[representedURL path] fileSystemRepresentation];
    err = FSPathMakeRefWithOptions(fsPath, kFSPathMakeRefDoNotFollowLeafSymlink, &fileRef, NULL);
    
    // return missing file icon if we can't convert the path to an FSRef
    if (noErr != err)
        return [[[FVFinderIcon allocWithZone:[self zone]] initWithURL:nil] autorelease];    
    
    // kLSItemContentType returns a CFStringRef, according to the header
    CFStringRef theUTI = NULL;
    // theUTI will be NULL if this fails
    if (noErr == err)
        LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, (CFTypeRef *)&theUTI);
    
    // For a link/alias, get the target's UTI in order to determine which concrete subclass to create.  Subclasses that are file-based need to check the URL to see if it should be badged using _shouldDrawBadgeForURL, and then call _resolvedURLWithURL in order to actually load the file's content.
    
    // aliases and symlinks are kUTTypeResolvable, so the alias manager should handle either of them
    if (NULL != theUTI && UTTypeConformsTo(theUTI, kUTTypeResolvable)) {
        Boolean isFolder, wasAliased;
        err = FSResolveAliasFileWithMountFlags(&fileRef, TRUE, &isFolder, &wasAliased, kARMNoUI);
        // don't change the UTI if it couldn't be resolved; in that case, we should just show a finder icon
        if (noErr == err) {
            CFRelease(theUTI);
            theUTI = NULL;
            // theUTI will be NULL if this fails
            LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, (CFTypeRef *)&theUTI);
        }
    }
    
    
    // limit FVTextIcon to < 20 MB files; layout is really slow with large files
    const UInt64 maximumTextDataSize = 20 * 1024 * 1024;
    
    // Limit FVImageIcon to < 250 MB files; resampling is expensive (using CG to resample requires a limit of ~50 MB, but we can get away with larger sizes using vImage and tiling).
    const UInt64 maximumImageDataSize = 250 * 1024 * 1024;
    
    FSCatalogInfo catInfo;
    UInt64 dataPhysicalSize = 0;
    err = FSGetCatalogInfo(&fileRef, kFSCatInfoNodeFlags | kFSCatInfoDataSizes, &catInfo, NULL, NULL, NULL);
    if (noErr == err && (catInfo.nodeFlags & kFSNodeIsDirectoryMask) == 0)
        dataPhysicalSize = catInfo.dataPhysicalSize;
    
    FVIcon *anIcon = nil;
    
    // Problems here.  TextMate claims a lot of plain text types but doesn't declare a UTI for any of them, so I end up with a dynamic UTI, and Spotlight ignores the files.  That's broken behavior on TextMate's part, and it sucks for my purposes.
    if ((NULL == theUTI) && dataPhysicalSize < maximumTextDataSize && [FVTextIcon canInitWithURL:representedURL]) {
        anIcon = [[FVTextIcon allocWithZone:[self zone]] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypePDF)) {
        anIcon = [[FVPDFIcon allocWithZone:[self zone]] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, CFSTR("com.adobe.postscript"))) {
        anIcon = [[FVPostScriptIcon allocWithZone:[self zone]] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, CFSTR("net.sourceforge.skim-app.pdfd"))) {
        anIcon = [[FVPDFDIcon allocWithZone:[self zone]] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypeImage) && dataPhysicalSize < maximumImageDataSize) {
        anIcon = [[FVImageIcon allocWithZone:[self zone]] initWithURL:representedURL];
    }
    else if (UTTypeEqual(theUTI, CFSTR("com.microsoft.windows-media-wmv")) && Nil != FVQLIconClass) {
        // Flip4Mac WMV plugin puts up a stupid progress bar and calls into WebCore, and it gives nothing if you uncheck "Open local files immediately" in its pref pane.  Bypass it entirely if we have Quick Look.  No idea if this is a QT bug or Flip4Mac bug, so I suppose I should file something...
        anIcon = [[FVQLIconClass allocWithZone:[self zone]] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypeMovie) && [FVMovieIcon canInitWithURL:representedURL]) {
        anIcon = [[FVMovieIcon allocWithZone:[self zone]] initWithURL:representedURL];
    }
    else if (UTTypeConformsTo(theUTI, kUTTypeHTML) || UTTypeConformsTo(theUTI, kUTTypeWebArchive)) {
        anIcon = [[FVWebViewIcon allocWithZone:[self zone]] initWithURL:representedURL];
    }
    else if (dataPhysicalSize < maximumTextDataSize && [FVTextIcon canInitWithUTI:(NSString *)theUTI]) {
        anIcon = [[FVTextIcon allocWithZone:[self zone]] initWithURL:representedURL isPlainText:(UTTypeConformsTo(theUTI, kUTTypePlainText))];
    }
    else if (Nil != FVQLIconClass) {
        anIcon = [[FVQLIconClass allocWithZone:[self zone]] initWithURL:representedURL];
    }
    
    // In case some subclass returns nil, fall back to Quick Look.  If disabled, it returns nil.
    if (nil == anIcon && Nil != FVQLIconClass)
        anIcon = [[FVQLIconClass allocWithZone:[self zone]] initWithURL:representedURL];
    
    // In case all subclasses failed, fall back to a Finder icon.
    if (nil == anIcon)
        anIcon = [[FVFinderIcon allocWithZone:[self zone]] initWithURL:representedURL];
    
    [(id)theUTI release];
    
    return [anIcon autorelease];    
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
