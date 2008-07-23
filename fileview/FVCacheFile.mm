//
//  FVCacheFile.mm
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

#import "FVCacheFile.h"
#import "FVUtilities.h"
#import "FVObject.h"
#import <libkern/OSAtomic.h>
#import <string>
#import <sys/stat.h>
#import <asl.h>
#import <zlib.h>
#import <sys/mman.h>

@interface _FVCacheKey : FVObject <NSCopying>
{
@public;
    dev_t       _device;
    ino_t       _inode;
    NSURL      *_URL;
    NSUInteger  _hash;
}
+ (id)newWithURL:(NSURL *)aURL;
@end

@interface _FVCacheLocation : NSObject
{
@public;
    off_t      _offset;              // starting offset in the file
    NSUInteger _compressedLength;    // length of compressed data to read with zlib
    NSUInteger _decompressedLength;  // final length of decompressed data
    NSUInteger _padLength;           // zero padding to align this segment to page boundary size
}
// full length of this location is _compressedLength + _padLength bytes
@end

@interface _FVCacheEventRecord : NSObject
{
@public
    double      _kbytes;
    NSUInteger  _count;
    CFStringRef _identifier;
}
@end

@implementation FVCacheFile

// http://www.zlib.net/zlib_how.html says that 128K or 256K is the most efficient size

#define ZLIB_BUFFER_SIZE 524288

static NSInteger FVCacheLogLevel = 0;

+ (void)initialize
{
    FVINITIALIZE(FVCacheFile);
    
    // Pass in args on command line: -FVCacheLogLevel 0
    // 0 - disabled
    // 1 - only print final stats
    // 2 - print URL each as it's added
    FVCacheLogLevel = [[NSUserDefaults standardUserDefaults] integerForKey:@"FVCacheLogLevel"];
    
    // workaround for NSRoundUpToMultipleOfPageSize: http://www.cocoabuilder.com/archive/message/cocoa/2008/3/5/200500
    (void)NSPageSize();    
}

+ (id)newKeyForURL:(NSURL *)aURL;
{
    return [_FVCacheKey newWithURL:aURL];
}

- (id)init
{
    self = [super init];
    if (self) {
        
        // docs say this returns nil in case of failure...so we'll check for it just in case
        NSString *tempDir = NSTemporaryDirectory();
        if (nil == tempDir)
            tempDir = @"/tmp";
        
        const char *tmpPath;
        tmpPath = [[tempDir stringByAppendingPathComponent:@"FileViewCache.XXXXXX"] fileSystemRepresentation];
        
        // mkstemp needs a writable string
        char *tempName = strdup(tmpPath);
        
        // use mkstemp to avoid race conditions; we can't share the cache for writing between processes anyway
        if ((mkstemp(tempName)) == -1) {
            // if this call fails the OS will probably crap out soon, so there's no point in dying gracefully
            std::string errMsg = std::string("mkstemp failed \"") + tempName + "\"";
            perror(errMsg.c_str());
            exit(1);
        }
        
        // all writes are synchronous since they need to occur in a single block at the end of the file
        _fileDescriptor = open(tempName, O_RDWR);

        _path = (NSString *)CFStringCreateWithFileSystemRepresentation(NULL, tempName);
        FVAPIAssert1(FVCanMapFileAtURL([NSURL fileURLWithPath:_path]), @"%@ is not safe for mmap()", _path);

        // Unlink the file immediately so we don't leave turds when the program crashes.
        unlink(tempName);
        free(tempName);
        tempName = NULL;

        if (FVCacheLogLevel > 0)
            _eventTable = [NSMutableDictionary new];     

        _writeLock = [NSLock new];
        _offsetTable = [NSMutableDictionary new];
        
        _deflateBuffer = new uint8_t[ZLIB_BUFFER_SIZE];
                
        if (-1 == _fileDescriptor) {
            NSLog(@"*** ERROR *** unable to open file %@", _path);
            [self release];
            self = nil;
        }
        
    }
    return self;
}

- (void)dealloc
{
    // owner is responsible for calling -closeFile at the appropriate time, and _readers is deleted in closeFile
    if (-1 != _fileDescriptor)
        NSLog(@"*** WARNING *** failed to close %@ before deallocating; leaking file descriptor", self);
    [_cacheName release];
    [_path release];
    delete [] _deflateBuffer;
    [_writeLock release];
    [_offsetTable release];
    [_eventTable release];
    [super dealloc];
}

