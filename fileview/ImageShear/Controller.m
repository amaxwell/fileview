//
//  Controller.m
//  ImageShear
//
//  Created by Adam Maxwell on 3/10/08.
/*
 This software is Copyright (c) 2008-2011
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

#import "Controller.h"

@implementation Controller

- (void)awakeFromNib
{    
    [_popup removeAllItems];
    
    // add all images from the desktop directory to the popup
    NSString *desktopDir = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) lastObject];
    NSArray *allFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:desktopDir error:NULL];
    allFiles = [allFiles sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    
    NSArray *supportedTypes = [(NSArray *)CGImageSourceCopyTypeIdentifiers() autorelease];
    
    for (NSString *path in allFiles) {
        path = [desktopDir stringByAppendingPathComponent:path];
        NSString *type = [[NSWorkspace sharedWorkspace] typeOfFile:path error:NULL];
        // eliminate PDF since CGImageSource lies about support!
        if (type && [supportedTypes containsObject:type] && UTTypeEqual((CFStringRef)type, kUTTypePDF) == FALSE) {
            [_popup addItemWithTitle:[path lastPathComponent]];
            [[_popup lastItem] setRepresentedObject:path];
        }
    }
    
    // select and display the last object
    [_popup selectItem:[_popup lastItem]];
    [self changeImage:_popup];
}

- (IBAction)changeImage:(id)sender;
{
    NSString *path = [[[sender selectedItem] representedObject] stringByStandardizingPath];
    CGImageSourceRef src = path ? CGImageSourceCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path], NULL) : NULL;
    CGImageRef originalImage = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src) CFRelease(src);
    [_imageView setNewImage:originalImage];
    CGImageRelease(originalImage);
}

@end

