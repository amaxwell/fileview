//
//  FVCGImageCache.m
//  FileView
//
//  Created by Adam Maxwell on 10/21/07.
/*
 This software is Copyright (c) 2007-2011
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

#import "FVCGImageCache.h"
#import "FVUtilities.h"
#import "FVCGImageDescription.h"
#import "FVCacheFile.h"
#import "FVAllocator.h"

#import <libkern/OSAtomic.h>
#import <pthread.h>

static CGImageRef FVCreateCGImageWithData(NSData *data);
static CFDataRef FVCreateDataWithCGImage(CGImageRef image);

@implementation FVCGImageCache

static FVCGImageCache *_bigImageCache = nil;
static FVCGImageCache *_smallImageCache = nil;

// sets name for recording/logging statistics
- (void)setName:(NSString *)name
{
    [_cacheFile setName:name];
}

+ (void)initialize
{
    FVINITIALIZE(FVCGImageCache);

    _bigImageCache = [FVCGImageCache new];
    [_bigImageCache setName:@"full size images"];
    _smallImageCache = [FVCGImageCache new];
    [_smallImageCache setName:@"thumbnail images"];
}

- (id)init
{
    self = [super init];
    if (self) {
        _cacheFile = [FVCacheFile new];
        
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(handleAppTerminate:) 
                                                     name:NSApplicationWillTerminateNotification 
                                                   object:nil];   
    }
    return self;
}

- (void)handleAppTerminate:(NSNotification *)notification
{    
    // avoid writing to a closed file
    FVCacheFile *cacheFile = _cacheFile;
    _cacheFile = nil;
    [cacheFile closeFile];   
    [cacheFile release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dealloc
{
    NSLog(@"*** error *** attempt to deallocate FVCGImageCache");
    if (0) [super dealloc];
}

- (CGImageRef)newImageForKey:(id)aKey;
{
    NSData *data = [_cacheFile copyDataForKey:aKey];
    CGImageRef image = FVCreateCGImageWithData(data);
    [data release];
    return image;
}

- (void)cacheImage:(CGImageRef)image forKey:(id)aKey;
{
    NSData *data = (NSData *)FVCreateDataWithCGImage(image);
    [_cacheFile saveData:data forKey:aKey];
    [data release];
}

- (void)invalidateCachedImageForKey:(id)aKey
{
    [_cacheFile invalidateDataForKey:aKey];
}

#pragma mark Class methods

#pragma clang diagnostic push
// Proper warning is unknown by Xcode 3.2.  Starting to think clang sucks.
// #pragma clang diagnostic ignored "-Wincompatible-pointer-types"
#pragma clang diagnostic ignored "-Wall"
+ (id <NSObject, NSCopying>)newKeyForURL:(NSURL *)aURL;
{
    return (id <NSObject, NSCopying>)[FVCacheFile newKeyForURL:aURL];
}
#pragma clang diagnostic pop

+ (CGImageRef)newThumbnailForKey:(id)aKey;
{
    return [_smallImageCache newImageForKey:aKey];
}

+ (void)cacheThumbnail:(CGImageRef)image forKey:(id)aKey;
{
    [_smallImageCache cacheImage:image forKey:aKey];
}

+ (CGImageRef)newImageForKey:(id)aKey;
{
    return [_bigImageCache newImageForKey:aKey];
}

+ (void)cacheImage:(CGImageRef)image forKey:(id)aKey;
{
    [_bigImageCache cacheImage:image forKey:aKey];
}

+ (void)invalidateCachesForKey:(id)aKey;
{
    [_bigImageCache invalidateCachedImageForKey:aKey];
    [_smallImageCache invalidateCachedImageForKey:aKey];
}

@end

#pragma mark -

#ifdef USE_IMAGEIO
#undef USE_IMAGEIO
#endif

#define USE_IMAGEIO 0

// PNG and JPEG2000 are too slow when drawing, and TIFF is too big (although we could compress it)
#define IMAGEIO_TYPE kUTTypeTIFF

static CGImageRef FVCreateCGImageWithData(NSData *data)
{
    CGImageRef toReturn = NULL;
    
    if (0 == [data length])
        return toReturn; 

#if USE_IMAGEIO
    static NSDictionary *imageProperties = nil;
    if (nil == imageProperties)
        imageProperties = [[NSDictionary alloc] initWithObjectsAndKeys:[NSNumber numberWithInt:1.0], (id)kCGImageDestinationLossyCompressionQuality, nil];
    
    CGImageSourceRef imsrc = CGImageSourceCreateWithData((CFDataRef)data, (CFDictionaryRef)imageProperties);
    if (imsrc && CGImageSourceGetCount(imsrc))
        toReturn = CGImageSourceCreateImageAtIndex(imsrc, 0, NULL);
    if (imsrc) CFRelease(imsrc);
#else
    NSUnarchiver *unarchiver = [[NSUnarchiver allocWithZone:FVDefaultZone()] initForReadingWithData:data];
    // only retained by unarchiver
    FVCGImageDescription *imageDescription = [unarchiver decodeObject];
    toReturn = [imageDescription newImage];
    [unarchiver release];
#endif
    return toReturn;
}

static CFDataRef FVCreateDataWithCGImage(CGImageRef image)
{
#if USE_IMAGEIO
    CFMutableDataRef data = CFDataCreateMutable(CFAllocatorGetDefault(), 0);
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(data, IMAGEIO_TYPE, 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    CGImageDestinationFinalize(dest);
    if (dest) CFRelease(dest);
#else
    CFDataRef data = nil;
    FVCGImageDescription *imageDescription = [[FVCGImageDescription allocWithZone:FVDefaultZone()] initWithImage:image];
    
    // do not call setLength:, even before writing the archive!
    size_t approximateLength = CGImageGetBytesPerRow(image) * CGImageGetHeight(image) + 20 * sizeof(size_t);
    NSMutableData *mdata = [[NSMutableData allocWithZone:FVDefaultZone()] initWithCapacity:approximateLength];
    
    NSArchiver *archiver = [[NSArchiver allocWithZone:FVDefaultZone()] initForWritingWithMutableData:(NSMutableData *)mdata];
    [archiver encodeObject:imageDescription];
    [imageDescription release];
    [archiver release];
    
    data = (CFDataRef)mdata;
#endif    
    return data;
}
