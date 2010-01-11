//
//  _FVController.h
//  FileView
//
//  Created by Adam Maxwell on 3/26/08.
/*
 This software is Copyright (c) 2007-2010
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

@class FileView, FVIcon, FVOperationQueue;

@interface _FVController : NSObject
{
    id                      _dataSource;
    FileView               *_view;
    NSMutableArray         *_orderedIcons;
    NSMutableArray         *_orderedURLs;
    NSMutableArray         *_orderedSubtitles;
    CFRunLoopTimerRef       _zombieTimer;
    NSMutableDictionary    *_zombieIconCache;
    NSMutableDictionary    *_iconCache;
    CFMutableDictionaryRef  _infoTable;
    FVOperationQueue       *_operationQueue;
    BOOL                    _isBound;
    
    NSMutableArray         *_downloads;
    CFRunLoopTimerRef       _progressTimer;
}

- (id)initWithView:(FileView *)view;
- (void)setDataSource:(id)obj;

// only for binding support; may contain NSNull values
- (NSArray *)iconURLs;
- (void)setIconURLs:(NSArray *)array;
// set to YES when creating a content binding, and NO when removing the binding
- (void)setBound:(BOOL)flag;

// dependent on cached state (always consistent)
- (NSUInteger)numberOfIcons;
- (NSURL *)URLAtIndex:(NSUInteger)anIndex;  // never returns NSNull
- (FVIcon *)iconAtIndex:(NSUInteger)anIndex;
- (NSArray *)iconsAtIndexes:(NSIndexSet *)indexes;
- (NSString *)subtitleAtIndex:(NSUInteger)anIndex;

- (void)reload;

// okay to pass NULL for name or label
- (void)getDisplayName:(NSString **)name andLabel:(NSUInteger *)label forURL:(NSURL *)aURL;

- (void)cancelQueuedOperations;
- (void)enqueueReleaseOperationForIcons:(NSArray *)icons;
- (void)enqueueRenderOperationForIcons:(NSArray *)icons checkSize:(NSSize)iconSize;


- (void)downloadURLAtIndex:(NSUInteger)anIndex;
- (NSArray *)downloads;
- (void)cancelDownloads;

@end
