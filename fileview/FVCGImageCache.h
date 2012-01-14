//
//  FVCGImageCache.h
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

#import <Cocoa/Cocoa.h>

@class FVCacheFile;

/** @brief On-disk cache of images.
  
 \warning Only 8-bit RGB or grayscale images are supported (with optional alpha).  Call FVBitmapContext::FVImageIsIncompatible to determine if an image needs to be redrawn.

 Conceptually, this class provides a dictionary of images.  It's presently implemented using a compressed file on disk for storage, but may do other clever things in future.  Two caches are provided: one for large images, and one for small images.  Use the class methods to store CGImages and to get an efficient key for those images; you cannot instantiate an FVCGImageCache and operate directly.
 
 Note that the "large" vs. "small" distinction is purely notional.  Clients are free to decide which they will use, as the underlying storage is identical in either case.
 */
@interface FVCGImageCache : NSObject
{
@private;
    FVCacheFile *_cacheFile;
}

/** @brief Key for caching.
 
 Use this to get a key for caching images to disk, or anything else that requires a copyable key (e.g., NSDictionary).  If your object is represented by a file: URL, the key will attempt to be robust against file renaming.  Additionally, file: URL keys may use a more efficient hash/isEqual: implementation than NSURL itself, which is a very poor dictionary key.
 @param aURL A URL representation of your object.
 @return A new key instance. */
+ (id <NSObject, NSCopying>)newKeyForURL:(NSURL *)aURL;

/** Retrieve a thumbnail.
 
 @param aKey The key representing the object to retrieve.
 @return A new CGImage instance. */
+ (CGImageRef)newThumbnailForKey:(id)aKey;

/** Store a thumbnail.

 @param image The CGImage to store.
 @param aKey The key representing the image, typically from FVCGImageCache::newKeyForURL:. */
+ (void)cacheThumbnail:(CGImageRef)image forKey:(id)aKey;

/** Retrieve an image.
 
 @param aKey The key representing the object to retrieve.
 @return A new CGImage instance. */
+ (CGImageRef)newImageForKey:(id)aKey;

/** Store an image.
 
 @param image The CGImage to store.
 @param aKey The key representing the image, typically from FVCGImageCache::newKeyForURL:. */
+ (void)cacheImage:(CGImageRef)image forKey:(id)aKey;

/** @brief Remove images.
 
 When an image has been changed and you want to continue using the same key, this will remove previously stored images for that key.
 @param aKey The key representing the image, typically from FVCGImageCache::newKeyForURL:. */
+ (void)invalidateCachesForKey:(id)aKey;

@end
