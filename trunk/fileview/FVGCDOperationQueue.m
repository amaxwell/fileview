//
//  FVGCDOperationQueue.m
//  FileView
//
//  Created by Adam Maxwell on 3/14/12.
/*
 This software is Copyright (c) 2012
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

#import "FVGCDOperationQueue.h"
#import "FVOperation.h"
#import "FVPriorityQueue.h"

@implementation FVGCDOperationQueue

+ (void)initialize
{
    FVINITIALIZE(FVGCDOperationQueue); 
}

- (id)init
{
    self = [super init];
    if (self) {
        
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(handleAppTerminate:) name:NSApplicationWillTerminateNotification object:NSApp];
        
        // this lock protects all of the collection ivars
        (void) pthread_mutex_init(&_queueLock, NULL);
        
        // pending operations
        _pendingOperations = [FVPriorityQueue new];
        
        // running operations
        _activeOperations = [NSMutableSet new];
        
        static NSUInteger __queueIndex = 0;
        NSString *queueName = [NSString stringWithFormat:@"com.mac.amaxwell.fileview-%lu", __queueIndex];
        __queueIndex++;
        
        _queue = dispatch_queue_create([queueName UTF8String], NULL);
    }
    return self;
}

- (void)dealloc
{
    dispatch_release(_queue);
    (void) pthread_mutex_destroy(&_queueLock);
    [_pendingOperations release];
    [_activeOperations release];
    [super dealloc];
}

- (void)handleAppTerminate:(NSNotification *)aNote
{
    [self terminate];
}

- (void)cancel;
{
    pthread_mutex_lock(&_queueLock);
    
    // objects in _pendingOperations queue are waiting to be executed, so just removing is likely sufficient; cancel anyways, just to be safe
    [_pendingOperations makeObjectsPerformSelector:@selector(cancel)];
    [_pendingOperations removeAllObjects];
    
    // these objects are presently executing, and we do not want them to call -finishedOperation: when their thread exits
    [_activeOperations makeObjectsPerformSelector:@selector(cancel)];
    [_activeOperations removeAllObjects];
    
    pthread_mutex_unlock(&_queueLock);
}

- (void)setThreadPriority:(double)p;
{
    NSLog(@"%s does nothing for GCD queue", __func__);
}

- (void)_startQueuedOperations
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    pthread_mutex_lock(&_queueLock);
    while ([_pendingOperations count]) {
        FVOperation *op = [_pendingOperations pop];
        // Coalescing based on _activeOperations here is questionable, since it's possible that the active operation is stale.
        if (NO == [op isCancelled] && NO == [_activeOperations containsObject:op]) {            
            [_activeOperations addObject:op];
            // avoid a deadlock for a non-threaded operation; -start can trigger -finishedOperation immediately on this thread
            pthread_mutex_unlock(&_queueLock);
            [op start];
            pthread_mutex_lock(&_queueLock);
        }        
    }
    pthread_mutex_unlock(&_queueLock);
    [pool release];
}

static void __FVGCDProcessQueueEntries(void *context)
{
    FVGCDOperationQueue *self = context;
    [self _startQueuedOperations];
    [self release];
}

- (void)addOperation:(FVOperation *)operation;
{
    [operation setQueue:self];
    pthread_mutex_lock(&_queueLock);
    [_pendingOperations push:operation];
    pthread_mutex_unlock(&_queueLock);
    dispatch_async_f(_queue, [self retain], __FVGCDProcessQueueEntries);
}

- (void)addOperations:(NSArray *)operations;
{
    [operations makeObjectsPerformSelector:@selector(setQueue:) withObject:self];
    pthread_mutex_lock(&_queueLock);
    [_pendingOperations pushMultiple:operations];
    pthread_mutex_unlock(&_queueLock);
    dispatch_async_f(_queue, [self retain], __FVGCDProcessQueueEntries);
}

// finishedOperation: callback received on an arbitrary thread
- (void)finishedOperation:(FVOperation *)anOperation;
{
    pthread_mutex_lock(&_queueLock);
    [_activeOperations removeObject:anOperation];
    pthread_mutex_unlock(&_queueLock);
}

- (void)terminate
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancel];
}

@end