- (void)_writeLogEventsIfNeeded
{
    NSAssert(NO == [_writeLock tryLock], @"failed to acquire write lock before writing to syslog");
    if (FVCacheLogLevel > 0) {
        
        const char *path = [_path fileSystemRepresentation];
        
        NSParameterAssert(-1 != _fileDescriptor);
        
        // print the file size, just because I'm curious about it (before closing the file, though, since we unlinked it!)
        struct stat sb;
        if (0 == fstat(_fileDescriptor, &sb)) {
            off_t fsize = sb.st_size;
            double mbSize = double(fsize) / 1024 / 1024;
            
            aslclient client = asl_open("FileViewCache", NULL, ASL_OPT_NO_DELAY);
            aslmsg m = asl_new(ASL_TYPE_MSG);
            asl_set(m, ASL_KEY_SENDER, "FileViewCache");
            const char *cacheName = [_cacheName UTF8String];
            asl_log(client, m, ASL_LEVEL_ERR, "%s: removing %s with cache size = %.2f MB\n", cacheName, path, mbSize);
            asl_log(client, m, ASL_LEVEL_ERR, "%s: final cache content (compressed): %s\n", cacheName, [[_eventTable description] UTF8String]);
            asl_free(m);
            asl_close(client);        
        }
        else {
            std::string errMsg = std::string("stat failed \"") + path + "\"";
            perror(errMsg.c_str());
        }
    }    
}

- (void)closeFile
{
    [_writeLock lock];
    
    FVAPIAssert1(-1 != _fileDescriptor, @"Attempt to close a file %@ that has already been closed", self);
    [self _writeLogEventsIfNeeded];
    
    // truncate the file to avoid any zero-fill delay on close()
    ftruncate(_fileDescriptor, 0);
    
    if (-1 != _fileDescriptor) {
        close(_fileDescriptor);
        _fileDescriptor = -1;
    }
    
    [_writeLock unlock];
}

- (void)setName:(NSString *)name
{
    [_cacheName autorelease];
    _cacheName = [name copy];
}

- (void)_recordCacheEventWithKey:(_FVCacheKey *)key size:(double)kbytes
{
    NSAssert(NO == [_writeLock tryLock], @"failed to acquire write lock before calling _recordCacheEventWithKey:size:");
    
    // !!! Early return; we don't want to dereference members that don't exist, since any object can be used as key.
    if ([key isKindOfClass:[_FVCacheKey class]] == NO)
        return;
    
    CFURLRef theURL = (CFURLRef)key->_URL;
    CFStringRef scheme = CFURLCopyScheme(theURL);
    CFStringRef identifier = NULL;
    if (scheme && CFStringCompare(scheme, CFSTR("file"), 0) == kCFCompareEqualTo) {
        
        FSRef fileRef;
        if (CFURLGetFSRef(theURL, &fileRef)) {
            CFStringRef theUTI;
            LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, (CFTypeRef *)&theUTI);
            if (theUTI) identifier = theUTI;
        }
    }
    else if (scheme) {
        identifier = (CFStringRef)CFRetain(scheme);
    }
    else {
        identifier = (CFStringRef)CFRetain(CFSTR("anonymous"));
    }
    
    _FVCacheEventRecord *rec = [_eventTable objectForKey:(id)identifier];
    if (nil != rec) {
        rec->_kbytes += kbytes;
        rec->_count += 1;
    }
    else {
        rec = [_FVCacheEventRecord new];
        rec->_kbytes = kbytes;
        rec->_count = 1;
        rec->_identifier = (CFStringRef)CFRetain(identifier);
        [_eventTable setObject:rec forKey:(id)identifier];
        [rec release];
    }
    
    if (identifier) CFRelease(identifier);
    if (scheme) CFRelease(scheme);
    
    if (FVCacheLogLevel > 1) {
        aslclient client = asl_open("FileViewCache", NULL, ASL_OPT_NO_DELAY);
        aslmsg m = asl_new(ASL_TYPE_MSG);
        asl_set(m, ASL_KEY_SENDER, "FileViewCache");
        asl_log(client, m, ASL_LEVEL_ERR, "caching image for %s, size = %.2f kBytes\n", [[key description] UTF8String], kbytes);
        asl_free(m);
        asl_close(client);
    }
}

