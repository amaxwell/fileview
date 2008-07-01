//
//  FVThread.m
//  FileView
//
//  Created by Adam Maxwell on 6/21/08.
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

#import "FVThread.h"
#import <libkern/OSAtomic.h>

@interface _FVThread : NSObject
{
    NSConditionLock *_condLock;
    NSString        *_threadDescription;
    id               _target;
    id               _argument;
    SEL              _selector;
}

+ (void)detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)argument;
- (void)performSelector:(SEL)selector withTarget:(id)target argument:(id)argument;

@end

@implementation FVThread

+ (void)detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)argument;
{
    [_FVThread detachNewThreadSelector:selector toTarget:target withObject:argument];
}

@end

static NSMutableArray  *_threadPool = nil;
static OSSpinLock       _lock = OS_SPINLOCK_INIT;
static int32_t          _threadPoolCapacity = 14;
static volatile int32_t _threadCount = 0;

#define FVTHREADWAITING 1
#define FVTHREADWAKE    2

@implementation _FVThread

+ (void)initialize 
{
    FVINITIALIZE(_FVThread);
    
    // nonretaining mutable array
    _threadPool = (NSMutableArray *)CFArrayCreateMutable(CFAllocatorGetDefault(), 0, NULL);
    
    // Pass in args on command line: -FVThreadPoolCapacity 0 to disable pooling
    NSNumber *capacity = [[NSUserDefaults standardUserDefaults] objectForKey:@"FVThreadPoolCapacity"];
    if (nil != capacity) _threadPoolCapacity = [capacity intValue];
}

/*
 The rules are simple: to use the pool, you need to obtain an _FVThread using +backgroundThread.  When you're done, call +recycleBackgroundThread: to return it to the queue.  There is no need to retain or release the _FVThread instance; it's retain count is never decremented after +alloc, and is also retained by its NSThread.  Hence we can use a nonretaining array and avoid refcounting overhead.
 */

+ (_FVThread *)backgroundThread;
{
    OSSpinLockLock(&_lock);
    _FVThread *thread = nil;
    if ([_threadPool count]) {
        thread = [_threadPool lastObject];
        // no ownership transfer here
        [_threadPool removeLastObject];
    }
    OSSpinLockUnlock(&_lock);
    if (nil == thread) {
        thread = [_FVThread new];
        OSAtomicIncrement32Barrier(&_threadCount);
    }
    return thread;
}

// no ownership transfer here
+ (void)recycleBackgroundThread:(_FVThread *)thread;
{
    NSParameterAssert(nil != thread);
    OSSpinLockLock(&_lock);
    NSParameterAssert([_threadPool containsObject:thread] == NO);
    // no ownership transfer here
    [_threadPool addObject:thread];
    OSSpinLockUnlock(&_lock);
}

+ (void)detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)argument;
{
    if (_threadPoolCapacity == _threadCount)
        [NSThread detachNewThreadSelector:selector toTarget:target withObject:argument];
    else
        [[self backgroundThread] performSelector:selector withTarget:target argument:argument];
}

- (id)init
{
    self = [super init];
    if (self) {
        _condLock = [NSConditionLock new];
        [NSThread detachNewThreadSelector:@selector(_run) toTarget:self withObject:nil];
        // return immediately; performSelector:withObject:argument: will block if necessary until the thread is running
    }
    return self;
}

// _FVThread instances should never dealloc, since they are retained by the NSThread
- (void)dealloc
{
    [_condLock release];
    [_target release];
    [_argument release];
    [_threadDescription release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@: %@", [super description], _threadDescription];
}

- (void)_run
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    
    [_condLock lock];
    
    // do some initial debugging setup
    NSThread *currentThread = [NSThread currentThread];
    static uint32_t threadIndex = 0;
    if ([currentThread respondsToSelector:@selector(setName:)])
        [currentThread setName:[NSString stringWithFormat:@"FVThread index %d", threadIndex++]];
    
    _threadDescription = [[currentThread description] copy];
    
    // performSelector:withTarget:argument: will block until this is ready
    [_condLock unlockWithCondition:FVTHREADWAITING];
        
    // no exit condition, so the thread will run until the program dies
    while (1) {
        [_condLock lockWhenCondition:FVTHREADWAKE];
        if (_argument)
            [_target performSelector:_selector withObject:_argument];
        else
            [_target performSelector:_selector];
        [_condLock unlockWithCondition:FVTHREADWAITING];
        [pool release];
        pool = [NSAutoreleasePool new];
        
        // selector has been performed, and we're unlocked, so it's now safe to allow another caller to use this thread
        [_FVThread recycleBackgroundThread:self];
    }
}

- (void)setTarget:(id)value {
    if (_target != value) {
        [_target release];
        _target = [value retain];
    }
}

- (void)setArgument:(id)value {
    if (_argument != value) {
        [_argument release];
        _argument = [value retain];
    }
}

- (void)setSelector:(SEL)selector
{
    _selector = selector;
}

- (void)performSelector:(SEL)selector withTarget:(id)target argument:(id)argument;
{
    [_condLock lockWhenCondition:FVTHREADWAITING];
    [self setTarget:target];
    [self setArgument:argument];
    [self setSelector:selector];
    [_condLock unlockWithCondition:FVTHREADWAKE];
}

@end
