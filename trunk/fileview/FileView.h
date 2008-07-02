//
//  FileView.h
//  FileViewTest
//
//  Created by Adam Maxwell on 06/23/07.
/*
 This software is Copyright (c) 2007-2008
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

enum {
    FVZoomInMenuItemTag      = 1001,
    FVZoomOutMenuItemTag     = 1002,
    FVQuickLookMenuItemTag   = 1003,
    FVOpenMenuItemTag        = 1004,
    FVRevealMenuItemTag      = 1005,
    FVChangeLabelMenuItemTag = 1006,
    FVDownloadMenuItemTag    = 1007,
    FVRemoveMenuItemTag      = 1008,
    FVReloadMenuItemTag      = 1009
};

@class FVSliderWindow;

@interface FileView : NSView 
{
@protected
    id                      _delegate;
    id                      _dataSource;
    id                      _controller;
    NSUInteger              _numberOfColumns;
    NSColor                *_backgroundColor;
    NSMutableIndexSet      *_selectedIndexes;
    CGLayerRef              _selectionOverlay;
    NSUInteger              _lastClickedIndex;
    NSRect                  _rubberBandRect;
    BOOL                    _isMouseDown;
    NSRect                  _dropRectForHighlight;
    NSSize                  _padding;
    NSSize                  _iconSize;
    double                  _maxScale;
    double                  _minScale;
    NSPoint                 _lastMouseDownLocInView;
    BOOL                    _isEditable;
    BOOL                    _isRescaling;
    BOOL                    _scheduledLiveResize;
    BOOL                    _isDrawingDragImage;
    CFAbsoluteTime          _timeOfLastOrigin;
    NSPoint                 _lastOrigin;
    CFMutableDictionaryRef  _trackingRectMap;
    NSButtonCell           *_leftArrow;
    NSButtonCell           *_rightArrow;
    NSRect                  _leftArrowFrame;
    NSRect                  _rightArrowFrame;
    FVSliderWindow         *_sliderWindow;
    NSTrackingRectTag       _sliderTag;
    
    id                      _selectionBinding;
    BOOL                    _isObservingSelectionIndexes;
}

// bindings compatibility, although this can be set directly
- (void)setIconURLs:(NSArray *)anArray;
- (NSArray *)iconURLs;

// this is the only way to get selection information at present
- (NSIndexSet *)selectionIndexes;
- (void)setSelectionIndexes:(NSIndexSet *)indexSet;

// bind a slider or other control to this
- (double)iconScale;
- (void)setIconScale:(double)scale;
- (double)maxIconScale;
- (void)setMaxIconScale:(double)scale;
- (double)minIconScale;
- (void)setMinIconScale:(double)scale;

- (NSUInteger)numberOfRows;
- (NSUInteger)numberOfColumns;

// must be called if the URLs provided by a datasource change, either in number or content
- (void)reloadIcons;

// default is source list color
- (void)setBackgroundColor:(NSColor *)aColor;
- (NSColor *)backgroundColor;

// actions that NSResponder doesn't declare
- (IBAction)selectPreviousIcon:(id)sender;
- (IBAction)selectNextIcon:(id)sender;
- (IBAction)delete:(id)sender;

// invalidates existing cached data for icons and marks the view for redisplay
- (void)reloadSelectedIcons:(id)sender;

// sender must implement -tag to return a valid Finder label integer (0-7); non-file URLs are ignored
- (IBAction)changeFinderLabel:(id)sender;
- (IBAction)openSelectedURLs:(id)sender;

- (BOOL)isEditable;
- (void)setEditable:(BOOL)flag;

// required for drag-and-drop support
- (void)setDataSource:(id)obj;
- (id)dataSource;

- (void)setDelegate:(id)obj;
- (id)delegate;

@end

@interface FVColumnView : FileView
@end


// Datasource must conform to this protocol.  Results are cached internally on each call to -reloadIcons, so datasource methods don't need to be incredibly efficient (and as a consequence, you should avoid gratuitous calls to -reloadIcons).
@interface NSObject (FileViewDataSource)

// Required.
- (NSUInteger)numberOfIconsInFileView:(FileView *)aFileView;
// Required.  The delegate must return an NSURL for each index < numberOfFiles.  NSNull or nil can be returned to represent a missing file.
- (NSURL *)fileView:(FileView *)aFileView URLAtIndex:(NSUInteger)anIndex;

// Optional.  String displayed below the URL name.
- (NSString *)fileView:(FileView *)aFileView subtitleAtIndex:(NSUInteger)anIndex;

@end

// datasource must implement all of these methods or dropping/rearranging will be disabled
@interface NSObject (FileViewDragDataSource)

// implement to do something (or nothing) with the dropped URLs
- (void)fileView:(FileView *)aFileView insertURLs:(NSArray *)absoluteURLs atIndexes:(NSIndexSet *)aSet;

// the datasource may replace the files at the given indexes
- (BOOL)fileView:(FileView *)aFileView replaceURLsAtIndexes:(NSIndexSet *)aSet withURLs:(NSArray *)newURLs;

// rearranging files in the view
- (BOOL)fileView:(FileView *)aFileView moveURLsAtIndexes:(NSIndexSet *)aSet toIndex:(NSUInteger)anIndex;

// does not delete the file from disk; this is the datasource's responsibility
- (BOOL)fileView:(FileView *)aFileView deleteURLsAtIndexes:(NSIndexSet *)indexSet;

@end

@interface NSObject (FileViewDelegate)

// Called immediately before display; the delegate can safely modify the menu, as a new copy is presented each time.   The anIndex parameter will be NSNotFound if there is not a URL at the mouse event location.  If you remove all items, the menu will not be shown.
- (void)fileView:(FileView *)aFileView willPopUpMenu:(NSMenu *)aMenu onIconAtIndex:(NSUInteger)anIndex;

// In addition, the delegate can be sent the WebUIDelegate method webView:contextMenuItemsForElement:defaultMenuItems: if implemented

// If unimplemented or returns YES, fileview will open the URL using NSWorkspace
- (BOOL)fileView:(FileView *)aFileView shouldOpenURL:(NSURL *)aURL;

// If unimplemented or returns nil, fileview will use a system temporary directory.  Used with FVDownloadMenuItemTag menu item.
- (NSURL *)fileView:(FileView *)aFileView downloadDestinationWithSuggestedFilename:(NSString *)filename;

@end
