//
//  FVIconOperation.m
//  FileView
//
//  Created by Adam Maxwell on 2/9/08.
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

#import "FVIconOperation.h"
#import "FVOperationQueue.h"
#import "FVInvocationOperation.h"
#import "FVIcon.h"
#import "FileView.h"
#import <pthread.h>

@implementation FVIconOperation

- (id)initWithIcon:(FVIcon *)icon view:(FileView *)view;
{
    NSParameterAssert(nil != icon);
    NSParameterAssert(nil == view || [view respondsToSelector:@selector(iconUpdated:)]);
    self = [super init];
    if (self) {
        _view = [view retain];
        _icon = [icon retain];
    }
    return self;
}

// class and pointer equality of icon and target; instances with the same icon but a different view should not be equal
- (BOOL)isEqual:(FVIconOperation *)other
{
    return [other isMemberOfClass:[self class]] && other->_icon == _icon && other->_view == _view;
}

// returns an address-based hash, suitable for pointer equality
- (NSUInteger)hash { return [_icon hash]; }

- (void)dealloc
{
    [_icon release];
    // release is thread safe, but we don't want to trigger dealloc on this thread
    [_view performSelectorOnMainThread:@selector(release) withObject:nil waitUntilDone:NO];
    [super dealloc];
}

@end


@implementation FVReleaseOperation

// avoid running a new thread for each release
- (BOOL)isConcurrent { return NO; }

- (void)main;
{
    if (NO == [self isCancelled]) {
        NSAutoreleasePool *pool = [NSAutoreleasePool new];
        [_icon releaseResources];
        [self finished];
        [pool release];
    }
}

@end

@interface FVIconUpdateOperation : FVIconOperation
@end

@interface FileView (Update)
- (void)iconUpdated:(FVIcon *)anIcon;
@end

@implementation FVIconUpdateOperation

- (BOOL)isConcurrent { return NO; }

- (void)main
{
    NSAssert(pthread_main_np() != 0, @"incorrect thread for FVIconUpdateOperation");        
    [_view iconUpdated:_icon];
    [self finished];
}

@end

@implementation FVRenderOperation

- (void)main;
{
    if (NO == [self isCancelled]) {
        NSAutoreleasePool *pool = [NSAutoreleasePool new];
        [_icon renderOffscreen];
        FVIconUpdateOperation *op = [[FVIconUpdateOperation alloc] initWithIcon:_icon view:_view];
        [[FVOperationQueue mainQueue] addOperation:op];
        [op release];
        [self finished];
        [pool release];
    }
}

@end

