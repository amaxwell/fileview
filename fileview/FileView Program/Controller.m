//
//  Controller.m
//  FileViewTest
//
//  Created by Adam Maxwell on 06/23/07.
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

#import "Controller.h"
#import "FVInvocationOperation.h"

@implementation Controller

- (id)init
{
    self = [super init];
    if (self) {
        _filePaths = [[NSMutableArray alloc] initWithCapacity:100];
    }
    return self;
}

- (void)windowWillClose:(NSNotification *)aNotification
{
    [_slider unbind:@"value"];
    [_fileView unbind:NSContentBinding];
    [_fileView unbind:NSSelectionIndexesBinding];
    [_fileView setDataSource:nil];
    [_fileView setDelegate:nil];
    _fileView = nil;
    
    [_columnView unbind:NSContentBinding];
    [_columnView unbind:NSSelectionIndexesBinding];
    [_columnView setDataSource:nil];
    [_columnView setDelegate:nil];
    _columnView = nil;
    
    [_fileViewLeft unbind:NSContentBinding];
    [_fileViewLeft unbind:NSSelectionIndexesBinding];
    [_fileViewLeft setDataSource:nil];
    [_fileViewLeft setDelegate:nil];
    _fileViewLeft = nil;
}

- (void)selectAndSort
{
    [arrayController setSelectionIndex:5];
    NSSortDescriptor *sort = [[[NSSortDescriptor alloc] initWithKey:@"path" ascending:YES] autorelease];
    [arrayController setSortDescriptors:[NSArray arrayWithObject:sort]];    
}

- (void)awakeFromNib
{
    NSString *base = [@"~/Desktop" stringByStandardizingPath];
#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
    NSArray *files = [[NSFileManager defaultManager] directoryContentsAtPath:base];
#else
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL];
#endif
    NSString *path;
    NSUInteger i, iMax = [files count];
    for (i = 0; i < iMax; i++) {
        path = [files objectAtIndex:i];
        if ([path hasPrefix:@"."] == NO)
            [arrayController addObject:[NSURL fileURLWithPath:[base stringByAppendingPathComponent:path]]];
    }
    
    NSUInteger insertIndex = floor([(NSArray *)[arrayController arrangedObjects] count] / 2);

    [arrayController insertObject:[NSNull null] atArrangedObjectIndex:insertIndex++];
    [arrayController insertObject:[NSURL URLWithString:@"http://www.macintouch.com/"] atArrangedObjectIndex:insertIndex++];
    [arrayController insertObject:[NSURL URLWithString:@"http://bibdesk.sf.net/"] atArrangedObjectIndex:insertIndex++];
    // direct link to PDF file
    [arrayController insertObject:[NSURL URLWithString:@"http://www-chaos.engr.utk.edu/pap/crg-aiche2000daw-paper.pdf"] atArrangedObjectIndex:insertIndex++];
    [arrayController insertObject:[NSURL URLWithString:@"http://dx.doi.org/10.1023/A:1018361121952"] atArrangedObjectIndex:insertIndex++];
    [arrayController insertObject:[NSURL URLWithString:@"http://searchenginewatch.com/_static/example1.html"] atArrangedObjectIndex:insertIndex++];
    [arrayController insertObject:[NSURL URLWithString:@"http://dx.doi.org/10.1016/j.scitotenv.2008.12.012"] atArrangedObjectIndex:insertIndex++];
    
    // server redirect; shows up as blank white page without workaround in FVWebViewIcon.m
    [arrayController insertObject:[NSURL URLWithString:@"http://dx.doi.org/10.1175/1520-0426(2003)20%3C730:AACEAF%3E2.0.CO;2"] atArrangedObjectIndex:insertIndex++];
    
    // this scheme is seldom (if ever) defined by any app; the delegate implementation demonstrates opening them
    [arrayController insertObject:[NSURL URLWithString:@"doi:10.2112/06-0677.1"] atArrangedObjectIndex:insertIndex++];
    [arrayController insertObject:[NSURL URLWithString:@"mailto:amaxwell@users.sourceforge.net"] atArrangedObjectIndex:insertIndex++];
    
    [arrayController insertObject:[NSURL URLWithString:@"http://192.168.0.1"] atArrangedObjectIndex:insertIndex++];
    
    // nonexistent domain
    [arrayController insertObject:[NSURL URLWithString:@"http://bibdesk.sourceforge.tld/"] atArrangedObjectIndex:insertIndex++];
    
    // redirects to PDF file
    [arrayController insertObject:[NSURL URLWithString:@"http://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=191466"] atArrangedObjectIndex:insertIndex++];
    
    [arrayController insertObject:[NSURL URLWithString:@"http://link.aps.org/doi/10.1103/PhysRevA.33.1141"] atArrangedObjectIndex:insertIndex++];
    
    [arrayController insertObject:[NSURL URLWithString:@"file://localhost/Library/Keychains/System.keychain"] atArrangedObjectIndex:insertIndex++];
    NSString *keychainApplication = [[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:@"com.apple.keychainaccess"];
    NSString *keychainUTI = [(id)UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, CFSTR("keychain"), NULL) autorelease];
    if (keychainUTI)
        [FileView useImage:[[NSWorkspace sharedWorkspace] iconForFile:keychainApplication] forUTI:keychainUTI];
    
