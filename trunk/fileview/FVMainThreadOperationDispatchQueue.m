//
//  FVMainThreadOperationDispatchQueue.m
//  FileView
//
//  Created by Adam R. Maxwell on 05/02/10.
/*
 This software is Copyright (c) 2010-2011
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

#import "FVMainThreadOperationDispatchQueue.h"
#import "FVOperation.h"
#import "FVPriorityQueue.h"
#import "FVUtilities.h"

#if USE_DISPATCH_QUEUE && (MAC_OS_X_VERSION_MIN_REQUIRED > MAC_OS_X_VERSION_10_5)
#import <dispatch/dispatch.h>
#endif
#import <pthread.h>

@implementation FVMainThreadOperationDispatchQueue

#if USE_DISPATCH_QUEUE && (MAC_OS_X_VERSION_MIN_REQUIRED > MAC_OS_X_VERSION_10_5)

#warning main thread queue is GCD

+ (void)initialize
{
    FVINITIALIZE(FVMainThreadOperationDispatchQueue);
}

- (id)init
{
    NSAssert(pthread_main_np() != 0, @"incorrect thread for main queue");
    
    self = [super init];
    if (self) {
        
        // this lock protects all of the collection ivars
        (void) pthread_mutex_init(&_queueLock, NULL);
        
        // pending and active operations
        _currentOperations = [NSMutableSet new];
        
    }
    return self;
}

- (void)dealloc
{
    [self terminate];
    [_currentOperations release];
    (void) pthread_mutex_destroy(&_queueLock);
    [super dealloc];
}

- (void)terminate;
{
    [self cancel];
}

- (void)cancel;
{
    pthread_mutex_lock(&_queueLock);
    
    // objects are either pending or executing; make sure they don't call -finishedOperation
    [_currentOperations makeObjectsPerformSelector:@selector(cancel)];
    [_currentOperations removeAllObjects];
    
    pthread_mutex_unlock(&_queueLock);
}

- (void)addOperation:(FVOperation *)operation;
{
    bool execute = false;
    pthread_mutex_lock(&_queueLock);
    if ([_currentOperations containsObject:operation] == NO) {
        [_currentOperations addObject:operation];
        [operation setQueue:self];
        execute = true;
    }
    pthread_mutex_unlock(&_queueLock); 
    
    if (execute) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([operation isCancelled] == NO)
                [operation start];
        });
    }
}

- (void)addOperations:(NSArray *)operations;
{
    NSMutableSet *possibleOperations = [[NSMutableSet alloc] initWithArray:operations];
    pthread_mutex_lock(&_queueLock);
    [possibleOperations minusSet:_currentOperations];    
    if ([possibleOperations count])
        [_currentOperations unionSet:possibleOperations];
    pthread_mutex_unlock(&_queueLock);   

    if ([possibleOperations count]) {
        [possibleOperations makeObjectsPerformSelector:@selector(setQueue:) withObject:self];
        NSMutableArray *sortedOperations = [[NSMutableArray alloc] initWithArray:[possibleOperations allObjects]];
        [sortedOperations enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(id obj, NSUInteger idx, BOOL *stop){
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([obj isCancelled] == NO)
                    [obj start];
            });
            *stop = NO;
        }];
        [sortedOperations release];
    }
    [possibleOperations release];
}

- (void)setThreadPriority:(double)p;
{
    NSLog(@"*** WARNING *** %@ ignoring request to change main thread priority", self);
}

// finishedOperation: callback, typically received on the main thread
- (void)finishedOperation:(FVOperation *)anOperation;
{
    pthread_mutex_lock(&_queueLock);
    [_currentOperations removeObject:anOperation];
    pthread_mutex_unlock(&_queueLock);
}

#endif

@end
