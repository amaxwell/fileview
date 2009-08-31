//
//  FVThread.m
//  FileView
//
//  Created by Adam Maxwell on 6/21/08.
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

#import "FVThread.h"
#import "FVUtilities.h"
#import <libkern/OSAtomic.h>
#import <pthread.h>

// lifted from CFInternal.h
#define __FVBitIsSet(V, N)  (((V) & (1UL << (N))) != 0)
#define __FVBitSet(V, N)  ((V) |= (1UL << (N)))
#define __FVBitClear(V, N)  ((V) &= ~(1UL << (N)))

enum {
    FVThreadSetup   = 1,
    FVThreadWaiting = 2,
    FVThreadWake    = 3,
    FVThreadDie     = 4
};

@interface _FVThread : NSObject
{
@private
    CFAbsoluteTime   _lastPerformTime;
    uint32_t         _threadIndex;
    uint32_t         _flags;    
    pthread_cond_t   _condition;
    pthread_mutex_t  _mutex;
    id               _target;
    id               _argument;
    SEL              _selector;    
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

// GCD seems to collect its threads fairly rapidly, and lets the number grow quite high
#define TIME_TO_DIE 10

#define THREAD_POOL_MAX 60
#define THREAD_POOL_MIN 0

static NSMutableArray  *_threadPool = nil;
static OSSpinLock       _lock = OS_SPINLOCK_INIT;
static int32_t          _threadPoolCapacity = THREAD_POOL_MAX;
static volatile int32_t _threadCount = 0;

#define DEBUG_REAPER 0


@implementation _FVThread

+ (void)_scheduleReaper
{
    [NSTimer scheduledTimerWithTimeInterval:TIME_TO_DIE target:self selector:@selector(reapThreads) userInfo:nil repeats:YES];
}

+ (void)initialize 
{
    FVINITIALIZE(_FVThread);
    
    // make sure Cocoa is multithreaded, since we're using pthreads directly
    [NSThread detachNewThreadSelector:@selector(self) toTarget:self withObject:nil];

    // nonretaining mutable array
    _threadPool = (NSMutableArray *)CFArrayCreateMutable(CFAllocatorGetDefault(), 0, NULL);
    
    // Pass in args on command line: -FVThreadPoolCapacity 0 to disable pooling
    NSNumber *capacity = [[NSUserDefaults standardUserDefaults] objectForKey:@"FVThreadPoolCapacity"];
    if (nil != capacity) _threadPoolCapacity = [capacity intValue];
    
    // schedule this on the main thread, since the class may first be used from a secondary thread
    [self performSelectorOnMainThread:@selector(_scheduleReaper) withObject:nil waitUntilDone:NO];    
}

/*
 The rules are simple: to use the pool, you need to obtain an _FVThread using +newThreadUsingPool.  When you're done, call +recycleThread: to return it to the queue.  There is no need to retain or release the _FVThread instance; it's retain count is never decremented after +alloc, and is also retained by its NSThread.  Hence we can use a nonretaining array and avoid refcounting overhead.
 */

+ (_FVThread *)newThreadUsingPool;
{
    OSSpinLockLock(&_lock);
    _FVThread *thread = nil;
    if ([_threadPool count]) {
        thread = [_threadPool lastObject];
        // no ownership transfer here
        [_threadPool removeLastObject];
    }
    OSSpinLockUnlock(&_lock);
    static int32_t reuseCount = 0;
    static int32_t newCount = 0;
    OSAtomicIncrement32Barrier(&newCount);
    if (nil == thread) {
        thread = [_FVThread new];
        OSAtomicIncrement32Barrier(&_threadCount);
    }
    else {
    OSAtomicIncrement32Barrier(&reuseCount);
    }
    if (newCount % 10)
        fprintf(stderr, "Of %d threads requested, %d reused (%.2f%%)\n", newCount, reuseCount, reuseCount*100 / (double)newCount);
    return thread;
}

// no ownership transfer here
+ (void)recycleThread:(_FVThread *)thread;
{
    NSParameterAssert(nil != thread);
    OSSpinLockLock(&_lock);
    NSAssert1([_threadPool containsObject:thread] == NO, @"thread %@ is already in the pool", thread);
    // no ownership transfer here
    [_threadPool addObject:thread];
    OSSpinLockUnlock(&_lock);
}

+ (void)reapThreads
{
    // !!! early return; recall that _threadCount != [_threadPool count] if threads are working
    if (_threadCount <= THREAD_POOL_MIN)
        return;
    
    OSSpinLockLock(&_lock);
    NSUInteger cnt = [_threadPool count];
#if DEBUG_REAPER
    FVLog(@"%d threads should fear the reaper", cnt);
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
    FVLog(@"%d threads will survive", [_threadPool count]);
#endif    
    OSSpinLockUnlock(&_lock);
}

+ (void)detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)argument;
{
    if (_threadPoolCapacity == _threadCount)
        [NSThread detachNewThreadSelector:selector toTarget:target withObject:argument];
    else
        [[self newThreadUsingPool] performSelector:selector withTarget:target argument:argument];
}

static void *__FVThread_main(void *obj);