#pragma unused(insertIndex)

    [_fileView bind:NSContentBinding toObject:arrayController withKeyPath:@"arrangedObjects" options:nil];
    [_fileView bind:NSSelectionIndexesBinding toObject:arrayController withKeyPath:NSSelectionIndexesBinding options:nil];
    
    // for optional datasource method
    [_fileView setDataSource:self];
    [_fileView setEditable:YES];
    [_fileView setDelegate:self];
    
    [_columnView bind:NSContentBinding toObject:arrayController withKeyPath:@"arrangedObjects" options:nil];
    [_columnView bind:NSSelectionIndexesBinding toObject:arrayController withKeyPath:NSSelectionIndexesBinding options:nil];
    [_columnView setDataSource:self];
    [_columnView setEditable:YES];
    [_columnView setDelegate:self];
    
    [_fileViewLeft bind:NSContentBinding toObject:arrayController withKeyPath:@"arrangedObjects" options:nil];
    [_fileViewLeft bind:NSSelectionIndexesBinding toObject:arrayController withKeyPath:NSSelectionIndexesBinding options:nil];
    [_fileViewLeft setDataSource:self];
    [_fileViewLeft setEditable:YES];
    [_fileViewLeft setDelegate:self];

}

- (void)dealloc
{
    [_filePaths release];
    [super dealloc];
}

- (NSUInteger)numberOfIconsInFileView:(FileView *)aFileView { return 0; }
- (NSURL *)fileView:(FileView *)aFileView URLAtIndex:(NSUInteger)idx { return nil; }

- (BOOL)fileView:(FileView *)aFileView moveURLsAtIndexes:(NSIndexSet *)aSet toIndex:(NSUInteger)anIndex;
{
    NSArray *toMove = [[[arrayController arrangedObjects] objectsAtIndexes:aSet] copy];
    // reduce idx by the number of smaller indexes in aSet
    if (anIndex > 0) {
        NSRange range = NSMakeRange(0, anIndex);
        NSUInteger *buffer = NSZoneMalloc(NULL, anIndex);
        anIndex -= [aSet getIndexes:buffer maxCount:anIndex inIndexRange:&range];
        NSZoneFree(NULL, buffer);
    }
    [arrayController removeObjectsAtArrangedObjectIndexes:aSet];
    aSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(anIndex, [aSet count])];
    [arrayController insertObjects:toMove atArrangedObjectIndexes:aSet];
    [toMove release];
    return YES;
}    

- (BOOL)fileView:(FileView *)fileView replaceURLsAtIndexes:(NSIndexSet *)aSet withURLs:(NSArray *)newURLs;
{
    if ([_filePaths count] > [aSet count]) {
        [arrayController removeObjectsAtArrangedObjectIndexes:aSet];
        [arrayController insertObjects:newURLs atArrangedObjectIndexes:aSet];
        return YES;
    }
    return NO;
}

- (BOOL)fileView:(FileView *)fileView deleteURLsAtIndexes:(NSIndexSet *)indexes;
{
    if ([_filePaths count] >= [indexes count]) {
        [arrayController removeObjectsAtArrangedObjectIndexes:indexes];
        return YES;
    }
    return NO;
}

- (void)fileView:(FileView *)aFileView insertURLs:(NSArray *)absoluteURLs atIndexes:(NSIndexSet *)aSet;
{
    [arrayController insertObjects:absoluteURLs atArrangedObjectIndexes:aSet];
}

- (NSString *)fileView:(FileView *)aFileView subtitleAtIndex:(NSUInteger)anIndex;
{
    return [NSString stringWithFormat:@"Check pq for %tu", anIndex];
}

