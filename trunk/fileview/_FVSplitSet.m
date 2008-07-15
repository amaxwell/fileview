//
//  _FVSplitSet.m
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

#import "_FVSplitSet.h"


@implementation _FVSplitSet

- (id)initWithSplit:(NSUInteger)split
{
    self = [super init];
    if (self) {
        _old = CFSetCreateMutable(CFAllocatorGetDefault(), 0, NULL);
        _new = CFSetCreateMutable(CFAllocatorGetDefault(), split, NULL);
        _split = split;
    }
    return self;
}

- (id)init { return [self initWithSplit:100]; }

- (void)dealloc
{
    CFRelease(_old);
    CFRelease(_new);
    [super dealloc];
}

- (NSUInteger)split { return _split; }

- (void)addObject:(id)obj
{
    if ((NSUInteger)CFSetGetCount(_new) < _split) {
        CFSetAddValue(_new, obj);
    }
    else {
        [(NSMutableSet *)_old unionSet:(NSSet *)_new];
        CFSetRemoveAllValues(_new);
    }
}

- (void)removeObject:(id)obj
{
    CFSetRemoveValue(_new, obj);
    CFSetRemoveValue(_old, obj);
}

- (void)removeOldObjects { CFSetRemoveAllValues(_old); }

- (NSSet *)copyOldObjects { return (NSSet *)CFSetCreateCopy(CFGetAllocator(_old), _old); }

- (NSUInteger)count { return CFSetGetCount(_old) + CFSetGetCount(_new); }

@end