- (void)saveData:(NSData *)data forKey:(id)aKey;
{
    // hold the lock for the entire method, since we don't want anyone else messing with the file descriptor or _deflateBuffer
    [_writeLock lock];
    
    FVAPIAssert1(-1 != _fileDescriptor, @"Attempt to write to a file %@ that has already been closed", self);

    if ([_offsetTable objectForKey:aKey] == nil) {
        
        _FVCacheLocation *location = [_FVCacheLocation new];
        location->_decompressedLength = [data length];

        // set the pointer to the end of the file, since we have no idea where it is now
        off_t currentEnd = lseek(_fileDescriptor, 0, SEEK_END);
            
        if (-1 != currentEnd) {
                
            location->_offset = currentEnd;
            location->_compressedLength = 0;
            
            z_stream strm;
            
            strm.zalloc = (void *(*)(void *, uInt, uInt))NSZoneCalloc;
            strm.zfree = (void (*)(void *, void *))NSZoneFree;
            strm.opaque = [self zone];
            strm.total_out = 0;
            strm.next_in = (Bytef *)[data bytes];
            strm.avail_in = location->_decompressedLength;
            
            int flush, status = deflateInit2(&strm, Z_BEST_SPEED, Z_DEFLATED, 15, 9, Z_HUFFMAN_ONLY);
            
            ssize_t writeLength;
            
            do {
                
                flush = strm.total_in == location->_decompressedLength ? Z_FINISH : Z_NO_FLUSH;
            
                do {
                    
                    strm.next_out = _deflateBuffer;
                    strm.avail_out = ZLIB_BUFFER_SIZE;
                    
                    status = deflate(&strm, flush);
                    NSParameterAssert(Z_STREAM_ERROR != status); // indicates state was clobbered
                    
                    writeLength = ZLIB_BUFFER_SIZE - strm.avail_out;
                    if (write(_fileDescriptor, _deflateBuffer, writeLength) != writeLength)
                        FVLog(@"failed to write all data (%d bytes)", writeLength);
                    
                    location->_compressedLength += writeLength;
                    
                } while (strm.avail_out == 0);
                
            } while (Z_FINISH != flush);

            (void)deflateEnd(&strm);
                        
            // extend the file so we fall on a page boundary
            location->_padLength = NSRoundUpToMultipleOfPageSize(location->_compressedLength) - location->_compressedLength;
            if (0 != ftruncate(_fileDescriptor, currentEnd + NSRoundUpToMultipleOfPageSize(location->_compressedLength)))
                perror([[NSString stringWithFormat:@"failed to zero pad data in file %@", self] UTF8String]);
            
            if (FVCacheLogLevel > 0)
                [self _recordCacheEventWithKey:aKey size:double([data length]) / 1024];
            
            // set this only after writing, so the reader thread doesn't get it too early
            [_offsetTable setObject:location forKey:aKey];

        }        
        else {
            perror("failed to write data");
        }
        [location release];
    }
    [_writeLock unlock];
}

- (NSData *)copyDataForKey:(id)aKey;
{
    FVAPIAssert1(-1 != _fileDescriptor, @"Attempt to read from a file %@ that has already been closed", self);
    
    NSData *data = nil;
    
    // retain to avoid losing this in case -invalidateDataForKey: is called
    _FVCacheLocation *location = [[_offsetTable objectForKey:aKey] retain];

    if (location) {
                    
        // malloc the entire block immediately since we have a fixed length, insted of using NSMutableData to manage a buffer
        char *bytes = (char *)NSZoneCalloc([aKey zone], location->_decompressedLength, sizeof(char));
        
        if (NULL != bytes) {
            
            ssize_t bytesRemaining = location->_compressedLength;
            // man page says mmap will fail if offset isn't a multiple of page size
            NSParameterAssert(location->_offset == NSRoundUpToMultipleOfPageSize(location->_offset));
            
            int status;
            
            z_stream strm;
            strm.avail_in = ZLIB_BUFFER_SIZE;
            strm.total_out = 0;
            strm.zalloc = (void *(*)(void *, uInt, uInt))NSZoneCalloc;
            strm.zfree = (void (*)(void *, void *))NSZoneFree;
            strm.opaque = [self zone];
            
            status = inflateInit(&strm);
            
            void *mapregion = NULL;
            const size_t mapLength = location->_compressedLength + location->_padLength;
            if ((mapregion = mmap(0, mapLength, PROT_READ, MAP_SHARED, _fileDescriptor, location->_offset)) == (void *)-1) {
                perror("mmap failed");
                return nil;
            }
            
            do {
                                    
                strm.next_in = (Bytef *)mapregion;
                strm.avail_in = location->_compressedLength;
                strm.next_out = (Bytef *)bytes + strm.total_out;
                strm.avail_out = location->_decompressedLength - strm.total_out;
                
                status = inflate(&strm, Z_NO_FLUSH);
                NSParameterAssert(Z_STREAM_ERROR != status);
                switch (status) {
                    case Z_NEED_DICT:
                    case Z_DATA_ERROR:
                    case Z_MEM_ERROR:
                        FVLog(@"failed to decompress with error %d", status);
                }
                bytesRemaining -= location->_compressedLength;
                
            } while (bytesRemaining > 0);
            
            if (Z_STREAM_END != status)
                FVLog(@"failed to decompress; now what?  status = %d", status);
            
            (void)inflateEnd(&strm);
            
            if (mapregion) munmap(mapregion, mapLength);
            
            NSParameterAssert(strm.total_out == location->_decompressedLength);
            
            // transfer ownership to NSData in order to avoid copying
            data = [[NSData allocWithZone:[aKey zone]] initWithBytesNoCopy:bytes length:location->_decompressedLength freeWhenDone:YES];
        }
        else {
            FVLog(@"Unable to malloc %d bytes in -[FVCacheFile copyDataForKey:] with key %@", location->_decompressedLength, aKey);
        }

        NSParameterAssert([data length] == location->_decompressedLength);
        
        [location release];
    }
    
    return data;
}

