//
//  FileViewIBPluginInspector.m
//  FileViewIBPlugin
//
//  Created by Adam Maxwell on 6/25/08.
/*
 This software is Copyright (c) 2008-2013
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

#import "FileViewIBPluginInspector.h"

@class FileView;

@interface NSObject (PluginExtensions)
+ (NSColor *)defaultBackgroundColor;
@end

@implementation FileViewIBPluginInspector

- (NSString *)viewNibName {
	return @"FileViewIBPluginInspector";
}

- (NSString *)label { return @"FileView"; }

- (IBAction)resetBackgroundColor:(id)sender;
{
    id selectedView = [self valueForKeyPath:@"inspectedObjectsController.selection.self"];
    NSColor *defaultColor = [[[selectedView class] self] performSelector:@selector(defaultBackgroundColor)];
    [selectedView setBackgroundColor:defaultColor];
}

- (void)refresh {
	// Synchronize your inspector's content view with the currently selected objects.
	[super refresh];
    
    id selectedView = [self valueForKeyPath:@"inspectedObjectsController.selection.self"];
    if ([[[selectedView class] self] respondsToSelector:@selector(defaultBackgroundColor)] == NO) {
        [resetColorButton setEnabled:NO];
        NSLog(@"*** ERROR *** %@ no longer implements +defaultBackgroundColor and %@ needs it", [[selectedView class] self], [self class]);
    }
}

@end

