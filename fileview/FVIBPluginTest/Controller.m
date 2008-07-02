//
//  Controller.m
//  FVIBPluginTest
//
//  Created by Adam Maxwell on 6/30/08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

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