- (void)fileView:(FileView *)aFileView willPopUpMenu:(NSMenu *)aMenu onIconAtIndex:(NSUInteger)anIndex;
{
    if ([aFileView isDescendantOf:_tabView]) {
        [aMenu addItem:[NSMenuItem separatorItem]];
        NSString *title = aFileView == _fileViewLeft ? @"Single Column Layout" : @"Multicolumn Layout";
        SEL action = aFileView == _fileViewLeft ? @selector(selectPreviousTabViewItem:) : @selector(selectNextTabViewItem:);
        NSMenuItem *item = [[NSMenuItem allocWithZone:[aMenu zone]] initWithTitle:title action:action keyEquivalent:@""];
        [item setTarget:_tabView];
        [aMenu addItem:item];
        [item release];
    }
}

- (BOOL)fileView:(FileView *)aFileView shouldOpenURL:(NSURL *)aURL
{
    if ([[aURL scheme] caseInsensitiveCompare:@"doi"] == NSOrderedSame) {
        // DOI manual says this is a safe URL to resolve with for the foreseeable future
        NSURL *baseURL = [NSURL URLWithString:@"http://dx.doi.org/"];
        // remove any text prefix, which is not required for a valid DOI, but may be present; DOI starts with "10"
        // http://www.doi.org/handbook_2000/enumeration.html#2.2
        NSString *path = [aURL resourceSpecifier];
        NSRange range = [path rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]];
        if(range.length && range.location > 0)
            path = [path substringFromIndex:range.location];
        aURL = [NSURL URLWithString:path relativeToURL:baseURL];
        
        // if we could create a new URL and NSWorkspace can open it, return NO so the view doesn't try
        if (aURL && [[NSWorkspace sharedWorkspace] openURL:aURL])
            return NO;
    }
    // let the view handle it
    return YES;
}

@end

#if (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5)

#import <objc/runtime.h>

@interface NSSplitView (FileViewFixes)
- (void)_fv_replacementMouseDown:(NSEvent *)theEvent;
@end

@implementation NSSplitView (FileViewFixes)

static IMP originalMouseDown = NULL;

+ (void)load
{
    Method m = class_getInstanceMethod(self, @selector(mouseDown:));
    IMP replacementMouseDown = class_getMethodImplementation(self, @selector(_fv_replacementMouseDown:));
    originalMouseDown = method_setImplementation(m, replacementMouseDown);
}

- (void)_fv_replacementMouseDown:(NSEvent *)theEvent;
{
    BOOL inDivider = NO;
    NSPoint mouseLoc = [self convertPoint:[theEvent locationInWindow] fromView:nil];
    NSArray *subviews = [self subviews];
    NSInteger i, count = [subviews count];
    id view;
    NSRect divRect;
    
    for (i = 0; i < count - 1; i++) {
        view = [subviews objectAtIndex:i];
        divRect = [view frame];
        if ([self isVertical]) {
            divRect.origin.x = NSMaxX(divRect);
            divRect.size.width = [self dividerThickness];
        } else {
            divRect.origin.y = NSMaxY(divRect);
            divRect.size.height = [self dividerThickness];
        }
        
        if (NSMouseInRect(mouseLoc, divRect, [self isFlipped])) {
            inDivider = YES;
            break;
        }
    }
    
    if (inDivider) {
        originalMouseDown(self, _cmd, theEvent);
    } else {
        [[self nextResponder] mouseDown:theEvent];
    }
}

@end

#else

@interface PosingSplitView : NSSplitView
@end

@implementation PosingSplitView

+ (void)load
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    [self poseAsClass:NSClassFromString(@"NSSplitView")];
    [pool release];
}

- (void)mouseDown:(NSEvent *)theEvent {
    BOOL inDivider = NO;
    NSPoint mouseLoc = [self convertPoint:[theEvent locationInWindow] fromView:nil];
    NSArray *subviews = [self subviews];
    NSInteger i, count = [subviews count];
    id view;
    NSRect divRect;
    
    for (i = 0; i < count - 1; i++) {
        view = [subviews objectAtIndex:i];
        divRect = [view frame];
        if ([self isVertical]) {
            divRect.origin.x = NSMaxX(divRect);
            divRect.size.width = [self dividerThickness];
        } else {
            divRect.origin.y = NSMaxY(divRect);
            divRect.size.height = [self dividerThickness];
        }
        
        if (NSMouseInRect(mouseLoc, divRect, [self isFlipped])) {
            inDivider = YES;
            break;
        }
    }
    
    if (inDivider) {
        [super mouseDown:theEvent];
    } else {
        [[self nextResponder] mouseDown:theEvent];
    }
}

@end

#endif
