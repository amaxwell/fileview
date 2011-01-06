//
//  FVMovieIcon.m
//  FileView
//
//  Created by Adam Maxwell on 2/22/08.
/*
 This software is Copyright (c) 2007-2011
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

#import "FVMovieIcon.h"
#import "FVFinderIcon.h"
#import "FVAllocator.h"
#import "FVOperationQueue.h"
#import "FVInvocationOperation.h"

#import <QTKit/QTKit.h>

@implementation FVMovieIcon

/*
 QTMovie can't be used from multiple threads simultaneously, since the underlying C functions apparently aren't thread safe.  Deallocation in particular seems to crash.  In addition, Christiaan found a case where a QT component tried to display a window and ended up trying to run NSApp in a modal session from a thread.  While modal windows are supposed to work from a thread, it appeared to cause a crash in some Carbon window drawing code.
 
 If performance problems are evident, we could just use Quick Look for thumbnailing movies, but I don't see any problems dropping ~200 movies on the test program window.
 
 Note: QTKit on 10.5 has enterQTKitOnThread/exitQTKitOnThread, which might be worth investigating as well.  Another note: enterQTKitOnThread does not seem to help, even locking beforehand so multiple threads aren't calling it simultaneously.  Trying to load certain wmv files causes it to crash very reliably.
 
 */

- (NSData *)_copyTIFFDataFromMovie
{
    NSAssert2(pthread_main_np() != 0, @"*** threading violation *** +[%@ %@] requires main thread", self, NSStringFromSelector(_cmd));
    NSMutableDictionary *attributes = [NSMutableDictionary new];
    [attributes setObject:_fileURL forKey:QTMovieURLAttribute];
    
    // Loading /DevTools/Documentation/DocSets/com.apple.ADC_Reference_Library.CoreReference.docset/Contents/Resources/Documents/documentation/QuickTime/REF/Effects/gradwip2.mov puts up a stupid modal dialog about searching for resources /after/ blocking for a long time.
    [attributes setObject:[NSNumber numberWithBool:NO] forKey:QTMovieResolveDataRefsAttribute];
    
    // QTMovieResolveDataRefsAttribute = NO probably implies QTMovieAskUnresolvedDataRefsAttribute = NO ...
    [attributes setObject:[NSNumber numberWithBool:NO] forKey:QTMovieAskUnresolvedDataRefsAttribute];
        
    // failed atttempt to stop Flip4Mac from putting up a progress bar during loads
    [attributes setObject:[NSNumber numberWithBool:YES] forKey:QTMovieDontInteractWithUserAttribute];
    
    QTMovie *movie = [[QTMovie alloc] initWithAttributes:attributes error:NULL];
    [attributes release];
    
    // Is poster time something the movie producer sets?  Always zero on my tests, which is typically a black screen.  Quick Look uses some non-zero time, but it doesn't seem to be a fixed percentage.
    QTTime movieTime = [[movie attributeForKey:QTMovieDurationAttribute] QTTimeValue];
    NSValue *timeValue = [movie attributeForKey:QTMovieCurrentTimeAttribute];
    if (nil == timeValue || QTTimeCompare(QTZeroTime, [timeValue QTTimeValue]) == NSOrderedSame)
        timeValue = [movie attributeForKey:QTMoviePosterTimeAttribute];
    
    QTTime timeToGet = QTZeroTime;
    if (timeValue && QTTimeCompare(QTZeroTime, [timeValue QTTimeValue]) == NSOrderedSame) {
        // 4% or 10 seconds, whichever is smaller
        NSTimeInterval frameTime = MIN((movieTime.timeValue / movieTime.timeScale) * 0.04, 10);
        timeToGet = QTMakeTimeWithTimeInterval(frameTime);
    }
    NSData *data = [[[movie frameImageAtTime:timeToGet] TIFFRepresentation] retain];
    [movie release];    
    
    return data;
}

+ (BOOL)canInitWithURL:(NSURL *)url;
{
    return [QTMovie canInitWithURL:url];
}

- (BOOL)canReleaseResources;
{
    return NULL != _fullImage;
}

// object is locked while this is called, so we can manipulate ivars
- (CFDataRef)_copyDataForImageSourceWhileLocked
{
    NSAssert2([self tryLock] == NO, @"*** threading violation *** -[%@ %@] requires caller to lock self", [self class], NSStringFromSelector(_cmd));
    
    FVInvocationOperation *op;
    op = [[FVInvocationOperation alloc] initWithTarget:self selector:@selector(_copyTIFFDataFromMovie) object:nil];
    [op setConcurrent:NO];
    [[FVOperationQueue mainQueue] addOperation:op];
    while (NO == [op isFinished])
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, TRUE);
    
    CFDataRef data = (CFDataRef)[op retainedResult];
    // result isn't owned by the operation, but the containing invocation is
    [op release];

    // superclass will cache the resulting images to disk unconditionally, in order to avoid hitting the main thread again
    return data;        
}

@end
