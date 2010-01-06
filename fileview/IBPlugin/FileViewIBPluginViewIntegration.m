//
//  FileViewIBPluginView.m
//  FileViewIBPlugin
//
//  Created by Adam Maxwell on 6/25/08.
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

#import <InterfaceBuilderKit/InterfaceBuilderKit.h>
#import <FileView/FileView.h>
#import "FileViewIBPluginInspector.h"

@interface FVIBPluginDataSource : NSObject
{
    NSMutableArray *_iconURLs;
}
+ (id)sharedDataSource;
@end


@implementation FileView ( FileViewIBPluginView )

// doesn't work correctly in IB, and not needed anyway
- (BOOL)_showsSlider { return NO; }

- (void)ibDidAddToDesignableDocument:(IBDocument *)document; 
{
    [super ibDidAddToDesignableDocument:document];
    
    // set a datasource so we display something
    if ([[self dataSource] isEqual:[FVIBPluginDataSource sharedDataSource]] == NO)
        [self setDataSource:[FVIBPluginDataSource sharedDataSource]];    
}

- (void)ibDidRemoveFromDesignableDocument:(IBDocument *)document;
{
    [super ibDidRemoveFromDesignableDocument:document];
    [self setDataSource:nil];
}

- (void)ibPopulateKeyPaths:(NSMutableDictionary *)keyPaths {
    [super ibPopulateKeyPaths:keyPaths];
	
    [[keyPaths objectForKey:IBAttributeKeyPaths] addObjectsFromArray:[NSArray arrayWithObjects:@"backgroundColor", @"iconScale", @"editable", NSSelectionIndexesBinding, @"minIconScale", @"maxIconScale", nil]];
}

- (void)ibPopulateAttributeInspectorClasses:(NSMutableArray *)classes {
    [super ibPopulateAttributeInspectorClasses:classes];
    [classes addObject:[FileViewIBPluginInspector class]];
}

// for inspector controls
- (BOOL)fv_ibIsGridView { return YES; }

@end

@implementation FVColumnView ( FileViewIBPluginView )

- (void)ibPopulateKeyPaths:(NSMutableDictionary *)keyPaths {
    [super ibPopulateKeyPaths:keyPaths];
	
    [[keyPaths objectForKey:IBAttributeKeyPaths] removeObject:@"iconScale"];
    [[keyPaths objectForKey:IBAttributeKeyPaths] removeObject:@"minIconScale"];
    [[keyPaths objectForKey:IBAttributeKeyPaths] removeObject:@"maxIconScale"];
}

// for inspector controls
- (BOOL)fv_ibIsGridView { return NO; }

@end

#pragma mark -

@implementation FVIBPluginDataSource

+ (id)sharedDataSource
{
    static id sharedDataSource = nil;
    if (nil == sharedDataSource)
        sharedDataSource = [[self alloc] init];
    return sharedDataSource;
}

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
        
        NSMutableArray *files = [[[[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL] mutableCopy] autorelease];
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

- (NSUInteger)numberOfIconsInFileView:(FileView *)aFileView { return [_iconURLs count]; }
- (NSURL *)fileView:(FileView *)aFileView URLAtIndex:(NSUInteger)idx { return [_iconURLs objectAtIndex:idx]; }

- (NSString *)fileView:(FileView *)aFileView subtitleAtIndex:(NSUInteger)anIndex;
{
    return [NSString stringWithFormat:@"Subtitle %d", anIndex];
}

// implement editing methods so we don't get an exception when clicking the "editable" checkbox
- (void)fileView:(FileView *)aFileView insertURLs:(NSArray *)absoluteURLs atIndexes:(NSIndexSet *)aSet;
{
    
}
- (BOOL)fileView:(FileView *)aFileView replaceURLsAtIndexes:(NSIndexSet *)aSet withURLs:(NSArray *)newURLs; { return NO; }
- (BOOL)fileView:(FileView *)aFileView moveURLsAtIndexes:(NSIndexSet *)aSet toIndex:(NSUInteger)anIndex; { return NO; }
- (BOOL)fileView:(FileView *)aFileView deleteURLsAtIndexes:(NSIndexSet *)indexSet; { return NO; }

@end