- (id)init
{
    self = [super init];
    if (self) {
        
        // for debugging
        static volatile int32_t threadIndex = 0;
        _threadIndex = OSAtomicIncrement32Barrier(&threadIndex);
        
        _lastPerformTime = CFAbsoluteTimeGetCurrent();        
        _flags = 0;
        __FVBitSet(_flags, FVThreadSetup);
        
        int err;
        err = pthread_cond_init(&_condition, NULL);
        if (0 == err)
            err = pthread_mutex_init(&_mutex, NULL);
        
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        
        // not required as an ivar at present
        pthread_t thread;
        if (0 == err)
            err = pthread_create(&thread, &attr, __FVThread_main, [self retain]);
        pthread_attr_destroy(&attr);
        
        if (0 != err) {
            [super dealloc];
            self = nil;
        }
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
    pthread_cond_destroy(&_condition);
    pthread_mutex_destroy(&_mutex);
    [_target release];
    [_argument release];
    [super dealloc];
}

- (NSString *)debugDescription
{
    NSMutableString *desc = [NSMutableString stringWithFormat:@"%@: creation index %d {\n", [super description], _threadIndex];
    [desc appendFormat:@"\ttarget = %@\n", _target];
    [desc appendFormat:@"\targument = %@\n", _argument];
    [desc appendFormat:@"\tselector = %@ }", NSStringFromSelector(_selector)];
    return desc;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@: creation index %d", [super description], _threadIndex];
}

- (CFAbsoluteTime)lastPerformTime { return _lastPerformTime; }

- (void)die;
{
    // this should always acquire the lock immediately, since the (locked) pool should only contain idle threads
    pthread_mutex_lock(&_mutex);        
    if (__FVBitIsSet(_flags, FVThreadWaiting)) {
        __FVBitClear(_flags, FVThreadWaiting);
        __FVBitSet(_flags, FVThreadWake);
    }
#if DEBUG_REAPER
    else {
        FVLog(@"active thread will die: %@", [self debugDescription]);
    }
#endif
    __FVBitSet(_flags, FVThreadDie);
    pthread_cond_signal(&_condition);
    pthread_mutex_unlock(&_mutex);
}

static void *__FVThread_main(void *obj)
{
    
#if DEBUG_REAPER
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
#endif
    
    _FVThread *self = obj;
    
    pthread_mutex_lock(&self->_mutex);
        
    // performSelector:withTarget:argument: will block until this is ready
    
    __FVBitClear(self->_flags, FVThreadSetup);
    __FVBitSet(self->_flags, FVThreadWaiting);
    pthread_cond_signal(&self->_condition);
    pthread_mutex_unlock(&self->_mutex);
        
    // break from the loop when the exit bit is set
    while (1) {
        
        pthread_mutex_lock(&self->_mutex);
        int ret = 0;
        while (0 == ret && __FVBitIsSet(self->_flags, FVThreadWake) == NO)
            ret = pthread_cond_wait(&self->_condition, &self->_mutex);
        
        if (__FVBitIsSet(self->_flags, FVThreadDie)) {
            // I've seen things you people wouldn't believe. Attack ships on fire off the shoulder of Orion.  I watched C-beams glitter in the dark near the Tannhauser Gate.  All those moments will be lost in time, like tears in rain.  Time to die.
#if DEBUG_REAPER
            NSLog(@"Time to die.  %@", self);
#endif            
            NSCParameterAssert(nil == self->_target);
            NSCParameterAssert(nil == self->_argument);
            NSCParameterAssert(NULL == self->_selector);
            pthread_mutex_unlock(&self->_mutex);
            break;
        }
        else {
            
            // this is certainly a developer error
            FVAPIParameterAssert(NULL != self->_selector);
            if (self->_argument)
                [self->_target performSelector:self->_selector withObject:self->_argument];
            else
                [self->_target performSelector:self->_selector];
            __FVBitClear(self->_flags, FVThreadWake);
            __FVBitSet(self->_flags, FVThreadWaiting);
            
            // reset all ivars
            [self->_target release];
            self->_target = nil;
            [self->_argument release];
            self->_argument = nil;
            self->_selector = NULL;
            
            pthread_cond_signal(&self->_condition);
            pthread_mutex_unlock(&self->_mutex);
            
            // selector has been performed, and we're unlocked, so it's now safe to allow another caller to use this thread
            [_FVThread recycleThread:self];
        }
    }
    [self release];
#if DEBUG_REAPER
    [pool release];
#endif
    return NULL;
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
    int ret = 0;
    pthread_mutex_lock(&_mutex);
    while (0 == ret && __FVBitIsSet(_flags, FVThreadWaiting) == NO)
        ret = pthread_cond_wait(&_condition, &_mutex);

    NSParameterAssert(__FVBitIsSet(_flags, FVThreadDie) == NO);
    [self setTarget:target];
    [self setArgument:argument];
    [self setSelector:selector];
    _lastPerformTime = CFAbsoluteTimeGetCurrent();
    
    __FVBitClear(_flags, FVThreadWaiting);
    __FVBitSet(_flags, FVThreadWake);
    pthread_cond_signal(&_condition);
    pthread_mutex_unlock(&_mutex);
}

@end
