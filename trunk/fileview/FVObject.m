//
//  FVObject.m
//  FileView
//
//  Created by Adam Maxwell on 07/21/08.
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

#import "FVObject.h"
#import "FVUtilities.h"
#import <Foundation/NSDebug.h>
#import <libkern/OSAtomic.h>

extern bool __CFOASafe;
static bool __FVOASafe = false;
#define RETAIN_WARNING_THRESHOLD 1000000

@implementation FVObject

+ (void)initialize
{
    FVINITIALIZE(FVObject);
    
    // used by CF and liboainject; Omni uses NSKeepAllocationStatistics, but the header says that's unused
    if (&__CFOASafe) __FVOASafe = __CFOASafe;
}

// _rc is initialized to zero in allocWithZone:, so avoid overriding -init by counting from 0.

#if DEBUG
static void _FVObjectError(NSString *format, ...)
{
    va_list list;
    va_start(list, format);
    FVLogv(format, list);
    va_end(list);
}
#endif

- (oneway void)release 
{
    // call NSRecordAllocationEvent before the event, since it may call retainCount (and we may dealloc)
    if (__builtin_expect(__FVOASafe, 0)) NSRecordAllocationEvent(NSObjectInternalRefDecrementedEvent, self);
    
    if (__builtin_expect(0 == _rc, 0)) {
        [self dealloc];
    }
    else {
        int32_t rc = OSAtomicDecrement32Barrier((volatile int32_t *)&_rc);
#if DEBUG
        if (__builtin_expect(-1 == rc, 0))
            _FVObjectError(@"*** possible refcount underflow for %@, break on _FVObjectError() to debug.", self);
#else
#pragma unused(rc)
#endif
    }
}

- (id)retain
{
    if (__builtin_expect(__FVOASafe, 0)) NSRecordAllocationEvent(NSObjectInternalRefIncrementedEvent, self);
    
    uint32_t rc = OSAtomicIncrement32Barrier((volatile int32_t *)&_rc);
#if DEBUG
    if (__builtin_expect(RETAIN_WARNING_THRESHOLD < rc, 1))
        _FVObjectError(@"*** high retain count (%u) for %@, break on _FVObjectError() to debug.", rc, self);
#else
#pragma unused(rc)
#endif

    return self;
}

- (NSUInteger)retainCount { return _rc + 1; }


@end
