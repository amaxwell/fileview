//
//  FVMovieIcon.m
//  FileView
//
//  Created by Adam Maxwell on 2/22/08.
/*
 This software is Copyright (c) 2007-2013
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
#import <AVFoundation/AVFoundation.h>

@implementation FVMovieIcon

+ (BOOL)canInitWithUTI:(NSString *)theUTI;
{
    // no AVURLAsshat before 10.7
    return floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_6 && [[AVURLAsset audiovisualTypes] containsObject:(id)theUTI];
}

- (BOOL)canReleaseResources;
{
    return NULL != _fullImage;
}

// object is locked while this is called, so we can manipulate ivars
- (CFDataRef)_copyDataForImageSourceWhileLocked
{
    NSAssert2([self tryLock] == NO, @"*** threading violation *** -[%@ %@] requires caller to lock self", [self class], NSStringFromSelector(_cmd));

    AVURLAsset *ass = [[AVURLAsset alloc] initWithURL:_fileURL options:nil];
    CMTime tm = CMTimeMultiplyByFloat64([ass duration], 0.04);
    AVAssetImageGenerator *assGen = [[AVAssetImageGenerator alloc] initWithAsset:ass];
    [ass release];
    CGImageRef cgImage = [assGen copyCGImageAtTime:tm actualTime:NULL error:NULL];
    [assGen release];
    
    CFMutableDataRef data = NULL;
    if (cgImage) {
        data = CFDataCreateMutable(CFAllocatorGetDefault(), 0);
        CGImageDestinationRef dest = CGImageDestinationCreateWithData(data, kUTTypeTIFF, 1, NULL);
        CGImageDestinationAddImage(dest, cgImage, NULL);
        CFRelease(cgImage);
        CGImageDestinationFinalize(dest);
        if (dest) CFRelease(dest);
    }
    
    // superclass will cache the resulting images to disk unconditionally, in order to avoid hitting the main thread again
    return data;
}

@end
