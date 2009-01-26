//
//  FVMainThreadOperationQueue.m
//  FileView
//
//  Created by Adam Maxwell on 2/23/08.
/*
 This software is 
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

#import "FVMainThreadOperationQueue.h"
#import "FVOperation.h"
#import "FVPriorityQueue.h"
#import "FVUtilities.h"

#import <pthread.h>

@implementation FVMainThreadOperationQueue

+ (void)initialize
{
    FVINITIALIZE(FVMainThreadOperationQueue);
}

static void __FVProcessSingleEntry(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info);

- (id)init
{
    NSAssert(pthread_main_np() != 0, @"incorrect thread for main queue");

    self = [super init];
    if (self) {
        
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(handleAppTerminate:) name:NSApplicationWillTerminateNotification object:NSApp];
        
        // this lock protects all of the collection ivars
        _queueLock = OS_SPINLOCK_INIT;
        
        // pending operations
        _pendingOperations = [FVPriorityQueue new];
        
        // running operations
        _activeOperations = [NSMutableSet new];     
        
        CFRunLoopObserverContext context = { 0, self, NULL, NULL, NULL };
        CFRunLoopActivity activity =  kCFRunLoopEntry | kCFRunLoopBeforeWaiting;
        _observer = CFRunLoopObserverCreate(NULL, activity, TRUE, 0, __FVProcessSingleEntry, &context);
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), (CFStringRef)FVMainQueueRunLoopMode);
        CFRunLoopAddObserver(CFRunLoopGetMain(), _observer, (CFStringRef)FVMainQueueRunLoopMode);
        CFRunLoopAddObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
    }
    return self;
}

- (void)dealloc
{
    [self terminate];
    NSParameterAssert(FALSE == CFRunLoopContainsObserver(CFRunLoopGetMain(), _observer, (CFStringRef)FVMainQueueRunLoopMode));
    NSParameterAssert(FALSE == CFRunLoopContainsObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes));
    CFRelease(_observer);
    _observer = NULL;
    [_pendingOperations release];
    [_activeOperations release];
    [super dealloc];
}

- (void)handleAppTerminate:(NSNotification *)aNote
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancel];
}

- (void)terminate;
{
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), _observer, (CFStringRef)FVMainQueueRunLoopMode);
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
    [self cancel];
}

- (void)cancel;
{
    OSSpinLockLock(&_queueLock);
    
    // objects in _pendingOperations queue are waiting to be executed, so just removing is likely sufficient; cancel anyways, just to be safe
    [_pendingOperations makeObjectsPerformSelector:@selector(cancel)];
    [_pendingOperations removeAllObjects];
    
    // these objects are presently executing, and we do not want them to call -finishedOperation: when their thread exits
    [_activeOperations makeObjectsPerformSelector:@selector(cancel)];
    [_activeOperations removeAllObjects];
    
    OSSpinLockUnlock(&_queueLock);
}

- (void)addOperation:(FVOperation *)operation;
{
    [operation setQueue:self];
    
    OSSpinLockLock(&_queueLock);
    [_pendingOperations push:operation];
    OSSpinLockUnlock(&_queueLock); 
    // needed if the app is in the background
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)addOperations:(NSArray *)operations;
{
    [operations makeObjectsPerformSelector:@selector(setQueue:) withObject:self];
    
    OSSpinLockLock(&_queueLock);
    [_pendingOperations pushMultiple:operations];
    OSSpinLockUnlock(&_queueLock);   
    // needed if the app is in the background
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

/*
 Process a single entry, and let the finishedOperation: callback wake the runloop for the next one.
 This potentially allows other processing to take place between queued operations and avoids blocking
 the main thread's runloop (and event loop) while processing operations.
 */
static void __FVProcessSingleEntry(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    NSCAssert(pthread_main_np() != 0, @"incorrect thread for main queue");
    FVMainThreadOperationQueue *queue = info;    
    FVOperation *op = nil;

    // ignore cancelled operations, so we get finishedOperation: (no coalescing on _activeOperations)
    OSSpinLockLock(&(queue->_queueLock));
    do {
        op = [queue->_pendingOperations pop];
    } while ([op isCancelled]);
    
    // !!! unlock on all branches
    if (op) {
        [queue->_activeOperations addObject:op];
        // avoid deadlock: next call may trigger finishedOperation: on this thread
        OSSpinLockUnlock(&(queue->_queueLock));
        [op start];
    }
    else {
        OSSpinLockUnlock(&(queue->_queueLock));
    }
}

- (void)setThreadPriority:(double)p;
{
    NSLog(@"*** WARNING *** %@ ignoring request to change main thread priority", self);
}

// finishedOperation: callback received on the main thread
- (void)finishedOperation:(FVOperation *)anOperation;
{
    OSSpinLockLock(&_queueLock);
    [_activeOperations removeObject:anOperation];
    NSUInteger cnt = [_pendingOperations count];
    OSSpinLockUnlock(&_queueLock);
    
    /*
     Process another operation if necessary.  If multiple ops added at once, we only get
     a wakeup message for the entire batch, but they're processed singly.
     */
    if (cnt) CFRunLoopWakeUp(CFRunLoopGetMain());
}

@end
