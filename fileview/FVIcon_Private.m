//
//  FVIcon_Private.m
//  FileView
//
//  Created by Adam Maxwell on 2/26/08.
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

#import "FVIcon_Private.h"
#import "FVPlaceholderImage.h"
#import "FVAliasBadge.h"

#import <objc/runtime.h>

@interface _FVQueuedKeys : NSObject
{
    NSCountedSet   *_keys;
    pthread_mutex_t _keyLock;
    pthread_cond_t  _keyCondition;
}
- (void)startRenderingForKey:(id)aKey;
- (void)stopRenderingForKey:(id)aKey;
@end


@implementation FVIcon (Private)

// key = Class, object = _FVQueuedKeys
static CFDictionaryRef _queuedKeysByClass = NULL;

// Walk the runtime's class list and get all subclasses of FVIcon, then add an _FVQueuedKeys instance to _queuedKeysByClass for each subclass.  This avoids adding them lazily, which would require locking around the dictionary.
+ (void)_processIconSubclasses
{
    int numClasses = objc_getClassList(NULL, 0);
    
    CFMutableDictionaryRef queuedKeysByClass;
    queuedKeysByClass = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    
    if (numClasses > 0) {
        Class *classes = NSZoneCalloc([self zone], numClasses, sizeof(Class));
        numClasses = objc_getClassList(classes, numClasses);
        
        Class FVIconClass = [FVIcon self];
        
        for (int classIndex = 0; classIndex < numClasses; classIndex++) {
            Class aClass = classes[classIndex];
            Class superClass = aClass->super_class;
            
            while (NULL != superClass) {

                if (superClass == FVIconClass) {
                    _FVQueuedKeys *qkeys = [_FVQueuedKeys new];
                    CFDictionaryAddValue(queuedKeysByClass, aClass, qkeys);
                    [qkeys release];
                    break;
                }
                superClass = superClass->super_class;
            }
        }
        NSZoneFree([self zone], classes);
    }
    _queuedKeysByClass = CFDictionaryCreateCopy(CFGetAllocator(queuedKeysByClass), queuedKeysByClass);
    CFRelease(queuedKeysByClass);
}

+ (void)_initializeCategory;
{
    static bool didInit = false;
    NSAssert(false == didInit, @"attempt to initialize category again");
    didInit = true;    
    
    [self _processIconSubclasses];
}

+ (void)_startRenderingForKey:(id)aKey;
{
    _FVQueuedKeys *qkeys = [(NSDictionary *)_queuedKeysByClass objectForKey:self];
    NSParameterAssert(nil != qkeys);
    [qkeys startRenderingForKey:aKey];
}

+ (void)_stopRenderingForKey:(id)aKey;
{
    _FVQueuedKeys *qkeys = [(NSDictionary *)_queuedKeysByClass objectForKey:self];
    NSParameterAssert(nil != qkeys);
    [qkeys stopRenderingForKey:aKey];   
}

+ (BOOL)_shouldDrawBadgeForURL:(NSURL *)aURL copyTargetURL:(NSURL **)linkTarget;
{
    NSParameterAssert([aURL isFileURL]);
    NSParameterAssert(NULL != linkTarget);
    
    uint8_t stackBuf[PATH_MAX];
    uint8_t *fsPath = stackBuf;
    CFStringRef absolutePath = CFURLCopyFileSystemPath((CFURLRef)aURL, kCFURLPOSIXPathStyle);
    NSUInteger maxLen = CFStringGetMaximumSizeOfFileSystemRepresentation(absolutePath);
    if (maxLen > sizeof(stackBuf))
        fsPath = NSZoneMalloc([self zone], maxLen);
    CFStringGetFileSystemRepresentation(absolutePath, (char *)fsPath, maxLen);
        
    OSStatus err;
    FSRef fileRef;
    err = FSPathMakeRefWithOptions(fsPath, kFSPathMakeRefDoNotFollowLeafSymlink, &fileRef, NULL);   
    if (fsPath != stackBuf)
        NSZoneFree([self zone], fsPath);
    if (absolutePath) CFRelease(absolutePath);
    
    // kLSItemContentType returns a CFStringRef, according to the header
    CFStringRef theUTI = NULL;
    if (noErr == err)
        err = LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, (CFTypeRef *)&theUTI);
    
    BOOL drawBadge = (NULL != theUTI && UTTypeConformsTo(theUTI, kUTTypeResolvable));
    
    if (theUTI) CFRelease(theUTI);
    
    if (drawBadge) {
        // replace the URL with the resolved URL in case it was an alias
        Boolean isFolder, wasAliased;
        err = FSResolveAliasFileWithMountFlags(&fileRef, TRUE, &isFolder, &wasAliased, kARMNoUI);
        
        // wasAliased is false for symlinks, but use the resolved alias anyway
        if (noErr == err)
            *linkTarget = (id)CFURLCreateFromFSRef(NULL, &fileRef);
        else
            *linkTarget = [aURL retain];
    }
    else {
        *linkTarget = [aURL retain];
    }
    
    return drawBadge;
}

- (id)initWithURL:(NSURL *)aURL { [self doesNotRecognizeSelector:_cmd]; return nil; }
- (BOOL)tryLock { [self doesNotRecognizeSelector:_cmd]; return NO; }
- (void)lock { [self doesNotRecognizeSelector:_cmd]; }
- (void)unlock { [self doesNotRecognizeSelector:_cmd]; }