- (void)invalidateDataForKey:(id)aKey;
{
    [_writeLock lock];
    // give copyDataForKey: a chance to get/retain
    [[[_offsetTable objectForKey:aKey] retain] autorelease];
    [_offsetTable removeObjectForKey:aKey];
    [_writeLock unlock];
}

@end

@implementation _FVCacheKey

+ (id)newWithURL:(NSURL *)aURL
{
    return [[self allocWithZone:[self zone]] initWithURL:aURL];
}

- (id)initWithURL:(NSURL *)aURL
{
    self = [super init];
    if (self) {
        
        // default to file not found
        OSStatus err = fnfErr;
        
        if ([aURL isFileURL]) {
            
            uint8_t stackBuf[PATH_MAX];
            uint8_t *fsPath = stackBuf;
            
            CFStringRef absolutePath = CFURLCopyFileSystemPath((CFURLRef)aURL, kCFURLPOSIXPathStyle);
            NSUInteger maxLen = CFStringGetMaximumSizeOfFileSystemRepresentation(absolutePath);
            if (maxLen > sizeof(stackBuf)) fsPath = new uint8_t[maxLen];
            CFStringGetFileSystemRepresentation(absolutePath, (char *)fsPath, maxLen);
            
            struct stat sb;
            err = stat((char *)fsPath, &sb);

            if (noErr == err) {
                _inode = sb.st_ino;
                _device = sb.st_dev;
                _hash = _inode;
            }
            
            if (fsPath != stackBuf) delete [] fsPath;
            if (absolutePath) CFRelease(absolutePath);
            
        }
        
        // for net URLs or if stat() failed
        if (noErr != err) {
            _inode = 0;
            _device = 0;
            // inline hash; CFURL hashing is expensive since it requires CFString copies
            _hash = [aURL hash];
        }
        
        // technically only required for isEqual: if noErr != err, but useful for description
        _URL = [aURL retain];
    }
    return self;
}

- (void)dealloc
{
    [_URL release];
    [super dealloc];
}

- (NSString *)description { return [_URL absoluteString]; }

- (id)copyWithZone:(NSZone *)aZone
{
    return NSShouldRetainWithZone(self, aZone) ? [self retain] : [[[self class] allocWithZone:aZone] initWithURL:_URL];
}

- (BOOL)isEqual:(_FVCacheKey *)other
{
    if ([other isKindOfClass:[self class]] == NO)
        return NO;
    
    if (other->_device == _device && other->_inode == _inode)        
        return (_device != 0 && _inode != 0) ? YES : [other->_URL isEqual:_URL];
    
    return NO;
}

- (NSUInteger)hash { return _hash; }

@end

@implementation _FVCacheLocation
@end

@implementation _FVCacheEventRecord

- (void)dealloc
{
    CFRelease(_identifier);
    [super dealloc];
}
- (NSString *)description { return [NSString stringWithFormat:@"%.2f kilobytes in %d files", _kbytes, _count]; }
- (NSUInteger)hash { return CFHash(_identifier); }
- (BOOL)isEqual:(id)other { return CFStringCompare(_identifier, ((_FVCacheEventRecord *)other)->_identifier, 0) == kCFCompareEqualTo; }
@end
