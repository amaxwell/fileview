//
//  FVScaledImageView.h
//  FileView
//
//  Created by Adam Maxwell on 09/22/07.
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

#import <Cocoa/Cocoa.h>

@class FVIcon;

/** @internal @brief Simple FVIcon view.
 
 This view is used for displaying an FVIcon as an image, filling the frame proportionately, or as an icon with a text description of the file along with it. */
 
@interface FVScaledImageView : NSView
{
@private
    FVIcon             *_icon;
    NSURL              *_fileURL;
    NSAttributedString *_text;
}

/** @internal @brief Display as icon with details.
 
 Loads an FVIcon for the given file: URL, along with attributes of the file.  This method does not redraw or mark the view as needing display.
 @param aURL A file: URL */
- (void)displayIconForURL:(NSURL *)aURL;

/** @internal @brief Display an image using FVIcon.
 
 Loads an FVIcon for the given URL, without details of the file.  May be used for other URL schemes, including those that aren't handled by the URL loading system.  This method does not redraw or mark the view as needing display.
 @param aURL Any URL */
- (void)displayImageAtURL:(NSURL *)aURL;

@end
