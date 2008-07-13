//
//  FVConcreteIcon.m
//  FileView
//
//  Created by Adam Maxwell on 7/12/08.
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

#import "FVConcreteIcon.h"
#import <Foundation/NSDebug.h>
#import "FVIcon_Private.h"

@implementation FVConcreteIcon

- (id)init
{
    self = [super init];
    if (self) _rc = 1;
    return self;
}

- (id)initWithURL:(NSURL *)aURL
{
    self = [self init];
    if (self) {
        _drawsLinkBadge = [[self class] _shouldDrawBadgeForURL:aURL copyTargetURL:&_fileURL];     
        _cacheKey = [FVIconCache newKeyForURL:_fileURL];
        pthread_mutex_init(&_mutex, NULL);
    }
    return self;
}

- (oneway void)release 
{
    do {
        
        if (1 == _rc) [self dealloc];
        
    } while (false == OSAtomicCompareAndSwap32Barrier(_rc, _rc - 1, (int32_t *)&_rc));
    NSRecordAllocationEvent(NSObjectInternalRefDecrementedEvent, self);
}

- (id)retain
{
    OSAtomicIncrement32Barrier((int32_t *)&_rc);
    NSRecordAllocationEvent(NSObjectInternalRefIncrementedEvent, self);
    return self;
}

- (NSUInteger)retainCount { return _rc; }

- (void)dealloc
{
    pthread_mutex_destroy(&_mutex);
    [_fileURL release];
    [_cacheKey release];
    [super dealloc];
}

- (BOOL)tryLock { return pthread_mutex_trylock(&_mutex) == 0; }
- (void)lock { pthread_mutex_lock(&_mutex); }
- (void)unlock { pthread_mutex_unlock(&_mutex); }


@end
