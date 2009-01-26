//
//  FVThread.h
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

#import <Cocoa/Cocoa.h>

/** @internal
 
 @brief Provides thread pooling.  
 
 Profiling with Shark indicated that a fair amount of time was wasted in pthread setup and teardown.  This is a significant hit when working with FVOperation subclasses that return YES for FVOperation::isConcurrent, since they create an ephemeral thread for icon rendering. 
 
 This class provides no benefit for threads that are long-lived, so you're better off using NSThread in that case.  If it's disturbing to see lots of threads blocking (or if you want a larger pool), use the FVThreadPoolCapacity user default to change the maximum number of threads available in the pool.  Currently the default is 14, but don't rely on that.  */
@interface FVThread : NSObject

/** @internal Performs the selector on a background thread.
 
 Essentially a cover for +[NSThread detachNewThreadSelector:toTarget:withObject:], but uses a thread from the pool if possible instead of spawning a new pthread.
 @param selector Target must respond to this selector.
 @param target The receiver of selector.
 @param argument Pass nil if the selector does not take an argument. */
+ (void)detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)argument;

@end
