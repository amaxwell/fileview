//
//  FVCacheFile.h
//  FileView
//
//  Created by Adam Maxwell on 3/23/08.
/*
 This software is Copyright (c) 2008-2010
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

/** @internal @brief Binary cache file.
 
 Conceptually, FVCacheFile provides a dictionary-like interface to a data file wherein NSData objects are represented by a key, and only one object exists for a given key.  FVCacheFile instances are thread-safe for multiple readers and writers, although write operations are serialized.  Reads are performed using mmap(2), and data is compressed using zlib when writing and decompressed while reading.  Various preferences are available for gathering usage statistics to see object space usage per key.
 
 The file is written to a temporary location, created using mkstemp(3).  If this location is not suitable for memory-mapping files, an exception will be raised.  The file is unlinked immediately after creation, so it will vanish if the app crashes or is otherwise terminated.  Typically, the owner of the FVCacheFile should register for NSApplicationWillTerminateNotification and call closeFile at that time.
 
 @warning FVCacheFile is not designed for persistent storage across app launches or architectures.  No validation or consistency checks are performed.  */

@interface FVCacheFile : NSObject {
@private;
    NSString            *_cacheName;
    NSString            *_path;
    int                  _fileDescriptor;
    uint8_t             *_deflateBuffer;
    NSLock              *_writeLock;
    NSMutableDictionary *_offsetTable;
    NSMutableDictionary *_eventTable;
}

/** Cache key.
 
 Returns an object suitable for use as a key (needs to be safe for use as an NSDictionary key).  This assumes that each object is representable by an NSURL.  Note that file: URLs are handled specially for improved performance and for tracking files after they are moved.
 
 @warning Do not rely on this being the same class between releases or even between calls to this method.
 @param aURL An NSURL representing the object to be cached.
 @return A newly created key. */
+ (id <NSObject, NSCopying>)newKeyForURL:(NSURL *)aURL;

/** Saving data.
 
 Write data to disk and use the specified key to retrieve it later.
 
 @param data The data object to store.
 @param aKey Key may be any object that conforms to &lt;NSCopying&gt;, and it must implement -hash and -isEqual: correctly.  */ 
- (void)saveData:(NSData *)data forKey:(id <NSObject, NSCopying>)aKey;

/** Reading data.
 
 @param aKey The key to read.
 @return Previously stored data or nil if the cache had no value for the specified key. */
- (NSData *)copyDataForKey:(id)aKey;

/** Invalidate cached data.
 
 Marks the data pointed to as invalid, but does not remove it from the on-disk cache.  It will not be accessible after this call, and the key may be safely reused for another data instance.
 @param aKey The key to invalidate */
- (void)invalidateDataForKey:(id)aKey;

/** Cache name.
 
 Name is currently only used when recording statistics to the log file.
 @param aName The name, which may be any string. */
- (void)setName:(NSString *)aName;

/** Close the file.
 
 The owner of the FVCacheFile is responsible for calling this before deallocating the file. */
- (void)closeFile;

@end