- (NSSize)size { [self doesNotRecognizeSelector:_cmd]; return NSZeroSize; }

- (void)_badgeIconInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{
    CGContextDrawLayerInRect(context, *(CGRect *)&dstRect, [FVAliasBadge aliasBadgeWithSize:dstRect.size]);
}

// handles centering and aspect ratio, since most of our icons have weird sizes, but they'll be drawn in a square box
- (CGRect)_drawingRectWithRect:(NSRect)iconRect;
{
    // lockless classes return NO specifically to avoid hitting this assertion
    NSAssert1([self tryLock] == NO, @"%@ failed to acquire lock before calling -size", [self class]);
    NSSize s = [self size];
    
    NSParameterAssert(s.width > 0);
    NSParameterAssert(s.height > 0);
    
    // for release builds with assertions disabled, use a 1:1 aspect
    if (s.width <= 0 || s.height <= 0) s = (NSSize) { 1, 1 };
    
    CGFloat ratio = MIN(NSWidth(iconRect) / s.width, NSHeight(iconRect) / s.height);
    CGRect dstRect = *(CGRect *)&iconRect;
    dstRect.size.width = ratio * s.width;
    dstRect.size.height = ratio * s.height;
    
    CGFloat dx = (iconRect.size.width - dstRect.size.width) / 2;
    CGFloat dy = (iconRect.size.height - dstRect.size.height) / 2;
    dstRect.origin.x += dx;
    dstRect.origin.y += dy;
    
    // The view uses centerScanRect:, which should be correct for resolution independence.  It's just annoying to return lots of decimals here.
    return CGRectIntegral(dstRect);
}

- (void)_drawPlaceholderInRect:(NSRect)dstRect ofContext:(CGContextRef)context
{
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    CGContextDrawLayerInRect(context, *(CGRect *)&dstRect, [FVPlaceholderImage placeholderWithSize:dstRect.size]);
    CGContextRestoreGState(context);
}

@end

#pragma mark Image sizing

bool FVShouldDrawFullImageWithThumbnailSize(const NSSize desiredSize, const NSSize thumbnailSize)
{
    return (desiredSize.height > 1.2 * thumbnailSize.height || desiredSize.width > 1.2 * thumbnailSize.width);
}

// these are compromises based on memory constraints and readability at high magnification
const size_t FVMaxThumbnailDimension = 200;
const size_t FVMaxImageDimension     = 512;

/*
 Global variables are evil, but NSPrintInfo and CUPS are more evil.  Since NSPrintInfo must be used from the main thread and it can block for a long time in +initialize if CUPS is jacked up, we'll just assume some values since the main need is to have page-like proportions.  The default for CGPDFContextCreate is 612x792 pts, and NSPrintInfo on my system has 1" left and 1.25" top margins.
 */
const NSSize FVDefaultPaperSize = { 612, 792 };
const CGFloat FVSideMargin      = 72.0;
const CGFloat FVTopMargin       = 90.0;

// used to constrain thumbnail size for huge pages
bool FVIconLimitThumbnailSize(NSSize *size)
{
    CGFloat dimension = MIN(size->width, size->height);
    if (dimension <= FVMaxThumbnailDimension)
        return false;
    
    while (dimension > FVMaxThumbnailDimension) {
        size->width *= 0.9;
        size->height *= 0.9;
        dimension = MIN(size->width, size->height);
    }
    return true;
}

bool FVIconLimitFullImageSize(NSSize *size)
{
    CGFloat dimension = MIN(size->width, size->height);
    if (dimension <= FVMaxImageDimension)
        return false;
    
    while (dimension > FVMaxImageDimension) {
        size->width *= 0.9;
        size->height *= 0.9;
        dimension = MIN(size->width, size->height);
    }
    return true;
}

CGImageRef FVCreateResampledThumbnail(CGImageRef image)
{
    NSSize size = FVCGImageSize(image);
    return (FVIconLimitThumbnailSize(&size) || FVImageIsIncompatible(image)) ? FVCreateResampledImageOfSize(image, size) : CGImageRetain(image);
}

CGImageRef FVCreateResampledFullImage(CGImageRef image)
{
    NSSize size = FVCGImageSize(image);
    return (FVIconLimitFullImageSize(&size) || FVImageIsIncompatible(image)) ? FVCreateResampledImageOfSize(image, size) : CGImageRetain(image);    
}

#pragma mark -

@implementation _FVQueuedKeys

- (id)init
{
    self = [super init];
    if (self) {
        _keys = [NSCountedSet new];
        pthread_mutex_init(&_keyLock, NULL);
        pthread_cond_init(&_keyCondition, NULL);
    }
    return self;
}

- (void)startRenderingForKey:(id)aKey
{
    int ret = 0;
    pthread_mutex_lock(&_keyLock);
    // block this thread while the key we need is being rendered
    while ([_keys countForObject:aKey] > 0 && 0 == ret) {
        ret = pthread_cond_wait(&_keyCondition, &_keyLock);
    }
    [_keys addObject:aKey];
    pthread_mutex_unlock(&_keyLock);
}

- (void)stopRenderingForKey:(id)aKey
{
    pthread_mutex_lock(&_keyLock);
    // there should be only a single instance rendering at any given time
    FVAPIParameterAssert([_keys countForObject:aKey] == 1);
    [_keys removeObject:aKey];
    pthread_mutex_unlock(&_keyLock);
    // wake up any threads waiting in startRenderingForKey:
    pthread_cond_broadcast(&_keyCondition);
}

@end

