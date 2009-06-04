//
//  _FVMappedDataProvider.m
//  FileView
//
//  Created by Adam Maxwell on 7/14/08.
/*
 This software is Copyright (c) 2008-2009
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

#import "_FVMappedDataProvider.h"
#import "FVObject.h"
#import "FVUtilities.h"
#import <pthread.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <libkern/OSAtomic.h>


typedef struct _FVMappedRegion {
    NSZone *zone;
    char   *path;
    void   *mapregion;
    off_t   length;
} FVMappedRegion;

static volatile int32_t _mappedDataSizeKB = 0;
#define MAX_MAPPED_SIZE_KB 400000

// This is intentionally low, since I don't know what the limit is, and sysctl doesn't say.  The max number of file descriptors is ~255 per process, but I can actually mmap ~28,000 files on 10.5.4.  We should never see even this many in practice, though.
#define MAX_MAPPED_PROVIDER_COUNT 254

static const void *__FVGetMappedRegion(void *info);
static void __FVReleaseMappedRegion(void *info);
const CGDataProviderDirectAccessCallbacks _FVMappedDataProviderCallBacks = { __FVGetMappedRegion, NULL, NULL, __FVReleaseMappedRegion };
// 10.5 and later
const CGDataProviderDirectCallbacks _FVMappedDataProviderDirectCallBacks = { 0, __FVGetMappedRegion, NULL, NULL, __FVReleaseMappedRegion };

static CFMutableDictionaryRef _dataProviders = NULL;
static pthread_mutex_t _providerLock = PTHREAD_MUTEX_INITIALIZER;

@interface _FVProviderInfo : FVObject
{
@public;
    CGDataProviderRef _provider;
    NSUInteger        _refCount;
}
@end

@implementation _FVMappedDataProvider

+ (void)initialize 
{
    FVINITIALIZE(_FVMappedDataProvider);
    _dataProviders = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

+ (BOOL)maxSizeExceeded
{
    return _mappedDataSizeKB > MAX_MAPPED_SIZE_KB || CFDictionaryGetCount(_dataProviders) >= MAX_MAPPED_PROVIDER_COUNT;
}

+ (unsigned char)maxProviderCount;
{
    return MAX_MAPPED_PROVIDER_COUNT;
}

+ (CGDataProviderRef)newDataProviderForURL:(NSURL *)aURL
{
    pthread_mutex_lock(&_providerLock);
    _FVProviderInfo *pInfo = (id)CFDictionaryGetValue(_dataProviders, (CFURLRef)aURL);
    if (nil == pInfo && CFDictionaryGetCount(_dataProviders) < MAX_MAPPED_PROVIDER_COUNT) {
        pInfo = [_FVProviderInfo new];
        pInfo->_refCount = 0;
        pInfo->_provider = NULL;
        
        const char *path = [[aURL path] fileSystemRepresentation];
        /* 
         Open the file so no one unlinks it until we're done here (may be a temporary PS file).  This means that stat and the assertion here will succeed if the file still exists.  The provider is supposed to handle mmap failures gracefully, so we just close the file descriptor when the provider info is set up. 
         */
        int fd = open(path, O_RDONLY);
        fcntl(fd, F_NOCACHE, 1);
        struct stat sb;
        if (-1 != fd && -1 != fstat(fd, &sb)) {
            
            // don't mmap network/firewire/usb filesystems
            NSAssert1(FVCanMapFileAtURL(aURL), @"%@ is not safe for mmap()", aURL);
            fcntl(fd, F_NOCACHE, 1);

            NSZone *zone = [self zone];
            FVMappedRegion *mapInfo = NSZoneMalloc(zone, sizeof(FVMappedRegion));
            mapInfo->zone = zone;
            mapInfo->path = NSZoneCalloc(zone, strlen(path) + 1, sizeof(char));
            strcpy(mapInfo->path, path);
            mapInfo->length = sb.st_size;   
            // map immediately instead of lazily in __FVGetMappedRegion, since someone might edit the file
            mapInfo->mapregion = mmap(0, mapInfo->length, PROT_READ, MAP_PRIVATE, fd, 0);
            if (mapInfo->mapregion == MAP_FAILED) {
                perror("failed to mmap file");
                mapInfo->mapregion = NULL;
            }
            else {
                bool swap;
                do {
                    int32_t newSize = _mappedDataSizeKB + (mapInfo->length) / 1024;
                    swap = OSAtomicCompareAndSwap32Barrier(_mappedDataSizeKB, newSize, &_mappedDataSizeKB);
                } while (false == swap);
            }
#if (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5)
            pInfo->_provider = CGDataProviderCreateDirect(mapInfo, mapInfo->length, &_FVMappedDataProviderDirectCallBacks);
#else
            // if compiled for 10.4, check for the symbol before using it
            if (NULL != CGDataProviderCreateDirect)
                pInfo->_provider = CGDataProviderCreateDirect(mapInfo, mapInfo->length, &_FVMappedDataProviderDirectCallBacks);
            else
                pInfo->_provider = CGDataProviderCreateDirectAccess(mapInfo, mapInfo->length, &_FVMappedDataProviderCallBacks);
#endif
        }
        close(fd);
        CFDictionarySetValue(_dataProviders, (CFURLRef)aURL, pInfo);
        [pInfo release];
    }
    if (pInfo) pInfo->_refCount++;
    pthread_mutex_unlock(&_providerLock);
    return pInfo ? pInfo->_provider : NULL;
}

+ (void)releaseProviderForURL:(NSURL *)aURL
{
    pthread_mutex_lock(&_providerLock);
    _FVProviderInfo *pInfo = (id)CFDictionaryGetValue(_dataProviders, (CFURLRef)aURL);
    if (pInfo) {
        NSAssert1(pInfo->_refCount > 0, @"Mapped provider refcount underflow for %@", [aURL path]);
        pInfo->_refCount--;
        if (pInfo->_refCount == 0) {
            CGDataProviderRelease(pInfo->_provider);
            CFDictionaryRemoveValue(_dataProviders, aURL);
        }
    }
    pthread_mutex_unlock(&_providerLock);
}

@end

@implementation _FVProviderInfo
@end


static const void *__FVGetMappedRegion(void *info)
{
    FVMappedRegion *mapInfo = info;
    return mapInfo->mapregion;
}

static void __FVReleaseMappedRegion(void *info)
{
    FVMappedRegion *mapInfo = info;
    NSZoneFree(mapInfo->zone, mapInfo->path);
    if (mapInfo->mapregion) munmap(mapInfo->mapregion, mapInfo->length);
    bool swap;
    do {
        int32_t newSize = _mappedDataSizeKB - (mapInfo->length) / 1024;
        swap = OSAtomicCompareAndSwap32Barrier(_mappedDataSizeKB, newSize, &_mappedDataSizeKB);
    } while (false == swap);
    NSZoneFree(mapInfo->zone, info);
}

