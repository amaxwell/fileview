//
//  Controller.m
//  FVIBPluginTest
//
//  Created by Adam Maxwell on 6/30/08.
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

- (id)init
{
    self = [super init];
    if (self) {
        _iconURLs = [NSMutableArray new];
        
        NSURL *picturesURL = nil;
        FSRef fileRef;
        if (noErr == FSFindFolder(kOnSystemDisk, kDesktopPicturesFolderType, FALSE, &fileRef))
            picturesURL = [(id)CFURLCreateFromFSRef(NULL, &fileRef) autorelease];
        
        NSString *base = [@"~/Desktop" stringByStandardizingPath];
        if (nil != picturesURL && [[NSFileManager defaultManager] fileExistsAtPath:[[picturesURL path] stringByAppendingPathComponent:@"Plants"] isDirectory:NULL])
            base = [[picturesURL path] stringByAppendingPathComponent:@"Plants"];
        
        NSMutableArray *files = [[[[NSFileManager defaultManager] directoryContentsAtPath:base] mutableCopy] autorelease];
        NSUInteger iMax, i = [files count];
        while (i--) {
            if ([[files objectAtIndex:i] hasPrefix:@"."])
                [files removeObjectAtIndex:i];
        }
        
        NSString *path;
        iMax = [files count];
        for (i = 0; i < iMax; i++) {
            path = [files objectAtIndex:i];
            [_iconURLs addObject:[NSURL fileURLWithPath:[base stringByAppendingPathComponent:path]]];
        }              
    }
    return self;
}

- (void)dealloc
{
    [_iconURLs release];
    [super dealloc];
}

- (NSUInteger)numberOfIconsInFileView:(FileView *)aFileView { return 0; }
- (NSURL *)fileView:(FileView *)aFileView URLAtIndex:(NSUInteger)anIndex { return nil; }

- (NSString *)fileView:(FileView *)aFileView subtitleAtIndex:(NSUInteger)anIndex;
{
    return [NSString stringWithFormat:@"Subtitle %d", anIndex];
}

@end
