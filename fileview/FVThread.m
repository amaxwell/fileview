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
#import "FVUtilities.h"
#import <libkern/OSAtomic.h>

@interface _FVThread : NSObject
{
    NSConditionLock *_condLock;
    NSString        *_threadDescription;
    id               _target;
    id               _argument;
    SEL              _selector;
    CFAbsoluteTime   _lastPerformTime;
    BOOL             _timeToDie;
}

+ (void)detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)argument;
- (void)performSelector:(SEL)selector withTarget:(id)target argument:(id)argument;
- (CFAbsoluteTime)lastPerformTime;
- (void)die;

@end

@implementation FVThread

+ (void)detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)argument;
{
    [_FVThread detachNewThreadSelector:selector toTarget:target withObject:argument];
}

@end

#define THREAD_POOL_MAX 20
#define THREAD_POOL_MIN 4

static NSMutableArray  *_threadPool = nil;
static OSSpinLock       _lock = OS_SPINLOCK_INIT;
static int32_t          _threadPoolCapacity = THREAD_POOL_MAX;
static volatile int32_t _threadCount = 0;

#define FVTHREADWAITING 1
#define FVTHREADWAKE    2

#define DEBUG_REAPER 0
#if DEBUG_REAPER
#define TIME_TO_DIE 60
#else
#define TIME_TO_DIE 300
#endif

@implementation _FVThread

+ (void)initialize 
{
    FVINITIALIZE(_FVThread);
    
    // nonretaining mutable array
    _threadPool = (NSMutableArray *)CFArrayCreateMutable(CFAllocatorGetDefault(), 0, NULL);
    
    // Pass in args on command line: -FVThreadPoolCapacity 0 to disable pooling
    NSNumber *capacity = [[NSUserDefaults standardUserDefaults] objectForKey:@"FVThreadPoolCapacity"];
    if (nil != capacity) _threadPoolCapacity = [capacity intValue];
    [NSTimer scheduledTimerWithTimeInterval:TIME_TO_DIE target:self selector:@selector(reapThreads) userInfo:nil repeats:YES];
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

+ (void)reapThreads
{
    OSSpinLockLock(&_lock);
    NSUInteger cnt = [_threadPool count];
#if DEBUG_REAPER
    NSLog(@"%d threads should fear the reaper", cnt);
#endif
    while (cnt-- && _threadCount > THREAD_POOL_MIN) {
        _FVThread *thread = [_threadPool objectAtIndex:cnt];
        if (CFAbsoluteTimeGetCurrent() - [thread lastPerformTime] > TIME_TO_DIE) {
            [thread die];
            [_threadPool removeObjectAtIndex:cnt];
            [thread release];
            OSAtomicDecrement32Barrier(&_threadCount);
        }
    }
#if DEBUG_REAPER
    NSLog(@"%d threads will survive", [_threadPool count]);
#endif    
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
        _lastPerformTime = CFAbsoluteTimeGetCurrent();
        _timeToDie = NO;
        // return immediately; performSelector:withObject:argument: will block if necessary until the thread is running
    }
    return self;
}

// _FVThread instances should never dealloc, since they are retained by the NSThread
- (void)dealloc
{
#if DEBUG_REAPER
    NSLog(@"dealloc %@", self);
#endif
    [_condLock release];
    [_target release];
    [_argument release];
    [_threadDescription release];
    [super dealloc];
}

- (NSString *)debugDescription
{
    NSMutableString *desc = [NSMutableString stringWithFormat:@"%@: %@ {\n", [super description], _threadDescription];
    [desc appendFormat:@"\ttarget = %@\n", _target];
    [desc appendFormat:@"\targument = %@\n", _argument];
    [desc appendFormat:@"\tselector = %@ }", NSStringFromSelector(_selector)];
    return desc;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@: %@", [super description], _threadDescription];
}

- (CFAbsoluteTime)lastPerformTime { return _lastPerformTime; }

- (void)die;
{
    if ([_condLock tryLockWhenCondition:FVTHREADWAITING]) {
        _timeToDie = YES;
        [_condLock unlockWithCondition:FVTHREADWAKE];
    }
#if DEBUG_REAPER
    else {
        FVLog(@"active thread will die: %@", [self debugDescription]);
    }
#endif
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
        
        if (_timeToDie) {
            /*
                 I've seen things you people wouldn't believe. 
                 Attack ships on fire off the shoulder of Orion. 
                 I watched C-beams glitter in the dark near the Tannhauser Gate. 
                 All those moments will be lost in time, like tears in rain.
                 Time to die.
             */
#if DEBUG_REAPER
            NSLog(@"Time to die.  %@", self);
#endif            
            [_condLock unlockWithCondition:FVTHREADWAITING];
            break;
        }
        else {
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
    [pool release];
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
    NSParameterAssert(NO == _timeToDie);
    [self setTarget:target];
    [self setArgument:argument];
    [self setSelector:selector];
    _lastPerformTime = CFAbsoluteTimeGetCurrent();
    [_condLock unlockWithCondition:FVTHREADWAKE];
}

@end
