//
//  _FVMappedDataProvider.m
//  FileView
//
//  Created by Adam Maxwell on 7/14/08.
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

#import "_FVMappedDataProvider.h"
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

static int32_t _mappedDataSizeKB = 0;
#define MAX_MAPPED_SIZE_KB 400000

static const void *__FVGetMappedRegion(void *info);
static void __FVReleaseMappedRegion(void *info);
const CGDataProviderDirectAccessCallbacks _FVMappedDataProviderCallBacks = { __FVGetMappedRegion, NULL, NULL, __FVReleaseMappedRegion };

static CFMutableDictionaryRef _dataProviders = NULL;
static pthread_mutex_t _providerLock = PTHREAD_MUTEX_INITIALIZER;

@interface _FVProviderInfo : NSObject
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
    return _mappedDataSizeKB > MAX_MAPPED_SIZE_KB;
}

+ (CGDataProviderRef)dataProviderForURL:(NSURL *)aURL
{
    pthread_mutex_lock(&_providerLock);
    _FVProviderInfo *pInfo = (id)CFDictionaryGetValue(_dataProviders, (CFURLRef)aURL);
    if (nil == pInfo) {
        pInfo = [_FVProviderInfo new];
        pInfo->_refCount = 0;
        pInfo->_provider = NULL;
        
        const char *path = [[aURL path] fileSystemRepresentation];
        /* 
         Open the file so no one unlinks it until we're done here (may be a temporary PS file).  This means that stat and the assertion here will succeed if the file still exists.  The provider is supposed to handle mmap failures gracefully, so we just close the file descriptor when the provider info is set up. 
         */
        int fd = open(path, O_RDONLY);
        struct stat sb;
        if (-1 != fd && -1 != fstat(fd, &sb)) {
            
            // don't mmap network/firewire/usb filesystems
            NSParameterAssert(FVCanMapFileAtURL(aURL));
            
            NSZone *zone = [self zone];
            FVMappedRegion *mapInfo = NSZoneMalloc(zone, sizeof(FVMappedRegion));
            mapInfo->zone = zone;
            mapInfo->path = NSZoneCalloc(zone, strlen(path) + 1, sizeof(char));
            strcpy(mapInfo->path, path);
            mapInfo->length = sb.st_size;                
            mapInfo->mapregion = NULL;
            pInfo->_provider = CGDataProviderCreateDirectAccess(mapInfo, mapInfo->length, &_FVMappedDataProviderCallBacks);
        }
        close(fd);
        CFDictionarySetValue(_dataProviders, (CFURLRef)aURL, pInfo);
        [pInfo release];
    }
    if (pInfo) pInfo->_refCount++;
    pthread_mutex_unlock(&_providerLock);
    return pInfo ? pInfo->_provider : NULL;
}

+ (void)removeProviderReferenceForURL:(NSURL *)aURL
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
    if (NULL == mapInfo->mapregion) {
        int fd = open(mapInfo->path, O_RDONLY);
        if (-1 == fd) {
            perror("failed to open PDF file");
        }
        else {
            mapInfo->mapregion = mmap(0, mapInfo->length, PROT_READ, MAP_SHARED, fd, 0);
            if (mapInfo->mapregion == (void *)-1) {
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
            close(fd);
        }
    }
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

