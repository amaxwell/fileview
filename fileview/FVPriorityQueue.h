//
//  FVPriorityQueue.h
//  FileView
//
//  Created by Adam Maxwell on 2/9/08.
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

#import <Cocoa/Cocoa.h>

/* 
 Objects are ordered in the queue by priority, as determined by the result of compare: as follows:
 
 if ([value1 compare:value2] == NSOrderedDescending), value1 has higher priority
 if ([value1 compare:value2] == NSOrderedAscending), value2 has higher priority
  
 A twist on usual queue behavior is that duplicate objects (as determined by -[NSObject isEqual:]) are not added to the queue in push:, but are silently ignored.  This allows easy maintenance of a unique set of objects in the priority queue.  Note that -hash must be implemented correctly for any objects that override -isEqual:, and the value of -hash for a given object must not change while the object is in the queue.
 
 Thanks to Mike Ash for demonstrating how to use std::make_heap.
 http://www.mikeash.com/?page=pyblog/using-evil-for-good.html
 
 */

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)
@interface FVPriorityQueue : NSObject <NSFastEnumeration>
#else
@interface FVPriorityQueue : NSObject
#endif
{
@private;
    CFMutableSetRef  _set;
    id              *_values;
    NSUInteger       _count;
    NSUInteger       _capacity;
    long unsigned    _mutations;
    BOOL             _madeHeap;
    BOOL             _sorted;
}

- (id)init;

// returns the highest priority item; if several items have highest priority, returns any of those items
- (id)pop;
- (void)push:(id)object;

// semantically equivalent to for(object in objects){ [queue push:object]; }
- (void)pushMultiple:(NSArray *)objects;

// returned in descending priority (high priority objects returned first)
- (NSEnumerator *)objectEnumerator;

// performed in order of descending priority
- (void)makeObjectsPerformSelector:(SEL)selector;

// manipulate the elements directly
- (NSUInteger)count;
- (void)removeAllObjects;

@end

typedef void (*FVPriorityQueueApplierFunction)(const void *value, void *context);
FV_PRIVATE_EXTERN void FVPriorityQueueApplyFunction(FVPriorityQueue *theSet, FVPriorityQueueApplierFunction applier, void *context);
