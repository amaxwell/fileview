//
//  FVAllocator.m
//  FileView
//
//  Created by Adam Maxwell on 08/01/08.
/*
 This software is Copyright (c) 2008-2011
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

#import "FVAllocator.h"
#import "fv_zone.h"

#define USE_SYSTEM_ZONE 1

static CFStringRef __FVAllocatorCopyDescription(const void *info)
{
    CFStringRef format = CFStringCreateWithCString(NULL, "FVAllocator <%p>", kCFStringEncodingASCII);
    CFStringRef ret = CFStringCreateWithFormat(NULL, NULL, format, info);
    CFRelease(format);
    return ret;
}

// return an available buffer of sufficient size or create a new one
static void * __FVAllocate(CFIndex allocSize, CFOptionFlags hint, void *info)
{
    if (__builtin_expect(allocSize <= 0, 0))
        return NULL;
    
    return malloc_zone_malloc((malloc_zone_t *)info, allocSize);
}

static void __FVDeallocate(void *ptr, void *info)
{
    malloc_zone_free((malloc_zone_t *)info, ptr);
}

static void * __FVReallocate(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info)
{
    // as per documentation for CFAllocatorContext
    if (__builtin_expect((NULL == ptr || newSize <= 0), 0))
        return NULL;
    
    return malloc_zone_realloc((malloc_zone_t *)info, ptr, newSize);
}

static CFIndex __FVPreferredSize(CFIndex size, CFOptionFlags hint, void *info)
{
    malloc_zone_t *zone = (malloc_zone_t *)info;
    return zone->introspect->good_size(zone, size);
}

#pragma mark Setup and cleanup

// single instance of this allocator
static CFAllocatorRef  _allocator = NULL;
static malloc_zone_t  *_allocatorZone = NULL;

__attribute__ ((constructor))
static void __initialize_allocator()
{        
#if USE_SYSTEM_ZONE
    _allocatorZone = malloc_default_zone();
    _allocator = CFAllocatorGetDefault();
#else
    // create the initial zone
    _allocatorZone = fv_create_zone_named("FVAllocatorZone");
    
    // wrap the zone in a CFAllocator; could just return it directly, though
    CFAllocatorContext context = { 
        0, 
        _allocatorZone, 
        NULL, 
        NULL, 
        __FVAllocatorCopyDescription, 
        __FVAllocate, 
        __FVReallocate, 
        __FVDeallocate, 
        __FVPreferredSize 
    };
    _allocator = CFAllocatorCreate(CFAllocatorGetDefault(), &context);
#endif
}

#pragma mark API

CFAllocatorRef FVAllocatorGetDefault() {  return _allocator; }

// NSZone is the same as malloc_zone_t: http://lists.apple.com/archives/objc-language/2008/Feb/msg00033.html
NSZone * FVDefaultZone() { return (void *)_allocatorZone; }
