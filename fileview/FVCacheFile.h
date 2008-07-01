//
//  FVCacheFile.h
//  FileView
//
//  Created by Adam Maxwell on 3/23/08.
/*
 This software is Copyright (c) 2008
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

#ifdef __cplusplus
#import <queue>
#endif

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

// Returns an object suitable for use as a key (needs to be safe for use as an NSDictionary key).  Do not rely on this being the same class between releases or even between calls to this method.
+ (id)newKeyForURL:(NSURL *)aURL;

// Write data to disk and use the specified key to retrieve it later; key may be any object that conforms to NSCopying, and it must implement -hash and -isEqual: correctly.  The copyDataForKey: method will return nil if the cache had no data for the specified key.
- (void)saveData:(NSData *)data forKey:(id)aKey;
- (NSData *)copyDataForKey:(id)aKey;

- (void)invalidateDataForKey:(id)aKey;

// Name is currently only used when recording statistics to the log file.
- (void)setName:(NSString *)aName;

// Owner is responsible for calling this before deallocating the file
- (void)closeFile;

@end
