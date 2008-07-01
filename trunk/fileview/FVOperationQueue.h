//
//  FVOperationQueue.h
//  FileViewTest
//
//  Created by Adam Maxwell on 09/21/07.
/*
 This software is Copyright (c) 2007-2008,2008
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

#import <Cocoa/Cocoa.h>

@class FVOperation;

// Can use this to run main queue operations in a blocking mode.
FV_PRIVATE_EXTERN NSString * const FVMainQueueRunLoopMode;

@interface FVOperationQueue : NSObject

// Queue that executes -start on the main thread.  Adding operations to this queue is roughly equivalent to using +[NSObject cancelPreviousPerformRequestsWithTarget:selector:object:]/-[NSObject performSelector:withObject:afterDelay:inModes:] with kCFRunLoopCommonModes, but you can add operations from any thread.
+ (FVOperationQueue *)mainQueue;

// Designated initializer.  Returns a queue set up with default parameters.  Call -terminate before releasing the last reference to the queue or else it will leak.
- (id)init;

// Operations are coalesced using -[FVOperation isEqual:].  If you want different behavior, override -hash and isEqual: in a subclass of FVOperation.
- (void)addOperations:(NSArray *)operations;
- (void)addOperation:(FVOperation *)operation;

// Stops any pending or active operations.
- (void)cancel;

// The queue will be invalid after this call.
- (void)terminate;

// Sent after each operation's -main method completes.
- (void)finishedOperation:(FVOperation *)anOperation;

// Sets the worker thread's priority using +[NSThread setThreadPriority:].  Mainly useful for a queue that will be running non-concurrent operations.
- (void)setThreadPriority:(double)p;

@end
