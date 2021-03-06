//
//  FileView.m
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

#import <FileView/FileView.h>
#import <FileView/FVFinderLabel.h>
#import <FileView/FVPreviewer.h>

#import <WebKit/WebKit.h>

#import "FVIcon.h"
#import "FVArrowButtonCell.h"
#import "FVUtilities.h"
#import "FVDownload.h"
#import "FVSlider.h"
#import "FVColorMenuView.h"
#import "_FVController.h"

/*
 Forward declarations to allow compilation on 10.5.  Note: the private Quick Look UI framework
 on 10.5 has a significantly different interface, so it would be fairly difficult to adapt it
 to use that (aside from the fact that using private frameworks crosses the line for me).
*/
#if MAC_OS_X_VERSION_MAX_ALLOWED <= MAC_OS_X_VERSION_10_5
@class QLPreviewPanel;
@protocol QLPreviewItem;
@interface NSObject (QLPreviewPanelDummy)

+ (id)sharedPreviewPanel;
- (void)updateController;
- (void)refreshCurrentPreviewItem;
- (void)reloadData;

@end
#endif


@interface FileView (Private)

// only declare methods here to shut the compiler up if we can't rearrange
- (FVIcon *)_cachedIconForURL:(NSURL *)aURL;
- (NSSize)_defaultPaddingForScale:(CGFloat)scale;
- (void)_recalculateGridSize;
- (BOOL)_getGridRow:(NSUInteger *)rowIndex column:(NSUInteger *)colIndex ofIndex:(NSUInteger)anIndex;
- (void)_getRangeOfRows:(NSRange *)rowRange columns:(NSRange *)columnRange inRect:(NSRect)aRect;
- (NSUInteger)_indexForGridRow:(NSUInteger)rowIndex column:(NSUInteger)colIndex;
- (void)_showArrowsForIconAtIndex:(NSUInteger)anIndex;
- (void)_hideArrows;
- (BOOL)_showsSlider;
- (void)_reloadIconsAndController:(BOOL)shouldReloadController;
- (void)_previewURLs:(NSArray *)iconURLs;
- (void)_previewURL:(NSURL *)aURL forIconInRect:(NSRect)iconRect;
- (NSArray *)_selectedURLs;

@end

// note: extend the bitfield in _fvFlags when adding enumerates
enum {
    FVDropNone   = 0,
    FVDropOnIcon = 1,
    FVDropOnView = 2,
    FVDropInsert = 3
};
typedef NSUInteger FVDropOperation;

// sets the default cursor for drop operations; originally NSDragOperationLink
#define DEFAULT_DROP_OPERATION NSDragOperationGeneric

#define DEFAULT_ICON_SIZE ((NSSize) { 64, 64 })
#define DEFAULT_PADDING   ((CGFloat) 32)         // 16 per side
#define MINIMUM_PADDING   ((CGFloat) 10)
#define MARGIN_BASE       ((CGFloat) 10)

#define DROP_MESSAGE_MIN_FONTSIZE ((CGFloat) 8.0)
#define DROP_MESSAGE_MAX_INSET    ((CGFloat) 20.0)

#define INSERTION_HIGHLIGHT_WIDTH ((CGFloat) 6.0)

// set to 1 to get legacy behavior of spacebar; habit from Finder is killing me
#define FV_SPACE_SCROLLS 0

// draws grid and margin frames
#define DEBUG_GRID 0

static Class         QLPreviewPanelClass = Nil;

// KVO context pointers (pass address): http://lists.apple.com/archives/cocoa-dev/2008/Aug/msg02471.html
static char _FVInternalSelectionObserverContext;
static char _FVSelectionBindingToControllerObserverContext;
static char _FVContentBindingToControllerObserverContext;

@interface _FVBinding : NSObject
{
@public
    id            _observable;
    NSString     *_keyPath;
    NSDictionary *_options;
}
- (id)initWithObservable:(id)observable keyPath:(NSString *)keyPath options:(NSDictionary *)options;
@end

#pragma mark -

@implementation FileView

+ (void)initialize 
{
    FVINITIALIZE(FileView);
        
    [self exposeBinding:@"iconScale"];
    [self exposeBinding:NSContentBinding];
    [self exposeBinding:NSSelectionIndexesBinding];
    [self exposeBinding:@"backgroundColor"];
    [self exposeBinding:@"maxIconScale"];
    [self exposeBinding:@"minIconScale"];
    
    // even without loading the framework on 10.5, this returns a class
    QLPreviewPanelClass = Nil;
#if defined(MAC_OS_X_VERSION_10_6) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_5) 
        QLPreviewPanelClass = NSClassFromString(@"QLPreviewPanel");
#endif
    
    // Hidden pref; 10.7 and later http://mjtsai.com/blog/2012/03/12/qlenabletextselection/
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"QLEnableTextSelection"];
}

+ (NSColor *)defaultBackgroundColor
{    
#ifndef NSAppKitVersionNumber10_6
#define NSAppKitVersionNumber10_6 1038
#endif
    
    // !!! early return for 10.7 and later to deal with gradient colors
    if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_6)
        return nil;
    
    NSColor *color = nil;

    // Magic source list color: http://lists.apple.com/archives/cocoa-dev/2008/Jun/msg02138.html
    if ([NSOutlineView instancesRespondToSelector:@selector(setSelectionHighlightStyle:)]) {
        NSOutlineView *outlineView = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0,0,1,1)];
        [outlineView setSelectionHighlightStyle:NSTableViewSelectionHighlightStyleSourceList];
        color = [[[outlineView backgroundColor] retain] autorelease];
        [outlineView release];
    }
    else {
        // from Mail.app on 10.4
        CGFloat red = (231.0f/255.0f), green = (237.0f/255.0f), blue = (246.0f/255.0f);
        color = [[NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0] colorUsingColorSpaceName:NSDeviceRGBColorSpace];
    }
    return color;
}

+ (BOOL)accessInstanceVariablesDirectly { return NO; }

+ (void)useImage:(NSImage *)image forUTI:(NSString *)type { [FVIcon useImage:image forUTI:type]; }

// always returns a new instance, so declare as mutable for internal usage and avoid copies
- (NSMutableDictionary *)_titleAttributes
{
    NSMutableDictionary *ta = [NSMutableDictionary dictionary];
    [ta setObject:[NSFont systemFontOfSize:12.0] forKey:NSFontAttributeName];
    // magic color for dark mode
    NSColor *fgColor = [NSColor respondsToSelector:@selector(labelColor)] ? [NSColor labelColor] : [NSColor darkGrayColor];
    [ta setObject:fgColor forKey:NSForegroundColorAttributeName];
    NSMutableParagraphStyle *ps = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    // Apple uses this in IKImageBrowserView
    [ps setLineBreakMode:NSLineBreakByTruncatingTail];
    [ps setAlignment:NSCenterTextAlignment];
    [ta setObject:ps forKey:NSParagraphStyleAttributeName];
    [ps release];

    return ta;
}

- (NSDictionary *)_labeledAttributes
{
    NSMutableDictionary *ta = [self _titleAttributes];
    [ta setObject:[NSColor blackColor] forKey:NSForegroundColorAttributeName];
    return ta;
}

- (NSDictionary *)_subtitleAttributes
{
    NSMutableDictionary *ta = [self _titleAttributes];
    [ta setObject:[NSFont systemFontOfSize:10.0] forKey:NSFontAttributeName];
    // magic color for dark mode
    NSColor *fgColor = [NSColor respondsToSelector:@selector(secondaryLabelColor)] ? [NSColor secondaryLabelColor] : [NSColor grayColor];
    [ta setObject:fgColor forKey:NSForegroundColorAttributeName];
    return ta;
}

- (CGFloat)_titleHeight
{
    static CGFloat _titleHeight = -1;
    if (_titleHeight < 0) {
        NSLayoutManager *lm = [[NSLayoutManager alloc] init];
        _titleHeight = [lm defaultLineHeightForFont:[[self _titleAttributes] objectForKey:NSFontAttributeName]];
        [lm release];
    }
    return _titleHeight;
}

- (CGFloat)_subtitleHeight
{
    static CGFloat _subtitleHeight = -1;
    if (_subtitleHeight < 0) {
        NSLayoutManager *lm = [[NSLayoutManager alloc] init];
        _subtitleHeight = [lm defaultLineHeightForFont:[[self _subtitleAttributes] objectForKey:NSFontAttributeName]];
        [lm release];
    }
    return _subtitleHeight;
}

// not part of the API because padding is private, and that's a can of worms
- (CGFloat)_columnWidth { return _iconSize.width + _padding.width; }
- (CGFloat)_rowHeight { return _iconSize.height + _padding.height; }

- (void)_commonInit 
{
    _dataSource = nil;
    _controller = [[_FVController allocWithZone:[self zone]] initWithView:self];
    // initialize to one; we always have one or more columns, but may have zero rows
    _numberOfColumns = 1;
    _iconSize = DEFAULT_ICON_SIZE;
    _padding = [self _defaultPaddingForScale:1.0];
    _lastMouseDownLocInView = NSZeroPoint;
    _dropRectForHighlight = NSZeroRect;
    _fvFlags.dropOperation = FVDropNone;
    _fvFlags.isRescaling = NO;
    _fvFlags.scheduledLiveResize = NO;
    _fvFlags.controllingQLPreviewPanel = NO;
    _fvFlags.controllingSharedPreviewer = NO;
    _selectedIndexes = [[NSMutableIndexSet alloc] init];
    _lastClickedIndex = NSNotFound;
    _rubberBandRect = NSZeroRect;
    _fvFlags.isMouseDown = NO;
    _fvFlags.isEditable = NO;
    [self setBackgroundColor:[[self class] defaultBackgroundColor]];
    _selectionOverlay = NULL;
            
    _lastOrigin = NSZeroPoint;
    _timeOfLastOrigin = CFAbsoluteTimeGetCurrent();
    _trackingRectMap = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &FVIntegerKeyDictionaryCallBacks, &FVIntegerValueDictionaryCallBacks);
        
    _leftArrow = [[FVArrowButtonCell alloc] initWithArrowDirection:FVArrowLeft];
    [_leftArrow setTarget:self];
    [_leftArrow setAction:@selector(leftArrowAction:)];
    
    _rightArrow = [[FVArrowButtonCell alloc] initWithArrowDirection:FVArrowRight];
    [_rightArrow setTarget:self];
    [_rightArrow setAction:@selector(rightArrowAction:)];
    
    _leftArrowFrame = NSZeroRect;
    _rightArrowFrame = NSZeroRect;
    _arrowAlpha = 0.0;
    _fvFlags.isAnimatingArrowAlpha = NO;
    _fvFlags.hasArrows = NO;
    
    _minScale = 0.5;
    _maxScale = 10;
    
    // don't waste memory on this for single-column case
    if ([self _showsSlider]) {
        _sliderWindow = [[FVSliderWindow alloc] init];
        FVSlider *slider = [_sliderWindow slider];
        // binding & unbinding is handled in viewWillMoveToSuperview:
        [slider setMaxValue:_maxScale];
        [slider setMinValue:_minScale];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSliderMouseExited:) name:FVSliderMouseExitedNotificationName object:slider];
    }
    // always initialize this to -1
    _sliderTag = -1;
    
    _contentBinding = nil;
    _selectionBinding = nil;
    _fvFlags.isObservingSelectionIndexes = NO;
    
}

#pragma mark NSView overrides

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    [self _commonInit];
    return self;
}

- (id)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    // initialize with default values, then override with settings from IB
    [self _commonInit];
    [self setBackgroundColor:[coder decodeObjectForKey:@"backgroundColor"]];
    [self setEditable:[coder decodeBoolForKey:@"editable"]];
    [self setMinIconScale:[coder decodeDoubleForKey:@"minIconScale"]];
    [self setMaxIconScale:[coder decodeDoubleForKey:@"maxIconScale"]];
    [self setIconScale:[coder decodeDoubleForKey:@"iconScale"]];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
    [coder encodeObject:[self backgroundColor] forKey:@"backgroundColor"];
    [coder encodeBool:[self isEditable] forKey:@"editable"];
    [coder encodeDouble:[self minIconScale] forKey:@"minIconScale"];
    [coder encodeDouble:[self maxIconScale] forKey:@"maxIconScale"];
    [coder encodeDouble:[self iconScale] forKey:@"iconScale"];
}

- (void)dealloc
{
    [_leftArrow release];
    [_rightArrow release];
    [_controller release];
    [_selectedIndexes release];
    [_backgroundColor release];
    [_sliderWindow release];
    // this variable is accessed in super's dealloc, so set it to NULL
    CFRelease(_trackingRectMap);
    _trackingRectMap = NULL;
    CGLayerRelease(_selectionOverlay);
    FVAPIAssert2(nil == _selectionBinding, @"failed to unbind %@ from %@; leaking observation info", ((_FVBinding *)_selectionBinding)->_observable, self);
    FVAPIAssert2(nil == _contentBinding, @"failed to unbind %@ from %@; leaking observation info", ((_FVBinding *)_contentBinding)->_observable, self);
    [super dealloc];
}

- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return YES; }

- (void)setBackgroundColor:(NSColor *)aColor;
{
    if (_backgroundColor != aColor) {
        [_backgroundColor release];
        _backgroundColor = [aColor copy];
        [self setNeedsDisplay:YES];
    }
}

- (NSColor *)backgroundColor
{ 
    return _fvFlags.isDrawingDragImage ? [NSColor clearColor] : _backgroundColor;
}

#pragma mark API

// scrollPositionAsPercentage borrowed and modified from the Omni frameworks
- (NSPoint)scrollPercentage;
{
    NSRect bounds = [self bounds];
    NSScrollView *enclosingScrollView = [self enclosingScrollView];
    
    // avoid returning a struct from a nil message
    if (nil == enclosingScrollView)
        return NSZeroPoint;
    
    NSRect documentVisibleRect = [enclosingScrollView documentVisibleRect];
    
    NSPoint scrollPosition;
    
    // Vertical position
    if (NSHeight(documentVisibleRect) >= NSHeight(bounds)) {
        scrollPosition.y = 0.0; // We're completely visible
    } else {
        scrollPosition.y = (NSMinY(documentVisibleRect) - NSMinY(bounds)) / (NSHeight(bounds) - NSHeight(documentVisibleRect));
        scrollPosition.y = MAX(scrollPosition.y, 0.0);
        scrollPosition.y = MIN(scrollPosition.y, 1.0);
    }
    
    // Horizontal position
    if (NSWidth(documentVisibleRect) >= NSWidth(bounds)) {
        scrollPosition.x = 0.0; // We're completely visible
    } else {
        scrollPosition.x = (NSMinX(documentVisibleRect) - NSMinX(bounds)) / (NSWidth(bounds) - NSWidth(documentVisibleRect));
        scrollPosition.x = MAX(scrollPosition.x, 0.0);
        scrollPosition.x = MIN(scrollPosition.x, 1.0);
    }
    
    return scrollPosition;
}

- (void)setScrollPercentage:(NSPoint)scrollPosition;
{
    NSRect bounds = [self bounds];
    NSScrollView *enclosingScrollView = [self enclosingScrollView];
    
    // do nothing if we don't have a scrollview
    if (nil == enclosingScrollView)
        return;
    
    NSRect desiredRect = [enclosingScrollView documentVisibleRect];
    
    // Vertical position
    if (NSHeight(desiredRect) < NSHeight(bounds)) {
        scrollPosition.y = MAX(scrollPosition.y, 0.0);
        scrollPosition.y = MIN(scrollPosition.y, 1.0);
        desiredRect.origin.y = rint(NSMinY(bounds) + scrollPosition.y * (NSHeight(bounds) - NSHeight(desiredRect)));
        if (NSMinY(desiredRect) < NSMinY(bounds))
            desiredRect.origin.y = NSMinY(bounds);
        else if (NSMaxY(desiredRect) > NSMaxY(bounds))
            desiredRect.origin.y = NSMaxY(bounds) - NSHeight(desiredRect);
    }
    
    // Horizontal position
    if (NSWidth(desiredRect) < NSWidth(bounds)) {
        scrollPosition.x = MAX(scrollPosition.x, 0.0);
        scrollPosition.x = MIN(scrollPosition.x, 1.0);
        desiredRect.origin.x = rint(NSMinX(bounds) + scrollPosition.x * (NSWidth(bounds) - NSWidth(desiredRect)));
        if (NSMinX(desiredRect) < NSMinX(bounds))
            desiredRect.origin.x = NSMinX(bounds);
        else if (NSMaxX(desiredRect) > NSMaxX(bounds))
            desiredRect.origin.x = NSMaxX(bounds) - NSHeight(desiredRect);
    }
    
    [self scrollPoint:desiredRect.origin];
}

- (void)_invalidateSelectionOverlay
{
    if (_selectionOverlay) {
        CFRelease(_selectionOverlay);
        _selectionOverlay = NULL;
    }
}

- (void)setIconScale:(double)scale;
{
    // formerly asserted this, but it caused problems with archiving
    if (scale <= 0) scale = 1.0;
    
    _iconSize.width = DEFAULT_ICON_SIZE.width * scale;
    _iconSize.height = DEFAULT_ICON_SIZE.height * scale;
    
    // arrows out of place now, they will be added again when required when resetting the tracking rects
    [self _hideArrows];
    
    // need to resize border
    [self _invalidateSelectionOverlay];
    
    NSPoint scrollPoint = [self scrollPercentage];
    
    // the grid and cursor rects have changed
    [self _reloadIconsAndController:NO];
    [self setScrollPercentage:scrollPoint];
    
    // Schedule a reload so we always have the correct quality icons, but don't do it while scaling in response to a slider.
    // This will also scroll to the first selected icon; maintaining scroll position while scaling is too jerky.
    if (NO == _fvFlags.isRescaling) {
        _fvFlags.isRescaling = YES;
        // this is only sent in the default runloop mode, so it's not sent during event tracking
        [self performSelector:@selector(_rescaleComplete) withObject:nil afterDelay:0.0];
    }
}

- (double)iconScale;
{
    return _iconSize.width / DEFAULT_ICON_SIZE.width;
}
    
- (void)_registerForDraggedTypes
{
    if (_fvFlags.isEditable && _dataSource) {
        struct _old_new_selectors {
            SEL old;
            SEL new;
        };
        struct _old_new_selectors selectors[] =
        {
            { @selector(fileView:insertURLs:atIndexes:),          @selector(fileView:insertURLs:atIndexes:dragOperation:)          },
            { @selector(fileView:replaceURLsAtIndexes:withURLs:), @selector(fileView:replaceURLsAtIndexes:withURLs:dragOperation:) },
            { @selector(fileView:moveURLsAtIndexes:toIndex:),     @selector(fileView:moveURLsAtIndexes:toIndex:dragOperation:)     },
            { @selector(fileView:deleteURLsAtIndexes:),           @selector(fileView:deleteURLsAtIndexes:)    /* same */           }
        };
        NSUInteger i, iMax = sizeof(selectors) / sizeof(struct _old_new_selectors);
        for (i = 0; i < iMax; i++) {
            struct _old_new_selectors ons = selectors[i];
            FVAPIAssert2([_dataSource respondsToSelector:ons.old] || [_dataSource respondsToSelector:ons.new], @"datasource must implement %@ or %@", NSStringFromSelector(ons.old), NSStringFromSelector(ons.new));
        }

        NSString *weblocType = @"CorePasteboardFlavorType 0x75726C20";
        [self registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType, NSURLPboardType, weblocType, (NSString *)kUTTypeURL, (NSString *)kUTTypeUTF8PlainText, NSStringPboardType, nil]];
    } else {
        [self unregisterDraggedTypes];
    }
}

- (double)maxIconScale { return _maxScale; }

- (void)setMaxIconScale:(double)scale { 
    _maxScale = scale; 
    [[_sliderWindow slider] setMaxValue:scale];
    if ([self iconScale] > scale && scale > 0)
        [self setIconScale:scale];
}

- (double)minIconScale { return _minScale; }

- (void)setMinIconScale:(double)scale { 
    _minScale = scale; 
    [[_sliderWindow slider] setMinValue:scale];
    if ([self iconScale] < scale && scale > 0)
        [self setIconScale:scale];
}

- (void)setDataSource:(id)obj;
{
    // I was asserting these conditions, but that crashes the IB simulator if you set a datasource in IB.  Setting datasource to nil in case of failure avoids other exceptions later (notably in _FVController).
    BOOL failed = NO;
    if (obj && [obj respondsToSelector:@selector(numberOfIconsInFileView:)] == NO) {
        FVLog(@"*** ERROR *** datasource %@ must implement %@", obj, NSStringFromSelector(@selector(numberOfIconsInFileView:)));
        failed = YES;
    }
    if (obj && [obj respondsToSelector:@selector(fileView:URLAtIndex:)] == NO) {
        FVLog(@"*** ERROR *** datasource %@ must implement %@", obj, NSStringFromSelector(@selector(fileView:URLAtIndex:)));
        failed = YES;
    }
    if (failed) obj = nil;
    
    _dataSource = obj;
    [_controller setDataSource:obj];
    
    [self _registerForDraggedTypes];
    
    // datasource may implement subtitles, which affects our drawing layout (padding height)
    [self reloadIcons];
}

- (id)dataSource { return _dataSource; }

- (BOOL)isEditable 
{ 
    return _fvFlags.isEditable;
}

- (void)setEditable:(BOOL)flag 
{
    if (_fvFlags.isEditable != flag) {
        _fvFlags.isEditable = flag;
        
        [self _registerForDraggedTypes];
    }
}

- (void)setDelegate:(id)obj;
{
    _delegate = obj;
}

- (id)delegate { return _delegate; }

- (NSUInteger)numberOfRows;
{
    NSUInteger nc = [self numberOfColumns];
    NSParameterAssert(nc >= 1);
    NSUInteger ni = [_controller numberOfIcons];
    NSUInteger r = ni % nc > 0 ? 1 : 0;
    return (ni/nc + r);
}

// overall borders around the view
- (CGFloat)_leftMargin { return _padding.width / 2 + MARGIN_BASE; }
- (CGFloat)_rightMargin { return _padding.width / 2 + MARGIN_BASE; }

// warning: if these are ever changed to depend on padding, _recalculateGridSize needs to be changed
- (CGFloat)_topMargin { return [self _titleHeight]; }
- (CGFloat)_bottomMargin { return MARGIN_BASE; }

- (NSUInteger)_numberOfColumnsInFrame:(NSRect)frameRect
{
    return MAX(1, trunc((NSWidth(frameRect) - 2 * MARGIN_BASE) / [self _columnWidth]));
}

- (NSUInteger)numberOfColumns;
{
    return _numberOfColumns;
}

- (NSSize)_defaultPaddingForScale:(CGFloat)scale;
{
    // ??? magic number here... using a fixed padding looked funny at some sizes, so this is now adjustable
    NSSize size = NSZeroSize;
    CGFloat extraMargin = round(4.0 * scale);
    size.width = MINIMUM_PADDING + extraMargin;
    size.height = [self _titleHeight] + extraMargin;
    // add subtitle + additional amount to keep from clipping descenders on subtitles with selection layer
    if ([_dataSource respondsToSelector:@selector(fileView:subtitleAtIndex:)])
        size.height += 1.3 * [self _subtitleHeight];
    return size;
}

- (BOOL)_showsSlider { return YES; }

- (NSRect)_sliderRect
{
    NSRect r;
    NSScrollView *scrollView = [self enclosingScrollView];
    NSPoint origin = NSZeroPoint;
    if (scrollView) {
        r = [scrollView frame];
        if ([scrollView hasVerticalScroller])
            r.size.width -= NSWidth([[scrollView verticalScroller] frame]);
        origin = [self convertPoint:NSMakePoint(NSWidth(r) / 3, 0) fromView:scrollView];
        r = [self convertRect:r fromView:scrollView];
    }
    else {
        r = [self visibleRect];
    }
    origin.y += 1;
    CGFloat w = NSWidth(r) / 3;
    r.size.width = w;
    r.size.height = 15;
    r.origin = origin;
    return r;
}

// This is the square rect the icon is drawn in.  It doesn't include padding, so rects aren't contiguous.
// Caller is responsible for any centering before drawing.
- (NSRect)_rectOfIconInRow:(NSUInteger)row column:(NSUInteger)column;
{
    NSPoint origin = [self bounds].origin;
    CGFloat leftEdge = origin.x + [self _leftMargin] + [self _columnWidth] * column;
    CGFloat topEdge = origin.y + [self _topMargin] + [self _rowHeight] * row;
    return NSMakeRect(leftEdge, topEdge, _iconSize.width, _iconSize.height);
}

- (NSRect)_rectOfTextForIconRect:(NSRect)iconRect;
{
    // add a couple of points between the icon and text, which is useful if we're drawing a Finder label
    // don't draw all the way into the padding vertically
    const CGFloat border = 2.0;
    NSRect textRect = NSMakeRect(NSMinX(iconRect), NSMaxY(iconRect) + border, NSWidth(iconRect), _padding.height - 2 * border);
    // allow the text rect to extend outside the grid cell horizontally
    return NSInsetRect(textRect, -_padding.width / 3.0, 0);
}

- (void)_setNeedsDisplayForIconInRow:(NSUInteger)row column:(NSUInteger)column {
    NSRect iconRect = [self _rectOfIconInRow:row column:column];
    // extend horizontally to account for shadow in case text is narrower than the icon
    // extend upward by 1 unit to account for slight mismatch between icon/placeholder drawing
    // extend downward to account for the text area
    CGFloat horizontalExpansion = floor(_padding.width / 2.0);
    NSRect dirtyRect = NSUnionRect(NSInsetRect(iconRect, -horizontalExpansion, -1.0), [self _rectOfTextForIconRect:iconRect]);
    [self setNeedsDisplayInRect:dirtyRect];
}

static void _removeTrackingRectTagFromView(const void *key, const void *value, void *context)
{
    [(NSView *)context removeTrackingRect:(NSTrackingRectTag)key];
}

- (void)_removeAllTrackingRects
{
    if (_trackingRectMap) {
        CFDictionaryApplyFunction(_trackingRectMap, _removeTrackingRectTagFromView, self);
        CFDictionaryRemoveAllValues(_trackingRectMap);
    }
    if (-1 != _sliderTag)
        [self removeTrackingRect:_sliderTag];
}

// okay to call this without removing the tracking rect first; no effect for single column views
- (void)_resetSliderTrackingRect;
{
    if (-1 != _sliderTag)
        [self removeTrackingRect:_sliderTag];
    
    if ([self _showsSlider]) {
        NSPoint mouseLoc = [self convertPoint:[[self window] mouseLocationOutsideOfEventStream] fromView:nil];
        NSRect sliderRect = [self _sliderRect];
        _sliderTag = [self addTrackingRect:sliderRect owner:self userData:_sliderWindow assumeInside:NSMouseInRect(mouseLoc, sliderRect, [self isFlipped])];  
    }
}

// We assume that all existing tracking rects and tooltips have been removed prior to invoking this method, so don't call it directly.  Use -[NSWindow invalidateCursorRectsForView:] instead.
- (void)_resetTrackingRectsAndToolTips
{    
    // no guarantee that we have a window, in which case these will all be wrong
    if (nil != [self window]) {
        NSRect visibleRect = [self visibleRect];        
        NSRange visRows, visColumns;
        [self _getRangeOfRows:&visRows columns:&visColumns inRect:visibleRect];
        NSUInteger r, rMin = visRows.location, rMax = NSMaxRange(visRows);
        NSUInteger c, cMin = visColumns.location, cMax = NSMaxRange(visColumns);
        NSUInteger i, iMin = [self _indexForGridRow:rMin column:cMin], iMax = MIN([_controller numberOfIcons], [self _indexForGridRow:rMax column:cMax]);
        
        NSPoint mouseLoc = [self convertPoint:[[self window] mouseLocationOutsideOfEventStream] fromView:nil];
        NSUInteger mouseIndex = NSNotFound;
        
        for (r = rMin, i = iMin; r < rMax; r++) 
        {
            for (c = cMin; c < cMax && i < iMax; c++, i++) 
            {
                NSRect iconRect = NSIntersectionRect(visibleRect, [self _rectOfIconInRow:r column:c]);
                
                if (NSIsEmptyRect(iconRect) == NO) {
                    BOOL mouseInside = NSMouseInRect(mouseLoc, iconRect, [self isFlipped]);
                    
                    if (mouseInside)
                        mouseIndex = i;
                    
                    // Getting the location from the mouseEntered: event isn't reliable if you move the mouse slowly, so we either need to enlarge this tracking rect, or keep a map table of tag->index.  Since we have to keep a set of tags anyway, we'll use the latter method.
                    NSTrackingRectTag tag = [self addTrackingRect:iconRect owner:self userData:NULL assumeInside:mouseInside];
                    CFDictionarySetValue(_trackingRectMap, (const void *)tag, (const void *)i);
                    
                    // don't pass the URL as owner, as it's not retained; use the delegate method instead
                    [self addToolTipRect:iconRect owner:self userData:NULL];
                }
            }
        }    
        
        FVIcon *anIcon = mouseIndex == NSNotFound ? nil : [_controller iconAtIndex:mouseIndex];
        if ([anIcon pageCount] > 1)
            [self _showArrowsForIconAtIndex:mouseIndex];
        else
            [self _hideArrows];
        
        [self _resetSliderTrackingRect];
    }
}

// Here again, use -[NSWindow invalidateCursorRectsForView:] instead of calling this directly.
- (void)_discardTrackingRectsAndToolTips
{
    [self _removeAllTrackingRects];
    [self removeAllToolTips];   
}

/*  
   10.4 docs say "You need never invoke this method directly; it's invoked automatically before the receiver's cursor rectangles are reestablished using resetCursorRects."
   10.5 docs say "You need never invoke this method directly; neither is it typically invoked during the invalidation of cursor rectangles. [...] This method is invoked just before the receiver is removed from a window and when the receiver is deallocated."
 
   This is a pretty radical change that makes -discardCursorRects sound pretty useless.  Maybe that explains why cursor rects have always sucked in Apple's apps and views?  Anyway, I'm explicitly discarding before resetting, just to be safe.  I'm also telling the window to invalidate cursor rects for this view explicitly whenever the grid changes due to number of icons or resize.  Even though I don't use cursor rects right now, this is a convenient funnel point for tracking rect handling.
 
   It is important to note that discardCursorRects /has/ to be safe during dealloc (hence the _trackingRectMap is explicitly set to NULL).
 
 */
- (void)discardCursorRects
{
    [super discardCursorRects];
    [self _discardTrackingRectsAndToolTips];
}

// automatically invoked as needed after -[NSWindow invalidateCursorRectsForView:]
- (void)resetCursorRects
{
    [super resetCursorRects];
    [self _discardTrackingRectsAndToolTips];
    [self _resetTrackingRectsAndToolTips];
}

- (void)_reloadIconsAndController:(BOOL)shouldReloadController;
{
    // scale changes don't cause any data reordering
    if (shouldReloadController) {
        
        /*
         Loading can cause unintended side effects, such as view redrawing, if AppKit decides to run the
         main thread's runloop.  Notably, this can happen through a call to +[FVTextIcon canInitWithURL:],
         so the count and actual icons in the controller are inconsistent.  This flag is a workaround for
         what I think is an egregious Apple bug:
         
         #3	0x0079cac0 in -[_FVController iconAtIndex:] at _FVController.m:217
         #4	0x00758c48 in -[FileView _drawIconsInRange:rows:columns:] at FileView.m:1745
         #5	0x00759dda in -[FileView drawRect:] at FileView.m:1896
         #6	0x91fce82a in -[NSView _drawRect:clip:]
         #7	0x91fcd4c8 in -[NSView _recursiveDisplayAllDirtyWithLockFocus:visRect:]
         #8	0x91fcd7fd in -[NSView _recursiveDisplayAllDirtyWithLockFocus:visRect:]
         #9	0x91fcb9e7 in -[NSView _recursiveDisplayRectIfNeededIgnoringOpacity:isVisibleRect:rectIsVisibleRectForView:topView:]
         #10	0x91fcc95c in -[NSView _recursiveDisplayRectIfNeededIgnoringOpacity:isVisibleRect:rectIsVisibleRectForView:topView:]
         #11	0x91fcc95c in -[NSView _recursiveDisplayRectIfNeededIgnoringOpacity:isVisibleRect:rectIsVisibleRectForView:topView:]
         #12	0x91fcc95c in -[NSView _recursiveDisplayRectIfNeededIgnoringOpacity:isVisibleRect:rectIsVisibleRectForView:topView:]
         #13	0x91fcc95c in -[NSView _recursiveDisplayRectIfNeededIgnoringOpacity:isVisibleRect:rectIsVisibleRectForView:topView:]
         #14	0x91fcc95c in -[NSView _recursiveDisplayRectIfNeededIgnoringOpacity:isVisibleRect:rectIsVisibleRectForView:topView:]
         #15	0x91fcb55b in -[NSThemeFrame _recursiveDisplayRectIfNeededIgnoringOpacity:isVisibleRect:rectIsVisibleRectForView:topView:]
         #16	0x91fc7ea2 in -[NSView _displayRectIgnoringOpacity:isVisibleRect:rectIsVisibleRectForView:]
         #17	0x91f28a57 in -[NSView displayIfNeeded]
         #18	0x91ef1d40 in -[NSWindow displayIfNeeded]
         #19	0x91f2328a in _handleWindowNeedsDisplay
         #20	0x9515de02 in __CFRunLoopDoObservers
         #21	0x95119d8d in __CFRunLoopRun
         #22	0x95119464 in CFRunLoopRunSpecific
         #23	0x95119291 in CFRunLoopRunInMode
         #24	0x922e3238 in -[NSHTMLReader _loadUsingWebKit]
         #25	0x922d791f in -[NSHTMLReader attributedString]
         #26	0x92136d4d in _NSReadAttributedStringFromURLOrData
         #27	0x9214bdd3 in -[NSAttributedString(NSAttributedStringKitAdditions) initWithURL:options:documentAttributes:error:]
         #28	0x9217c2ca in -[NSAttributedString(NSAttributedStringKitAdditions) initWithURL:documentAttributes:]
         #29	0x007777bf in +[FVTextIcon canInitWithURL:] at FVTextIcon.m:201
         #30	0x00768016 in -[FVIcon initWithURL:] at FVIcon.m:226
         #31	0x0079e23c in -[_FVController _cachedIconForURL:] at _FVController.m:469
         #32	0x0079d967 in -[_FVController reload] at _FVController.m:380
         #33	0x00750c16 in -[FileView _reloadIconsAndController:] at FileView.m:764
         
         */
        _fvFlags.reloadingController = YES;
        [_controller reload];
        _fvFlags.reloadingController = NO;
        
        // Follow NSTableView's example and clear selection outside the current range of indexes
        NSUInteger lastSelIndex = [_selectedIndexes lastIndex];
        if (NSNotFound != lastSelIndex && lastSelIndex >= [_controller numberOfIcons]) {
            [self willChangeValueForKey:NSSelectionIndexesBinding];
            [_selectedIndexes removeIndexesInRange:NSMakeRange([_controller numberOfIcons], lastSelIndex + 1 - [_controller numberOfIcons])];
            [self didChangeValueForKey:NSSelectionIndexesBinding];
        }
        
        // Content or ordering of selection (may) have changed, so reload any previews
        // Only modify the previewer if this view is controlling it, though!
        if (_fvFlags.controllingSharedPreviewer || _fvFlags.controllingQLPreviewPanel) {
            
            // reload might result in an empty view...
            if ([_selectedIndexes count] == 0) {
                
                if ([[FVPreviewer sharedPreviewer] isPreviewing]) {
                    [[FVPreviewer sharedPreviewer] stopPreviewing];
                }
                else if (_fvFlags.controllingQLPreviewPanel) {
                    [[QLPreviewPanelClass sharedPreviewPanel] orderOut:nil];
                    [[QLPreviewPanelClass sharedPreviewPanel] setDataSource:nil];
                    [[QLPreviewPanelClass sharedPreviewPanel] setDelegate:nil];
                }
            }
            else if ([_selectedIndexes count] == 1) {
                NSUInteger r, c;
                [self _getGridRow:&r column:&c ofIndex:[_selectedIndexes lastIndex]];
                [self _previewURL:[[self _selectedURLs] lastObject] forIconInRect:[self _rectOfIconInRow:r column:c]];
            }
            else {
                [self _previewURLs:[self _selectedURLs]];
            }
        }
    }
    
    [self _recalculateGridSize];
    
    // grid may have changed, so do a full redisplay
    [self setNeedsDisplay:YES];
    
    /* 
     Any time the number of icons or scale changes, cursor rects are garbage and need to be reset.  
     The approved way to do this is by calling invalidateCursorRectsForView:, and the docs say to 
     never invoke -[NSView resetCursorRects] manually.  Unfortunately, tracking rects are still 
     active even though the window isn't key, and we show buttons for non-key windows.  
     As a consequence, if the number of icons just changed from (say) 3 to 1 in a non-key view, 
     it can receive mouseEntered: events for the now-missing icons.  Possibly we don't need to 
     reset cursor rects since they only change for the key window, but we'll reset everything 
     manually just in case.  Allow NSWindow to handle it if the window is key.
     */
    NSWindow *window = [self window];
    [window invalidateCursorRectsForView:self];
    if ([window isKeyWindow] == NO)
        [self resetCursorRects];
}

- (void)reloadIcons;
{
    [self _reloadIconsAndController:YES];
}

#pragma mark Binding support

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{    
    if (context == &_FVInternalSelectionObserverContext || context == &_FVSelectionBindingToControllerObserverContext) {

        NSParameterAssert([keyPath isEqualToString:NSSelectionIndexesBinding]);
        
        _FVBinding *selBinding = _selectionBinding;
        BOOL updatePreviewer = NO;
        
        if (selBinding && context == &_FVInternalSelectionObserverContext) {
            // update the controller's selection; this call will cause a KVO notification that we'll also observe
            [selBinding->_observable setValue:_selectedIndexes forKeyPath:selBinding->_keyPath];
            
            // since this will be called multiple times for a single event, we should only run the preview if self == context
            updatePreviewer = YES;
        }
        else if (selBinding && context == &_FVSelectionBindingToControllerObserverContext) {
            NSIndexSet *controllerSet = [selBinding->_observable valueForKeyPath:selBinding->_keyPath];
            // since we manipulate _selectedIndexes directly, this won't cause a looping notification
            if ([controllerSet isEqualToIndexSet:_selectedIndexes] == NO) {
                [_selectedIndexes removeAllIndexes];
                [_selectedIndexes addIndexes:controllerSet];
            }
        }
        else if (nil == selBinding) {
            // no binding, so this should be a view-initiated change
            NSParameterAssert(context == &_FVInternalSelectionObserverContext);
            updatePreviewer = YES;
        }
        [self setNeedsDisplay:YES];
        
        FVPreviewer *previewer = [FVPreviewer sharedPreviewer];
        if (updatePreviewer && NSNotFound != [_selectedIndexes firstIndex] && ([previewer isPreviewing] || _fvFlags.controllingQLPreviewPanel)) {
            if ([_selectedIndexes count] == 1) {
                NSUInteger r, c;
                [self _getGridRow:&r column:&c ofIndex:[_selectedIndexes firstIndex]];
                [self _previewURL:[_controller URLAtIndex:[_selectedIndexes firstIndex]] forIconInRect:[self _rectOfIconInRow:r column:c]];
            }
            else {
                [self _previewURLs:[self _selectedURLs]];
            }
        }      

    }
    else if (context == &_FVContentBindingToControllerObserverContext) {
        NSParameterAssert(nil != _contentBinding);
        _FVBinding *contentBinding = _contentBinding;
        NSParameterAssert([keyPath isEqualToString:contentBinding->_keyPath]);
        // change to the number of icons or some rearrangement
        [_controller setIconURLs:[contentBinding->_observable valueForKeyPath:contentBinding->_keyPath]];
        [self reloadIcons];
    }
    else {
        // not our context, so use super's implementation; documentation is totally wrong on this
        // http://lists.apple.com/archives/cocoa-dev/2008/Oct/msg01096.html
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)bind:(NSString *)binding toObject:(id)observable withKeyPath:(NSString *)keyPath options:(NSDictionary *)options;
{
    if ([options count])
        FVLog(@"*** warning *** binding options are unsupported in -[%@ %@] (requested %@)", [self class], NSStringFromSelector(_cmd), options);
    
    // Note: we don't bind to this, some client does.  We do register as an observer, but that's a different code path.
    if ([binding isEqualToString:NSSelectionIndexesBinding]) {
        
        FVAPIAssert3(nil == _selectionBinding, @"attempt to bind %@ to %@ when bound to %@", keyPath, observable, ((_FVBinding *)_selectionBinding)->_observable);
        
        // Create an object to handle the binding mechanics manually; it's deallocated when the client unbinds.
        _selectionBinding = [[_FVBinding alloc] initWithObservable:observable keyPath:keyPath options:options];
        [observable addObserver:self forKeyPath:keyPath options:0 context:&_FVSelectionBindingToControllerObserverContext];
        
        // set initial values
        [_selectedIndexes release];
        _selectedIndexes = [[observable valueForKeyPath:keyPath] mutableCopy];
        [self setNeedsDisplay:YES];
    }
    else if ([binding isEqualToString:NSContentBinding]) {
     
        FVAPIAssert3(nil == _contentBinding, @"attempt to bind %@ to %@ when bound to %@", keyPath, observable, ((_FVBinding *)_contentBinding)->_observable);
                
        // keep a record of the observervable object for unbinding; this is strictly for observation, not a manual binding
        _contentBinding = [[_FVBinding alloc] initWithObservable:observable keyPath:keyPath options:options];
        [observable addObserver:self forKeyPath:keyPath options:0 context:&_FVContentBindingToControllerObserverContext];
        [_controller setBound:YES];
        
        // set initial values
        [_controller setIconURLs:[observable valueForKeyPath:keyPath]];
        [self reloadIcons];
    }
    else {
        [super bind:binding toObject:observable withKeyPath:keyPath options:options];
    }
}

- (void)unbind:(NSString *)binding
{    
    [super unbind:binding];

    if ([binding isEqualToString:NSSelectionIndexesBinding]) {
        FVAPIAssert2(nil != _selectionBinding, @"%@: attempt to unbind %@ when unbound", self, binding);
        [_selectionBinding release];
        _selectionBinding = nil;
    }
    else if ([binding isEqualToString:NSContentBinding]) {
        FVAPIAssert2(nil != _contentBinding, @"%@: attempt to unbind %@ when unbound", self, binding);
        
        _FVBinding *contentBinding = (_FVBinding *)_contentBinding;
        [contentBinding->_observable removeObserver:self forKeyPath:contentBinding->_keyPath];
        [_contentBinding release];
        _contentBinding = nil;

        [_controller setIconURLs:nil];
        [_controller setBound:NO];
        /*
         Calling -[super unbind:binding] after this may cause selection to be reset; 
         this happens with the controller in the demo project, since it unbinds in 
         the wrong order.  We should be resilient against that, so we unbind first.
         */
        [self setSelectionIndexes:[NSIndexSet indexSet]];
    }
    [self reloadIcons];
}

- (NSDictionary *)infoForBinding:(NSString *)binding;
{
    NSDictionary *info = nil;
    if (([binding isEqualToString:NSSelectionIndexesBinding] && nil != _selectionBinding) || ([binding isEqualToString:NSContentBinding] && nil != _contentBinding)) {
        NSMutableDictionary *bindingInfo = [NSMutableDictionary dictionary];
        _FVBinding *theBinding = [binding isEqualToString:NSSelectionIndexesBinding] ? _selectionBinding : _contentBinding;
        NSParameterAssert(NULL != theBinding); // for static analyzer
        if (theBinding->_observable) [bindingInfo setObject:theBinding->_observable forKey:NSObservedObjectKey];
        if (theBinding->_keyPath) [bindingInfo setObject:theBinding->_keyPath forKey:NSObservedKeyPathKey];
        if (theBinding->_options) [bindingInfo setObject:theBinding->_options forKey:NSOptionsKey];
        info = bindingInfo;
    }
    else {
        info = [super infoForBinding:binding];
    }
    return info;
}

- (Class)valueClassForBinding:(NSString *)binding
{
    Class valueClass = Nil;
    if ([binding isEqualToString:NSSelectionIndexesBinding])
        valueClass = [NSIndexSet class];
    else if ([binding isEqualToString:NSContentBinding])
        valueClass = [NSArray class];
    else if ([binding isEqualToString:@"backgroundColor"])
        valueClass = [NSColor class];
    else if ([binding isEqualToString:@"iconScale"] || [binding isEqualToString:@"maxIconScale"] || [binding isEqualToString:@"minIconScale"])
        valueClass = [NSNumber class];
    else
        valueClass = [super valueClassForBinding:binding];
    return valueClass;
}

- (void)unbindExposedBindings
{
    NSEnumerator *bindingEnum = [[self exposedBindings] objectEnumerator];
    NSString *binding;
    while ((binding = [bindingEnum nextObject])) {
        
        if (nil != [self infoForBinding:binding])
            [self unbind:binding];
    }
}

- (NSArray *)optionDescriptionsForBinding:(NSString *)binding;
{
    NSArray *options;
    
    if ([binding isEqualToString:NSSelectionIndexesBinding]) {
        NSAttributeDescription *desc = [NSAttributeDescription new];
        [desc setName:@"Selection indexes"];
        [desc setAttributeType:NSUndefinedAttributeType];
        [desc setDefaultValue:[NSIndexSet indexSet]];
        [desc setAttributeValueClassName:@"NSIndexSet"];
        options = [NSArray arrayWithObject:desc];
        [desc release];
    }
    else if ([binding isEqualToString:NSContentBinding]) {
        NSAttributeDescription *desc = [NSAttributeDescription new];
        [desc setName:@"Content"];
        [desc setAttributeType:NSUndefinedAttributeType];
        [desc setDefaultValue:[NSArray array]];
        [desc setAttributeValueClassName:@"NSArray"];
        options = [NSArray arrayWithObject:desc];
        [desc release];
    }
    else if ([binding isEqualToString:@"backgroundColor"]) {
        NSAttributeDescription *desc = [NSAttributeDescription new];
        [desc setName:@"Background color"];
        [desc setAttributeType:NSUndefinedAttributeType];
        [desc setDefaultValue:[[self class] defaultBackgroundColor]];
        [desc setAttributeValueClassName:@"NSColor"];
        options = [NSArray arrayWithObject:desc];
        [desc release];    
    }
    else if ([binding isEqualToString:@"iconScale"]) {
        NSAttributeDescription *desc = [NSAttributeDescription new];
        [desc setName:@"Icon scale"];
        [desc setAttributeType:NSDoubleAttributeType];
        [desc setDefaultValue:[NSNumber numberWithDouble:1.0]];
        [desc setAttributeValueClassName:@"NSNumber"];
        options = [NSArray arrayWithObject:desc];
        [desc release];
    }
    else if ([binding isEqualToString:@"maxIconScale"]) {
        NSAttributeDescription *desc = [NSAttributeDescription new];
        [desc setName:@"Maximum icon scale"];
        [desc setAttributeType:NSDoubleAttributeType];
        [desc setDefaultValue:[NSNumber numberWithDouble:10.0]];
        [desc setAttributeValueClassName:@"NSNumber"];
        options = [NSArray arrayWithObject:desc];
        [desc release];
    }
    else if ([binding isEqualToString:@"minIconScale"]) {
        NSAttributeDescription *desc = [NSAttributeDescription new];
        [desc setName:@"Minimum icon scale"];
        [desc setAttributeType:NSDoubleAttributeType];
        [desc setDefaultValue:[NSNumber numberWithDouble:0.5]];
        [desc setAttributeValueClassName:@"NSNumber"];
        options = [NSArray arrayWithObject:desc];
        [desc release];
    }
    else {
        options = [super optionDescriptionsForBinding:binding];
    }
    return options;
}

- (void)viewWillMoveToSuperview:(NSView *)newSuperview
{
    [super viewWillMoveToSuperview:newSuperview];
    
    /*
     Mmalc's example unbinds here for a nil superview, and that's the only way I see at present to unbind without having 
     the client do it explicitly, for instance in a windowWillClose:.  Perhaps it would be better for register for that 
     in the view?   
     Old comment: this causes problems if you remove the view and add it back in later (and also can cause crashes as a 
     side effect, if we're not careful with the datasource).
     */
    if (nil == newSuperview) {
        
        if (_fvFlags.isObservingSelectionIndexes) {
            [self removeObserver:self forKeyPath:NSSelectionIndexesBinding];
            _fvFlags.isObservingSelectionIndexes = NO;
        }
        
        [self unbindExposedBindings];

        [_controller cancelQueuedOperations];
        
        // break a retain cycle; binding is retaining this view
        [[_sliderWindow slider] unbind:@"value"];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:FVSliderMouseExitedNotificationName object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:FVPreviewerWillCloseNotification object:nil];
    }
    else {
        
        if (NO == _fvFlags.isObservingSelectionIndexes) {
            [self addObserver:self forKeyPath:NSSelectionIndexesBinding options:0 context:&_FVInternalSelectionObserverContext];
            _fvFlags.isObservingSelectionIndexes = YES;
        }
        
        // bind here (noop if we don't have a slider)
        FVSlider *slider = [_sliderWindow slider];
        [slider bind:@"value" toObject:self withKeyPath:@"iconScale" options:nil];
        if (slider)
            [[NSNotificationCenter defaultCenter] addObserver:self 
                                                     selector:@selector(handleSliderMouseExited:) 
                                                         name:FVSliderMouseExitedNotificationName 
                                                       object:slider];    
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handlePreviewerWillClose:)
                                                     name:FVPreviewerWillCloseNotification
                                                   object:nil];
    }
}

- (void)setSelectionIndexes:(NSIndexSet *)indexSet;
{
    FVAPIAssert(nil != indexSet, @"index set must not be nil");
    [_selectedIndexes autorelease];
    _selectedIndexes = [indexSet mutableCopy];
}

- (NSIndexSet *)selectionIndexes;
{
    return [[_selectedIndexes copy] autorelease];
}

- (NSArray *)_selectedURLs
{
    NSMutableArray *array = [NSMutableArray array];
    NSUInteger idx = [_selectedIndexes firstIndex];
    while (NSNotFound != idx) {
        [array addObject:[_controller URLAtIndex:idx]];
        idx = [_selectedIndexes indexGreaterThanIndex:idx];
    }
    return array;
}

#pragma mark Drawing layout

- (void)_recalculateGridSize
{
    NSClipView *cv = [[self enclosingScrollView] contentView];

    // This is the drawing area we have to work with; it does not include the scroller, but will change if a scroller is added or removed.
    // !!! see if things still work without a scrollview
    NSRect minFrame = cv ? [cv bounds] : [self frame];
    NSRect frame = NSZeroRect;
    
    // Reset padding to the default value, so we get correct baseline for numberOfColumns and other padding-dependent values
    _padding = [self _defaultPaddingForScale:[self iconScale]];
    
    /*
     Required frame using default padding.  The only time we don't use NSWidth(minFrame) is when we 
     have a single column of icons, and the scale is such that icons are clipped horizontally (i.e. we have a horizontal scroller).
     */
    frame.size.width = MAX([self _columnWidth] * [self _numberOfColumnsInFrame:minFrame] + 2 * MARGIN_BASE, NSWidth(minFrame));
    frame.size.height = MAX([self _rowHeight] * [self numberOfRows] + [self _topMargin] + [self _bottomMargin], NSHeight(minFrame));

    // Add a column, then see if we can shrink padding enough to fit it in.  If not, expand padding so we have uniform spacing across the grid.
    NSUInteger ncolumns = [self _numberOfColumnsInFrame:frame] + 1;

    // Compute the number of rows to match our adjusted number of columns
    NSUInteger ni = [_controller numberOfIcons];
    NSUInteger nrows = ni / ncolumns + (ni % ncolumns > 0 ? 1 : 0);
    
    // may not be enough columns to fill a single row; this causes a single icon to be centered across the view
    if (1 == nrows) ncolumns = ni;
    
    /*
     Note: side margins are f(padding), so 
       frameWidth = 2 * (padding / 2 + MARGIN_BASE) + width_icon * ncolumns + padding * (ncolumns - 1).  
     Top and bottom margins are constant, so the accessors are used.
     */
    CGFloat horizontalPadding = (NSWidth(frame) - 2 * MARGIN_BASE - _iconSize.width * ncolumns) / ((CGFloat)ncolumns);
    
    if (horizontalPadding < MINIMUM_PADDING) {
        // recompute based on default number of rows and columns
        ncolumns -= 1;
        nrows = ni / ncolumns + (ni % ncolumns > 0 ? 1 : 0);
        horizontalPadding = (NSWidth(frame) - 2 * MARGIN_BASE - _iconSize.width * ncolumns) / ((CGFloat)ncolumns);
    }

    NSParameterAssert(horizontalPadding > 0);    
    // truncate to avoid tolerance buildup (avoids horizontal scroller display)
    _padding.width = floor(horizontalPadding);   
    
    frame.size.width = MAX([self _columnWidth] * ncolumns + 2 * MARGIN_BASE, NSWidth(minFrame));
    frame.size.height = MAX([self _rowHeight] * nrows + [self _topMargin] + [self _bottomMargin], NSHeight(minFrame));

    // this is a hack to avoid edge cases when resizing; sometimes computing it based on width would give an inconsistent result
    _numberOfColumns = ncolumns;

    // reentrancy:  setFrame: may cause the scrollview to call resizeWithOldSuperviewSize:, so set all state before calling it
    if (NSEqualRects(frame, [self frame]) == NO) {
        [self setFrame:frame];  
        
        /*
         Occasionally the scrollview with autohiding scrollers shows a horizontal scroller unnecessarily; 
         it goes away as soon as the view is scrolled, with no change to the frame or padding.  
         Sending -[scrollView tile] doesn't seem to fix it, nor does setNeedsDisplay:YES; it seems to be 
         an edge case with setting the frame when the last row of icon subtitles are near the bottom of 
         the view.  Using reflectScrollClipView: seems to work reliably, and should at least be harmless.
         */
        [[self enclosingScrollView] reflectScrolledClipView:cv];
    }
}  

- (void)resizeWithOldSuperviewSize:(NSSize)oldBoundsSize
{
    [super resizeWithOldSuperviewSize:oldBoundsSize];
    [self _recalculateGridSize];
}

- (NSUInteger)_indexForGridRow:(NSUInteger)rowIndex column:(NSUInteger)colIndex;
{
    // nc * (r-1) + c
    // assumes all slots are filled, so check numberOfIcons before returning a value
    NSUInteger fileIndex = rowIndex * [self numberOfColumns] + colIndex;
    return fileIndex >= [_controller numberOfIcons] ? NSNotFound : fileIndex;
}

- (BOOL)_getGridRow:(NSUInteger *)rowIndex column:(NSUInteger *)colIndex ofIndex:(NSUInteger)anIndex;
{
    NSUInteger cMax = [self numberOfColumns], rMax = [self numberOfRows];
    
    if (0 == cMax || 0 == rMax)
        return NO;

    // initialize all of these, in case we don't make it to the inner loop
    NSUInteger r, c = 0, i = 0;
    
    // iterate columns within each row
    for (r = 0; r < rMax && i <= anIndex; r++)
    {
        for (c = 0; c < cMax && i <= anIndex; c++) 
        {
            i++;
        }
    }
    
    // grid row/index are zero based
    r--;
    c--;

    if (i <= [_controller numberOfIcons]) {
        if (NULL != rowIndex)
            *rowIndex = r;
        if (NULL != colIndex)
            *colIndex = c;
        return YES;
    }
    return NO;
}

// this is only used for hit testing, so we should ignore padding
- (BOOL)_getGridRow:(NSUInteger *)rowIndex column:(NSUInteger *)colIndex atPoint:(NSPoint)point;
{
    // check for this immediately
    if (point.x <= [self _leftMargin] || point.y <= [self _topMargin])
        return NO;
    
    // column width is padding + icon width
    // row height is padding + icon width
    NSUInteger idx, nc = [self numberOfColumns], nr = [self numberOfRows];
    
    idx = 0;
    CGFloat start;
    
    while (idx < nc) {
        
        start = [self _leftMargin] + [self _columnWidth] * idx;
        if (start < point.x && point.x < (start + _iconSize.width))
            break;
        idx++;
        
        if (idx == nc)
            return NO;
    }
    
    if (colIndex)
        *colIndex = idx;
    
    idx = 0;
    
    while (idx < nr) {
        
        start = [self _topMargin] + [self _rowHeight] * idx;
        if (start < point.y && point.y < (start + _iconSize.height))
            break;
        idx++;
        
        if (idx == nr)
            return NO;
    }
    
    if (rowIndex)
        *rowIndex = idx;
    
    return YES;
}

#pragma mark Cache thread

- (void)_rescaleComplete;
{    
    NSUInteger scrollIndex = [_selectedIndexes firstIndex];
    if (NSNotFound != scrollIndex) {
        NSUInteger r, c;
        [self _getGridRow:&r column:&c ofIndex:scrollIndex];
        // this won't necessarily trigger setNeedsDisplay:, which we need unconditionally
        [self scrollRectToVisible:[self _rectOfIconInRow:r column:c]];
    }
    [self setNeedsDisplay:YES];
    _fvFlags.isRescaling = NO;
}

- (void)iconUpdated:(FVIcon *)updatedIcon;
{
    // Only iterate icons in the visible range, since we know the overall geometry
    NSRange rowRange, columnRange;
    [self _getRangeOfRows:&rowRange columns:&columnRange inRect:[self visibleRect]];
    
    NSUInteger iMin, iMax = [_controller numberOfIcons];
    
    // _indexForGridRow:column: returns NSNotFound if we're in a short row (empty column)
    iMin = [self _indexForGridRow:rowRange.location column:columnRange.location];
    if (NSNotFound == iMin)
        iMin = [_controller numberOfIcons];
    else
        iMax = MIN([_controller numberOfIcons], iMin + rowRange.length * [self numberOfColumns]);

    NSUInteger i;
    
    // If an icon isn't visible, there's no need to redisplay anything.  Similarly, if 20 icons are displayed and only 5 updated, there's no need to redraw all 20.  Geometry calculations are much faster than redrawing, in general.
    for (i = iMin; i < iMax; i++) {
        
        FVIcon *anIcon = [_controller iconAtIndex:i];
        if (anIcon == updatedIcon) {
            NSUInteger r, c;
            if ([self _getGridRow:&r column:&c ofIndex:i])
                [self _setNeedsDisplayForIconInRow:r column:c];
        }
    }
}

#pragma mark Drawing

// no save/restore needed because of when these are called in -drawRect: (this is why they're private)

- (NSBezierPath *)_insertionHighlightPathInRect:(NSRect)aRect
{
    NSBezierPath *p;
    NSRect rect = aRect;
    // similar to NSTableView's between-row drop indicator
    rect.size.height = NSWidth(aRect);
    rect.origin.y -= NSWidth(aRect);
    p = [NSBezierPath bezierPathWithOvalInRect:rect];
    
    NSPoint point = NSMakePoint(NSMidX(aRect), NSMinY(aRect));
    [p moveToPoint:point];
    point = NSMakePoint(NSMidX(aRect), NSMaxY(aRect));
    [p lineToPoint:point];
    
    rect = aRect;
    rect.origin.y = NSMaxY(aRect);
    rect.size.height = NSWidth(aRect);
    [p appendBezierPathWithOvalInRect:rect];
    
    return p;
}

- (void)_drawDropHighlightInRect:(NSRect)aRect;
{
    [[[NSColor alternateSelectedControlColor] colorWithAlphaComponent:0.8] setStroke];
    [[[NSColor alternateSelectedControlColor] colorWithAlphaComponent:0.2] setFill];
    
    CGFloat lineWidth = 2.0;
    NSBezierPath *p;
    
    if (FVDropInsert == _fvFlags.dropOperation) {
        // insert between icons
        p = [self _insertionHighlightPathInRect:aRect];
    }
    else {
        // it's either a drop on the whole view or on top of a particular icon
        p = [NSBezierPath fv_bezierPathWithRoundRect:NSInsetRect(aRect, 0.5 * lineWidth, 0.5 * lineWidth) xRadius:7 yRadius:7];
    }
    [p setLineWidth:lineWidth];
    [p stroke];
    [p fill];
    [p setLineWidth:1.0];
}

- (void)_drawHighlightInRect:(NSRect)aRect;
{
    CGContextRef drawingContext = [[NSGraphicsContext currentContext] graphicsPort];
    
    // drawing into a CGLayer and then overlaying it keeps the rubber band highlight much more responsive
    if (NULL == _selectionOverlay) {
        
        _selectionOverlay = CGLayerCreateWithContext(drawingContext, CGSizeMake(NSWidth(aRect), NSHeight(aRect)), NULL);
        CGContextRef layerContext = CGLayerGetContext(_selectionOverlay);
        NSRect imageRect = NSZeroRect;
        CGSize layerSize = CGLayerGetSize(_selectionOverlay);
        imageRect.size.height = layerSize.height;
        imageRect.size.width = layerSize.width;
        CGContextClearRect(layerContext, NSRectToCGRect(imageRect));
        
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext *nsContext = [NSGraphicsContext graphicsContextWithGraphicsPort:layerContext flipped:YES];
        [NSGraphicsContext setCurrentContext:nsContext];
        [nsContext saveGraphicsState];
        
        NSColor *strokeColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.8] colorUsingColorSpaceName:NSDeviceRGBColorSpace];
        NSColor *fillColor = [[NSColor colorWithCalibratedWhite:0.0 alpha:0.2] colorUsingColorSpaceName:NSDeviceRGBColorSpace];
        [strokeColor setStroke];
        [fillColor setFill];
        imageRect = NSInsetRect(imageRect, 1.0, 1.0);
        NSBezierPath *p = [NSBezierPath fv_bezierPathWithRoundRect:imageRect xRadius:5 yRadius:5];
        [p setLineWidth:2.0];
        [p fill];
        [p stroke];
        [p setLineWidth:1.0];
        
        [nsContext restoreGraphicsState];
        [NSGraphicsContext restoreGraphicsState];
    }
    // make sure we use source over for drawing the layer
    CGContextSaveGState(drawingContext);
    CGContextSetBlendMode(drawingContext, kCGBlendModeNormal);
    CGContextDrawLayerInRect(drawingContext, NSRectToCGRect(aRect), _selectionOverlay);
    CGContextRestoreGState(drawingContext);
}

- (void)_drawRubberbandRect
{
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.3] setFill];
    NSRect r = [self centerScanRect:NSInsetRect(_rubberBandRect, 0.5, 0.5)];
    NSRectFillUsingOperation(r, NSCompositeSourceOver);
    // NSFrameRect doesn't respect setStroke
    [[NSColor lightGrayColor] setFill];
    NSFrameRectWithWidth(r, 1.0);
}

- (NSMutableAttributedString *)_dropMessageWithFontSize:(CGFloat)fontSize
{
    NSBundle *bundle = [NSBundle bundleForClass:[FileView class]];
    NSString *message = NSLocalizedStringFromTableInBundle(@"Drop Files Here", @"FileView", bundle, @"placeholder message for empty file view");
    NSMutableAttributedString *attrString = [[[NSMutableAttributedString alloc] initWithString:message] autorelease];
    [attrString addAttribute:NSFontAttributeName value:[NSFont boldSystemFontOfSize:fontSize] range:NSMakeRange(0, [attrString length])];
    [attrString addAttribute:NSForegroundColorAttributeName value:[NSColor lightGrayColor] range:NSMakeRange(0, [attrString length])];
    
    NSMutableParagraphStyle *ps = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    [ps setAlignment:NSCenterTextAlignment];
    [attrString addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, [attrString length])];
    [ps release];
    
    return attrString;
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
/*
 Redeclare these CF symbols since they don't have the appropriate __attribute__((weak_import))
 decorator.  This is sufficient to allow checking for NULL (tested on 10.4.11 Server).
 rdar://problem/6781636
 */
CF_EXPORT
CFStringTokenizerRef CFStringTokenizerCreate(CFAllocatorRef alloc, CFStringRef string, CFRange range, CFOptionFlags options, CFLocaleRef locale) AVAILABLE_MAC_OS_X_VERSION_10_5_AND_LATER;
CF_EXPORT
CFStringTokenizerTokenType CFStringTokenizerAdvanceToNextToken(CFStringTokenizerRef tokenizer) AVAILABLE_MAC_OS_X_VERSION_10_5_AND_LATER;
CF_EXPORT
CFTypeRef CFStringTokenizerCopyCurrentTokenAttribute(CFStringTokenizerRef tokenizer, CFOptionFlags attribute) AVAILABLE_MAC_OS_X_VERSION_10_5_AND_LATER;
#endif

static NSArray * _wordsFromAttributedString(NSAttributedString *attributedString)
{
    NSString *string = [attributedString string];

    if (NULL == CFStringTokenizerCreate)
        return [string componentsSeparatedByString:@" "];
    
    CFStringTokenizerRef tokenizer = CFStringTokenizerCreate(NULL, (CFStringRef)string, CFRangeMake(0, [string length]), kCFStringTokenizerUnitWord, NULL);
    NSMutableArray *words = [NSMutableArray array];
    while (kCFStringTokenizerTokenNone != CFStringTokenizerAdvanceToNextToken(tokenizer)) {
        CFStringRef word = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription);
        if (word) {
            [words addObject:(id)word];
            CFRelease(word);
        }
    }
    CFRelease(tokenizer);
    return words;
}

- (CGFloat)_widthOfLongestWordInDropMessage
{
    NSMutableAttributedString *message = [self _dropMessageWithFontSize:DROP_MESSAGE_MIN_FONTSIZE];
    NSString *word;
    NSArray *words = _wordsFromAttributedString(message);
    NSUInteger i, wordCount = [words count];
    CGFloat width = 0;
    for (i = 0; i < wordCount; i++) {
        word = [words objectAtIndex:i];
        [[message mutableString] setString:word];
        width = MAX(width, NSWidth([message boundingRectWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin]));
    }
    return ceil(width);
}

- (void)_drawDropMessage;
{
    CGFloat minWidth = [self _widthOfLongestWordInDropMessage];    
    NSRect visibleRect = [self visibleRect];
    CGFloat containerInset = (NSWidth(visibleRect) - minWidth) / 2.0;
    containerInset = MIN(containerInset, DROP_MESSAGE_MAX_INSET);
    NSRect containerRect = containerInset > 0 ? [self centerScanRect:NSInsetRect(visibleRect, containerInset, containerInset)] : visibleRect;
    
    // avoid drawing text right up to the path at small widths (inset < 20)
    NSRect pathRect;
    if (containerInset < DROP_MESSAGE_MAX_INSET)
        pathRect = NSInsetRect(containerRect, -2, -2);
    else
        pathRect = NSInsetRect(visibleRect, DROP_MESSAGE_MAX_INSET, DROP_MESSAGE_MAX_INSET);
    
    // negative inset at small view widths may extend outside the view; in that case, don't draw the path
    if (NSContainsRect(visibleRect, pathRect)) {
        NSBezierPath *path = [NSBezierPath fv_bezierPathWithRoundRect:[self centerScanRect:pathRect] xRadius:10 yRadius:10];
        CGFloat pattern[2] = { 12.0, 6.0 };
        
        // This sets all future paths to have a dash pattern, and it's not affected by save/restore gstate on Tiger.  Lame.
        CGFloat previousLineWidth = [path lineWidth];
        // ??? make this a continuous function of width <= 3
        [path setLineWidth:(NSWidth(containerRect) > 100 ? 3.0 : 2.0)];
        [path setLineDash:pattern count:2 phase:0.0];
        [[NSColor lightGrayColor] setStroke];
        [path stroke];
        [path setLineWidth:previousLineWidth];
        [path setLineDash:NULL count:0 phase:0.0];
    }
    
    CGFloat fontSize = 24.0;
    NSMutableAttributedString *message = [self _dropMessageWithFontSize:fontSize];
    CGFloat singleLineHeight = NSHeight([message boundingRectWithSize:containerRect.size options:0]);
    
    // NSLayoutManager's defaultLineHeightForFont doesn't include padding that NSStringDrawing uses
    NSRect r = [message boundingRectWithSize:containerRect.size options:NSStringDrawingUsesLineFragmentOrigin];
    NSUInteger wordCount = [_wordsFromAttributedString(message) count];
    
    // reduce font size until we have no more than wordCount lines
    while (fontSize > DROP_MESSAGE_MIN_FONTSIZE && NSHeight(r) > wordCount * singleLineHeight) {
        fontSize -= 1.0;
        [message addAttribute:NSFontAttributeName value:[NSFont boldSystemFontOfSize:fontSize] range:NSMakeRange(0, [message length])];
        singleLineHeight = NSHeight([message boundingRectWithSize:containerRect.size options:0]);
        r = [message boundingRectWithSize:containerRect.size options:NSStringDrawingUsesLineFragmentOrigin];
    }
    containerRect.origin.y = (NSHeight(containerRect) - NSHeight(r)) / 2;
    
    // draw nothing if words are broken across lines, or the font size is too small
    if (fontSize >= DROP_MESSAGE_MIN_FONTSIZE && NSHeight(r) <= wordCount * singleLineHeight)
        [message drawWithRect:containerRect options:NSStringDrawingUsesLineFragmentOrigin];
}

- (void)handleKeyOrMainNotification:(NSNotification *)aNote
{
    [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToWindow;
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSWindow *window = [self window];
    if (window) {
        /*
         For redrawing the "magic" sourcelist background color.  The 10.5 AppKit color evidently changes based on main 
         status, but key status must also be observed for a utility window. A spurious redraw from observing both 
         notifications is not a problem, in any event.
         */
        [nc addObserver:self selector:@selector(handleKeyOrMainNotification:) name:NSWindowDidBecomeMainNotification object:window];
        [nc addObserver:self selector:@selector(handleKeyOrMainNotification:) name:NSWindowDidResignMainNotification object:window];
        [nc addObserver:self selector:@selector(handleKeyOrMainNotification:) name:NSWindowDidBecomeKeyNotification object:window];
        [nc addObserver:self selector:@selector(handleKeyOrMainNotification:) name:NSWindowDidResignKeyNotification object:window];
    }
    else {
        [nc removeObserver:self name:NSWindowDidBecomeMainNotification object:nil];
        [nc removeObserver:self name:NSWindowDidResignMainNotification object:nil];
        [nc removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
        [nc removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    }
}

// redraw at full quality after a resize
- (void)viewDidEndLiveResize
{
    [super viewDidEndLiveResize];
    [self setNeedsDisplay:YES];
    _fvFlags.scheduledLiveResize = NO;
}

// only invoked when autoscrolling or in response to user action
- (NSRect)adjustScroll:(NSRect)proposedVisibleRect
{    
    NSRect r = [super adjustScroll:proposedVisibleRect];
    _timeOfLastOrigin = CFAbsoluteTimeGetCurrent();
    _lastOrigin = [self visibleRect].origin;
    // Mojave has some kind of weird scroll updating bug where the background isn't drawn; it seems to need copying
    if (floor(NSAppKitVersionNumber) > 1561.61 /*NSAppKitVersionNumber10_13*/)
        [self setNeedsDisplayInRect:proposedVisibleRect];
    return r;
}

// positive = scroller moving down
// negative = scroller moving upward
- (CGFloat)_scrollVelocity
{
    return ([self visibleRect].origin.y - _lastOrigin.y) / (CFAbsoluteTimeGetCurrent() - _timeOfLastOrigin);
}

/*
 This method is conservative.  It doesn't test icon rects for intersection in the rect 
 argument, but simply estimates the maximum range of rows and columns required for 
 complete drawing in the given rect.  Hence, it can't be used for determining rubber 
 band selection indexes or anything requiring a precise range (this is why it's private), 
 but it's guaranteed to be fast.
 */
- (void)_getRangeOfRows:(NSRange *)rowRange columns:(NSRange *)columnRange inRect:(NSRect)aRect;
{
    NSUInteger rmin, rmax, cmin, cmax;
    
    NSRect bounds = [self bounds];
    
    // account for padding around edges of the view
    bounds.origin.x += [self _leftMargin];
    bounds.origin.y += [self _topMargin];
    
    rmin = (NSMinY(aRect) - NSMinY(bounds)) / [self _rowHeight];
    rmax = (NSMinY(aRect) - NSMinY(bounds)) / [self _rowHeight] + NSHeight(aRect) / [self _rowHeight];
    // add 1 to account for integer truncation
    rmax = MIN(rmax + 1, [self numberOfRows]);
    
    cmin = (NSMinX(aRect) - NSMinX(bounds)) / [self _columnWidth];
    cmax = (NSMinX(aRect) - NSMinX(bounds)) / [self _columnWidth] + NSWidth(aRect) / [self _columnWidth];
    // add 1 to account for integer truncation
    cmax = MIN(cmax + 1, [self numberOfColumns]);

    rowRange->location = rmin;
    rowRange->length = rmax - rmin;
    columnRange->location = cmin;
    columnRange->length = cmax - cmin; 
}

- (BOOL)_isFastScrolling { return ABS([self _scrollVelocity]) > 10000.0f; }

- (void)_scheduleIconsInRange:(NSRange)indexRange;
{
    NSMutableIndexSet *visibleIndexes = [NSMutableIndexSet indexSetWithIndexesInRange:indexRange];

    /*
     this method is now called with only the icons being drawn, not necessarily everything 
     that's visible; we need to compute visibility to avoid calling -releaseResources on the wrong icons
     */
    NSRange visRows, visCols;
    [self _getRangeOfRows:&visRows columns:&visCols inRect:[self visibleRect]];
    NSUInteger iMin, iMax = [_controller numberOfIcons];
    
    // _indexForGridRow:column: returns NSNotFound if we're in a short row (empty column)
    iMin = [self _indexForGridRow:visRows.location column:visCols.location];
    if (NSNotFound == iMin)
        iMin = [_controller numberOfIcons];
    else
        iMax = MIN([_controller numberOfIcons], iMin + visRows.length * [self numberOfColumns]);
    
    if (iMax > iMin)
        [visibleIndexes addIndexesInRange:NSMakeRange(iMin, iMax - iMin)];
                
    // Queuing will call needsRenderForSize: after initial display has taken place, since it may flush the icon's cache
    // this isn't obvious from the method name; it all takes place in a single op to avoid locking twice
    
    // enqueue visible icons with high priority
    NSArray *iconsToRender = [_controller iconsAtIndexes:visibleIndexes];
    [_controller enqueueRenderOperationForIcons:iconsToRender checkSize:_iconSize];
        
    /*
     Call this only for icons that we're not going to display "soon."  The problem with this 
     approach is that if you only have a single icon displayed at a time (say in a master-detail view), 
     FVIcon cache resources will continue to be used up since each one is cached and then never 
     touched again (if it doesn't show up in this loop, that is).  We handle this by using a timer 
     that culls icons which are no longer present in the datasource.  I suppose this is only a 
     symptom of the larger problem of a view maintaining a cache of model objects...but expecting 
     a client to be aware of our caching strategy and icon management is a bit much.  
     */
    
    // Don't release resources while scrolling; caller has already checked -inLiveResize and _isRescaling for us

    if (NO == [self _isFastScrolling]) {
        
        // make sure we don't call this on any icons that we just added to the render queue
        NSMutableIndexSet *unusedIndexes = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [_controller numberOfIcons])];
        [unusedIndexes removeIndexes:visibleIndexes];
        
        // If scrolling quickly, avoid releasing icons that may become visible
        CGFloat velocity = [self _scrollVelocity];
        
        if (ABS(velocity) > 10.0f && [unusedIndexes count] > 0) {
            // going down: don't release anything between end of visible range and the last icon
            // going up: don't release anything between the first icon and the start of visible range
            if (velocity > 0) { 
                [unusedIndexes removeIndexesInRange:NSMakeRange([visibleIndexes lastIndex], [_controller numberOfIcons] - [visibleIndexes lastIndex])];
            }
            else {
                [unusedIndexes removeIndexesInRange:NSMakeRange(0, [visibleIndexes firstIndex])];
            }
        }

        if ([unusedIndexes count]) {
            /*
             Since the same FVIcon instance is returned for duplicate URLs, the same icon 
             instance may receive -renderOffscreen and -releaseResources in the same pass 
             if it represents a visible icon and a hidden icon.
             */
            NSSet *renderSet = [[NSSet alloc] initWithArray:iconsToRender];
            NSMutableArray *unusedIcons = [[_controller iconsAtIndexes:unusedIndexes] mutableCopy];
            NSUInteger i = [unusedIcons count];
            while (i--) {
                FVIcon *anIcon = [unusedIcons objectAtIndex:i];
                if ([renderSet containsObject:anIcon])
                    [unusedIcons removeObjectAtIndex:i];
            }
            [_controller enqueueReleaseOperationForIcons:unusedIcons];
            [renderSet release];
            [unusedIcons release];
        }
        
    }
}

- (void)_drawIconsInRange:(NSRange)indexRange rows:(NSRange)rows columns:(NSRange)columns
{
    BOOL isResizing = [self inLiveResize];

    NSUInteger r, rMin = rows.location, rMax = NSMaxRange(rows);
    NSUInteger c, cMin = columns.location, cMax = NSMaxRange(columns);
    NSUInteger i;
        
    NSGraphicsContext *ctxt = [NSGraphicsContext currentContext];
    CGContextRef cgContext = [ctxt graphicsPort];
    CGContextSetBlendMode(cgContext, kCGBlendModeNormal);
    
    // don't limit quality based on scrolling unless we really need to
    if (isResizing || _fvFlags.isRescaling) {
        CGContextSetInterpolationQuality(cgContext, kCGInterpolationNone);
        CGContextSetShouldAntialias(cgContext, false);
    }
    else if (_iconSize.height > 256) {
        CGContextSetInterpolationQuality(cgContext, kCGInterpolationHigh);
        CGContextSetShouldAntialias(cgContext, true);
    }
    else {
        CGContextSetInterpolationQuality(cgContext, kCGInterpolationDefault);
        CGContextSetShouldAntialias(cgContext, true);
    }
    
    // http://lists.apple.com/archives/Cocoa-dev/2008/Jul/msg02539.html indicates this is a good idea; I don't see a difference
    if (_fvFlags.isDrawingDragImage)
        CGContextSetShouldSmoothFonts(cgContext, false);
            
    BOOL isDrawingToScreen = [ctxt isDrawingToScreen];
    
    // we should use the fast path when scrolling at small sizes; PDF sucks in that case...
    
    BOOL useFastDrawingPath = (isResizing || _fvFlags.isRescaling || ([self _isFastScrolling] && _iconSize.height <= 256));
    
    // redraw at high quality after scrolling
    if (useFastDrawingPath && NO == _fvFlags.scheduledLiveResize && [self _isFastScrolling]) {
        _fvFlags.scheduledLiveResize = YES;
        [self performSelector:@selector(viewDidEndLiveResize) withObject:nil afterDelay:0 inModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
    }
    
    // shadow needs to be scaled as the icon scale changes to approximate the IconServices shadow
    CGFloat shadowBlur = 2.0 * [self iconScale];
    CGSize shadowOffset = CGSizeMake(0.0, -[self iconScale]);
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    CGFloat shadowComponents[] = { 0, 0, 0, 0.4 };
    CGColorRef shadowColor = CGColorCreate(cspace, shadowComponents);
    CGColorSpaceRelease(cspace);
    
    NSDictionary *titleAttributes = [self _titleAttributes];
    NSDictionary *labeledAttributes = [self _labeledAttributes];
    NSDictionary *subtitleAttributes = [self _subtitleAttributes];
    
    // iterate each row/column to see if it's in the dirty rect, and evaluate the current cache state
    for (r = rMin; r < rMax; r++) 
    {
        for (c = cMin; c < cMax && NSNotFound != (i = [self _indexForGridRow:r column:c]); c++) 
        {
            // if we're creating a drag image, only draw selected icons
            if (NO == _fvFlags.isDrawingDragImage || [_selectedIndexes containsIndex:i]) {
            
                NSRect iconRect = [self _rectOfIconInRow:r column:c];
                NSURL *aURL = [_controller URLAtIndex:i];
                NSRect textRect = [self _rectOfTextForIconRect:iconRect];
                
                // always draw icon and text together, as they may overlap due to shadow and finder label, and redrawing a part may look odd
                BOOL willDrawIcon = _fvFlags.isDrawingDragImage || [self needsToDrawRect:NSUnionRect(NSInsetRect(iconRect, -2.0 * [self iconScale], 0), textRect)];

                if (willDrawIcon) {

                    FVIcon *image = [_controller iconAtIndex:i];
                    
                    /*
                     Note that imageRect will be transformed for a flipped context.  The inset allows for highlight, 
                     which otherwise extends outside the box and ends up getting drawn over when iconUpdate: or various
                     other methods are called.  It would be possible to adjust _setNeedsDisplayForIconInRow:column: to
                     compensate, but then we have consistency issues, since the "iconRect" meaning is less clear.
                     */
                    const CGFloat highlightOffset = 2;
                    NSRect imageRect = NSInsetRect(iconRect, highlightOffset, highlightOffset);
                    imageRect.origin.y += highlightOffset;
                    
                    // draw highlight, then draw icon over it, as Finder does
                    if ([_selectedIndexes containsIndex:i])
                        [self _drawHighlightInRect:NSInsetRect(imageRect, -2 * highlightOffset, -2 * highlightOffset)];
                    
                    CGContextSaveGState(cgContext);
                    
                    // draw a shadow behind the image/page
                    CGContextSetShadowWithColor(cgContext, shadowOffset, shadowBlur, shadowColor);
                    
                    // possibly better performance by caching all bitmaps in a flipped state, but bookkeeping is a pain
                    CGContextTranslateCTM(cgContext, 0, NSMaxY(imageRect));
                    CGContextScaleCTM(cgContext, 1, -1);
                    imageRect.origin.y = 0;
                    
                    /*
                     Note: don't use integral rects here to avoid res independence issues 
                     (on Tiger, centerScanRect: just makes an integral rect).  The icons may 
                     create an integral bitmap context, but it'll still be drawn into this rect 
                     with correct scaling.
                     */
                    imageRect = [self centerScanRect:imageRect];
                    
                    if (NO == isDrawingToScreen && [image needsRenderForSize:_iconSize])
                        [image renderOffscreen];
                                    
                    if (useFastDrawingPath)
                        [image fastDrawInRect:imageRect ofContext:cgContext];
                    else
                        [image drawInRect:imageRect ofContext:cgContext];
                    
                    CGContextRestoreGState(cgContext);
                    CGContextSaveGState(cgContext);
                    
                    textRect = [self centerScanRect:textRect];
                    
                    // draw Finder label and text over the icon/shadow
                    
                    NSString *name, *subtitle = [_controller subtitleAtIndex:i];
                    NSUInteger label;
                    [_controller getDisplayName:&name andLabel:&label forURL:aURL];
                    NSStringDrawingOptions stringOptions = NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingOneShot;
                    const CGFloat titleHeight = [self _titleHeight];
                    
                    if (label > 0) {
                        CGRect labelRect = NSRectToCGRect(textRect);
                        labelRect.size.height = titleHeight;                        
                        [FVFinderLabel drawFinderLabel:label inRect:labelRect ofContext:cgContext flipped:YES roundEnds:YES];
                        
                        // labeled title uses black text for greater contrast; inset horizontally because of the rounded end caps
                        NSRect titleRect = NSInsetRect(textRect, titleHeight / 2.0, 0);
                        [name drawWithRect:titleRect options:stringOptions attributes:labeledAttributes];
                    }
                    else {
                        [name drawWithRect:textRect options:stringOptions attributes:titleAttributes];
                    }
                    
                    if (subtitle) {
                        textRect.origin.y += titleHeight;
                        textRect.size.height -= titleHeight;
                        [subtitle drawWithRect:textRect options:stringOptions attributes:subtitleAttributes];
                    }
                    CGContextRestoreGState(cgContext);
                } 
#if DEBUG_GRID
                [NSGraphicsContext saveGraphicsState];
                if (c % 2 && !(r % 2))
                    [[NSColor redColor] setFill];
                else
                    [[NSColor greenColor] setFill];
                NSFrameRect(NSUnionRect(NSInsetRect(iconRect, -2.0 * [self iconScale], 0), textRect));                
                [NSGraphicsContext restoreGraphicsState];
#endif
            }
        }
    }
    
    CGColorRelease(shadowColor);
    
    // avoid hitting the cache thread while a live resize is in progress, but allow cache updates while scrolling
    // use the same range criteria that we used in iterating icons
    NSUInteger iMin = indexRange.location, iMax = NSMaxRange(indexRange);
    if (NO == isResizing && NO == _fvFlags.isRescaling && isDrawingToScreen)
        [self _scheduleIconsInRange:NSMakeRange(iMin, iMax - iMin)];
}

- (NSRect)_rectOfProgressIndicatorForIconAtIndex:(NSUInteger)anIndex;
{
    NSUInteger r, c;
    NSRect frame = NSZeroRect;
    if ([self _getGridRow:&r column:&c ofIndex:anIndex]) {    
        frame = [self _rectOfIconInRow:r column:c];
        NSPoint center = NSMakePoint(NSMidX(frame), NSMidY(frame));
        
        CGFloat size = NSHeight(frame) / 2;
        frame.size.height = size;
        frame.size.width = size;
        frame.origin.x = center.x - NSWidth(frame) / 2;
        frame.origin.y = center.y - NSHeight(frame) / 2;
    }
    return frame;
}

- (void)_drawProgressIndicatorForDownloads
{
    NSArray *downloads = [_controller downloads];
    NSUInteger idx, downloadCount = [downloads count];
    
    for (idx = 0; idx < downloadCount; idx++) {
        
        FVDownload *download = [downloads objectAtIndex:idx];
        NSUInteger anIndex = [download indexInView];
    
        // we only draw a if there's an active download for this URL/index pair
        if (anIndex < [_controller numberOfIcons] && [[_controller URLAtIndex:anIndex] isEqual:[download downloadURL]]) {
            NSRect frame = [self _rectOfProgressIndicatorForIconAtIndex:anIndex];
            [[download progressIndicator] drawWithFrame:frame inView:self];
        }
    }
}

- (void)_fillBackgroundColorOrGradientInRect:(NSRect)rect
{
    /*
     If you reset color in a nib inspector on 10.7, a nil color is archived in the nib
     and will take precendence over the +defaultBackgroundColor.  Likewise, if you
     intentionally called setBackgroundColor:nil for some reason, you could end up
     in the gradient code path on 10.6 and earlier.  We'll just dodge that problem
     by declaring that a nil value means that you want the default color.  It doesn't
     make sense to do anything more elaborate, since the nib inspector is gone in
     Xcode 4 and later.
     
     The second condition is for nibs that have been previously set up on 10.6 and
     earlier, so may have the source list color archived.  We don't want to use 
     that on 10.7, so hack around it.
     */
    if (floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6 && [self backgroundColor] == nil)
        [self setBackgroundColor:[[self class] defaultBackgroundColor]];
    else if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_6 && [[self backgroundColor] isKindOfClass:NSClassFromString(@"NSSourceListBackgroundColor")])
        [self setBackgroundColor:nil];
    
    // any solid color background should override the gradient code
    if ([self backgroundColor]) {
        [NSGraphicsContext saveGraphicsState];
        [[self backgroundColor] setFill];
        NSRectFillUsingOperation(rect, NSCompositeCopy);
        [NSGraphicsContext restoreGraphicsState];
    }
    else if (floor(NSAppKitVersionNumber) >= NSAppKitVersionNumber10_14) {
        [NSGraphicsContext saveGraphicsState];
        // magic color for dark mode; I like the bluish color better, especially for activation status, but…sigh
        [[NSColor controlBackgroundColor] setFill];
        NSRectClip(rect);
        NSRectFillUsingOperation(rect, NSCompositeCopy);
        [NSGraphicsContext restoreGraphicsState];
    }
    else {
        /*
         The NSTableView magic source list color no longer works properly on 10.7, either
         because they changed it from a solid color to a gradient, or just changed the
         drawing.  I couldn't see a reasonable way to subclass NSColor and draw a gradient
         as Apple does, or to force the color to update properly, so we'll just cheat and
         do it the easy way.  Using 10.5 and later API is okay, since 10.4 gets a solid
         color anyway.
         */
        FVAPIAssert(floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_6, @"gradient background is only available on 10.7 and later");
        
        // otherwise we see a blocky transition, which fades on the redraw when scrolling stops
        if ([[[self enclosingScrollView] contentView] copiesOnScroll])
            [[[self enclosingScrollView] contentView] setCopiesOnScroll:NO];
        
        // should be RGBA space, since we're drawing to the screen
        CGColorSpaceRef cspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
        const CGFloat locations[] = { 0, 1 };
        CGGradientRef gradient;
        
        // color values from DigitalColor Meter on 10.7, using Generic RGB space
        if ([[self window] isKeyWindow] || [[self window] isMainWindow]) {
            // ordered as lower/upper
            const CGFloat components[8] = { 198.0 / 255.0, 207.0 / 255.0, 216.0 / 255.0, 1.0, 227.0 / 255.0, 232.0 / 255.0, 238.0 / 255.0, 1.0 };
            gradient = CGGradientCreateWithColorComponents(cspace, components, locations, 2);
        }
        else {
            // ordered as lower/upper
            const CGFloat components[8] = { 230.0 / 255.0, 230.0 / 255.0, 230.0 / 255.0, 1.0, 246.0 / 255.0, 246.0 / 255.0, 246.0 / 255.0, 1.0 };
            gradient = CGGradientCreateWithColorComponents(cspace, components, locations, 2);
        }
        CGContextRef ctxt = [[NSGraphicsContext currentContext] graphicsPort];

        // only draw the dirty part, but we need to use the full visible bounds as the gradient extent
        CGContextSaveGState(ctxt);
        CGContextClipToRect(ctxt, NSRectToCGRect(rect));
        const NSRect bounds = [self visibleRect];
        CGContextDrawLinearGradient(ctxt, gradient, CGPointMake(0, NSMaxY(bounds)), CGPointMake(0, NSMinY(bounds)), 0);
        CGContextRestoreGState(ctxt);

        CGGradientRelease(gradient);
        CGColorSpaceRelease(cspace);
    }
}

- (void)drawRect:(NSRect)rect;
{    
    
    // !!! early return
    if (_fvFlags.reloadingController) {
        FVLog(@"FileView: skipping an unsafe redraw request while reloading the controller.");
        return;
    }
        
    BOOL isDrawingToScreen = [[NSGraphicsContext currentContext] isDrawingToScreen];

    if (isDrawingToScreen)
        [self _fillBackgroundColorOrGradientInRect:rect];
        
    // Only iterate icons in the visible range, since we know the overall geometry
    NSRange rowRange, columnRange;
    [self _getRangeOfRows:&rowRange columns:&columnRange inRect:rect];
    
    NSUInteger iMin, iMax = [_controller numberOfIcons];
    
    // _indexForGridRow:column: returns NSNotFound if we're in a short row (empty column)
    iMin = [self _indexForGridRow:rowRange.location column:columnRange.location];
    if (NSNotFound == iMin)
        iMin = [_controller numberOfIcons];
    else
        iMax = MIN([_controller numberOfIcons], iMin + rowRange.length * [self numberOfColumns]);

    // only draw icons if we actually have some in this rect
    if (iMax > iMin) {
        [self _drawIconsInRange:NSMakeRange(iMin, iMax - iMin) rows:rowRange columns:columnRange];
    }
    else if (0 == iMax && [self isEditable]) {
        [[NSGraphicsContext currentContext] setShouldAntialias:YES];
        [self _drawDropMessage];
    }
    
    if (isDrawingToScreen) {
        
        if ((_fvFlags.hasArrows || _fvFlags.isAnimatingArrowAlpha) && _fvFlags.isDrawingDragImage == NO) {
            if (NSIntersectsRect(rect, _leftArrowFrame))
                [(FVArrowButtonCell *)_leftArrow drawWithFrame:_leftArrowFrame inView:self alpha:_arrowAlpha];
            if (NSIntersectsRect(rect, _rightArrowFrame))
                [(FVArrowButtonCell *)_rightArrow drawWithFrame:_rightArrowFrame inView:self alpha:_arrowAlpha];
        }
        
        // drop highlight and rubber band are mutually exclusive
        if (FVDropNone != _fvFlags.dropOperation) {
            [self _drawDropHighlightInRect:[self centerScanRect:_dropRectForHighlight]];
        }
        else if (NSIsEmptyRect(_rubberBandRect) == NO) {
            [self _drawRubberbandRect];
        }
        
        [self _drawProgressIndicatorForDownloads];
    }
#if DEBUG_GRID 
    [[NSColor grayColor] set];
    NSFrameRect(NSInsetRect([self bounds], [self _leftMargin], [self _topMargin]));
#endif
    
}

#pragma mark Drag source

- (void)draggedImage:(NSImage *)image endedAt:(NSPoint)screenPoint operation:(NSDragOperation)operation;
{
    // only called if we originated the drag, so the row/column must be valid
    if ((operation & NSDragOperationDelete) != 0 && [self isEditable]) {
        // pass copy of _selectionIndexes
        [[self dataSource] fileView:self deleteURLsAtIndexes:[self selectionIndexes]];
        [self setSelectionIndexes:[NSIndexSet indexSet]];
        [self reloadIcons];
    }
}

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    /*
     Adding NSDragOperationLink for non-local drags gives us behavior similar to the 
     NSDocument proxy icon, allowing the receiving app to decide what is appropriate; 
     hence, in Finder it now defaults to alias, and you can use option to force a copy.
     */
    NSDragOperation mask = NSDragOperationCopy | NSDragOperationLink;
    if (isLocal)
        mask |= NSDragOperationMove;
    else if ([self isEditable])
        mask |= NSDragOperationDelete;
    return mask;
}

- (void)dragImage:(NSImage *)anImage at:(NSPoint)viewLocation offset:(NSSize)unused event:(NSEvent *)event pasteboard:(NSPasteboard *)pboard source:(id)sourceObj slideBack:(BOOL)slideFlag;
{
    id scrollView = [self enclosingScrollView];
    NSRect boundsRect;
    if (nil == scrollView) {
        scrollView = self;
        boundsRect = [self bounds];
    }
    else {
        boundsRect = [scrollView convertRect:[scrollView documentVisibleRect] fromView:self];
    }
    
    NSPoint dragPoint = [scrollView bounds].origin;
    dragPoint.y += NSHeight([scrollView bounds]);
    dragPoint = [scrollView convertPoint:dragPoint toView:self];
    
    // this will force a redraw of the entire area into the cached image
    NSBitmapImageRep *imageRep = [scrollView bitmapImageRepForCachingDisplayInRect:boundsRect];
    
    // set a flag so only the selected icons are drawn and background is set to clear
    _fvFlags.isDrawingDragImage = YES;    
    [scrollView cacheDisplayInRect:boundsRect toBitmapImageRep:imageRep];
    _fvFlags.isDrawingDragImage = NO;

    NSImage *newImage = [[[NSImage alloc] initWithSize:boundsRect.size] autorelease];
    [newImage addRepresentation:imageRep];
    
    // redraw with transparency, so it's easier to see a target
    anImage = [[[NSImage alloc] initWithSize:boundsRect.size] autorelease];
    [anImage lockFocus];
    [newImage drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositeCopy fraction:0.7];
    [anImage unlockFocus];
    newImage = anImage;
    
    [super dragImage:newImage at:dragPoint offset:unused event:event pasteboard:pboard source:sourceObj slideBack:slideFlag];
}

#pragma mark Event handling

- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)canBecomeKeyView { return YES; }

- (void)scrollWheel:(NSEvent *)event
{
    // Run in NSEventTrackingRunLoopMode for scroll wheel events, in order to avoid continuous tracking/tooltip rect resets while scrolling.
    while ((event = [NSApp nextEventMatchingMask:NSScrollWheelMask untilDate:[NSDate dateWithTimeIntervalSinceNow:0.5] inMode:NSEventTrackingRunLoopMode dequeue:YES]))
        [super scrollWheel:event];
}

- (void)_updateButtonsForIcon:(FVIcon *)anIcon;
{
    NSUInteger curPage = [anIcon currentPageIndex];
    [_leftArrow setEnabled:curPage != 1];
    [_rightArrow setEnabled:curPage != [anIcon pageCount]];
    NSUInteger r, c;
    /*
     _getGridRow should always succeed.  Drawing entire icon since a mouseover can occur 
     between the time the icon is loaded and drawn, so only the part of the icon below 
     the buttons is drawn (at least, I think that's what happens...)
     */
    if ([self _getGridRow:&r column:&c atPoint:_leftArrowFrame.origin])
        [self _setNeedsDisplayForIconInRow:r column:c];
}

- (void)_redisplayIconAfterPageChanged:(FVIcon *)anIcon
{
    [self _updateButtonsForIcon:anIcon];
    NSUInteger r, c;
    // _getGridRow should always succeed; either arrow frame would work here, since both are in the same icon
    if ([self _getGridRow:&r column:&c atPoint:_leftArrowFrame.origin]) {
        // render immediately so the placeholder path doesn't draw
        if ([anIcon needsRenderForSize:_iconSize])
            [anIcon renderOffscreen];
        [self _setNeedsDisplayForIconInRow:r column:c];
    }    
}

- (void)leftArrowAction:(id)sender
{
    FVIcon *anIcon = [_leftArrow representedObject];
    [anIcon showPreviousPage];
    [self _redisplayIconAfterPageChanged:anIcon];
}

- (void)rightArrowAction:(id)sender
{
    FVIcon *anIcon = [_rightArrow representedObject];
    [anIcon showNextPage];
    [self _redisplayIconAfterPageChanged:anIcon];
}

// note that hasArrows has to have the desired state before this fires
- (void)_updateArrowAlpha:(NSTimer *)timer
{
    NSAnimation *animation = [timer userInfo];
    CGFloat value = [animation currentValue];
    if (value > 0.99) {
        [animation stopAnimation];
        [timer invalidate];
        _fvFlags.isAnimatingArrowAlpha = NO;
        _arrowAlpha = _fvFlags.hasArrows ? 1.0 : 0.0;
    }
    else {
        _arrowAlpha = _fvFlags.hasArrows ? value : (1 - value);
    }
    [self setNeedsDisplayInRect:NSUnionRect(_leftArrowFrame, _rightArrowFrame)];
}

- (void)_startArrowAlphaTimer
{
    _fvFlags.isAnimatingArrowAlpha = YES;
    // animate ~30 fps for 0.3 seconds, using NSAnimation to get the alpha curve
    NSAnimation *animation = [[NSAnimation alloc] initWithDuration:0.3 animationCurve:NSAnimationEaseInOut]; 
    // runloop mode is irrelevant for non-blocking threaded
    [animation setAnimationBlockingMode:NSAnimationNonblockingThreaded];
    // explicitly alloc/init so it can be added to all the common modes instead of the default mode
    NSTimer *timer = [[NSTimer alloc] initWithFireDate:[NSDate date]
                                              interval:0.03
                                                target:self 
                                              selector:@selector(_updateArrowAlpha:)
                                              userInfo:animation
                                               repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:(NSString *)kCFRunLoopCommonModes];
    [timer release];
    [animation startAnimation];
    [animation release];  
}

- (void)_showArrowsForIconAtIndex:(NSUInteger)anIndex
{
    NSUInteger r, c;
    
    // this can happen if we screwed up in managing cursor rects
    NSParameterAssert(anIndex < [_controller numberOfIcons]);
    
    if ([self _getGridRow:&r column:&c ofIndex:anIndex]) {
    
        FVIcon *anIcon = [_controller iconAtIndex:anIndex];
        
        if ([anIcon pageCount] > 1) {
        
            NSRect iconRect = [self _rectOfIconInRow:r column:c];
            
            // determine a min/max size for the arrow buttons
            CGFloat side = round(NSHeight(iconRect) / 5);
            side = MIN(side, 32);
            side = MAX(side, 10);
            // 2 pixels between arrows horizontally, and 4 pixels between bottom of arrow and bottom of iconRect
            _leftArrowFrame = _rightArrowFrame = NSMakeRect(NSMidX(iconRect) + 2, NSMaxY(iconRect) - side - 4, side, side);
            _leftArrowFrame.origin.x -= side + 4;
            
            [_leftArrow setRepresentedObject:anIcon];
            [_rightArrow setRepresentedObject:anIcon];
            _fvFlags.hasArrows = YES;

            // set enabled states
            [self _updateButtonsForIcon:anIcon];  
                        
            if (_fvFlags.isAnimatingArrowAlpha) {
                // make sure we redraw whatever area previously had the arrows
                [self setNeedsDisplay:YES];
            }
            else {
                [self _startArrowAlphaTimer];
            }
        }
    }
}

- (void)_hideArrows
{
    if (_fvFlags.hasArrows) {
        _fvFlags.hasArrows = NO;
        [_leftArrow setRepresentedObject:nil];
        [_rightArrow setRepresentedObject:nil];
        if (NO == _fvFlags.isAnimatingArrowAlpha)
            [self _startArrowAlphaTimer];
    }
}

- (void)mouseEntered:(NSEvent *)event;
{
    const NSTrackingRectTag tag = [event trackingNumber];
    NSInteger anIndex;
    
    /*
     Finder doesn't show buttons unless it's the front app.  If Finder is the front app, 
     it shows them for any window, regardless of main/key state, so we'll do the same.
     */
    if ([NSApp isActive]) {
        if (FVCFDictionaryGetIntegerIfPresent(_trackingRectMap, (const void *)tag, &anIndex))
            [self _showArrowsForIconAtIndex:anIndex];
        else if ([self _showsSlider] && [event userData] == _sliderWindow) {
            
            if ([[[self window] childWindows] containsObject:_sliderWindow] == NO) {
                NSRect sliderRect = [self _sliderRect];
                sliderRect = [self convertRect:sliderRect toView:nil];
                sliderRect = [[self window] convertRectToScreen:sliderRect];
                // looks cool to use -animator here, but makes it hard to hit...
                if (NSEqualRects([_sliderWindow frame], sliderRect) == NO)
                    [_sliderWindow setFrame:sliderRect display:NO];
                
                [[self window] addChildWindow:_sliderWindow ordered:NSWindowAbove];
                [[_sliderWindow animator] setAlphaValue:1.0];
            }
        }
    }
    
    // !!! calling this before adding buttons seems to disable the tooltip on 10.4; what does it do on 10.5?
    [super mouseEntered:event];
}

/*
 We can't do this in mouseExited: since it's received as soon as the mouse enters the 
 slider's window (and checking the mouse location just postpones the problems).
 */
- (void)handleSliderMouseExited:(NSNotification *)aNote
{
    if ([[[self window] childWindows] containsObject:_sliderWindow]) {
        [[self window] removeChildWindow:_sliderWindow];
        [_sliderWindow fadeOut];
    }
}

- (void)mouseExited:(NSEvent *)event;
{
    [super mouseExited:event];
    [self _hideArrows];
}

- (NSURL *)_URLAtPoint:(NSPoint)point;
{
    NSUInteger anIndex = NSNotFound, r, c;
    if ([self _getGridRow:&r column:&c atPoint:point])
        anIndex = [self _indexForGridRow:r column:c];
    return NSNotFound == anIndex ? nil : [_controller URLAtIndex:anIndex];
}

- (void)_openURLs:(NSArray *)URLs
{
    NSEnumerator *e = [URLs objectEnumerator];
    NSURL *aURL;
    while ((aURL = [e nextObject])) {
        if ([aURL isEqual:[FVIcon missingFileURL]] == NO &&
            ([[self delegate] respondsToSelector:@selector(fileView:shouldOpenURL:)] == NO ||
             [[self delegate] fileView:self shouldOpenURL:aURL]))
            [[NSWorkspace sharedWorkspace] openURL:aURL];
    }
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)userData
{
    NSURL *theURL = [self _URLAtPoint:point];
    CFStringRef name;
    if ([theURL isFileURL] && noErr == LSCopyDisplayNameForURL((CFURLRef)theURL, &name))
        name = (CFStringRef)[(id)name autorelease];
    else
        name = (CFStringRef)[theURL absoluteString];
    return (NSString *)name;
}

// this method and shouldDelayWindowOrderingForEvent: are overriden to allow dragging from the view without making our window key
- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return ([self _URLAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]] != nil);
}

- (BOOL)shouldDelayWindowOrderingForEvent:(NSEvent *)event
{
    return ([self _URLAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]] != nil);
}

- (void)keyDown:(NSEvent *)event
{
    NSString *chars = [event characters];
    if ([chars length] > 0) {
        unichar ch = [chars characterAtIndex:0];
        
        switch(ch) {
            case 0x0020:
#if FV_SPACE_SCROLLS
                NSUInteger flags = [event modifierFlags];
                if ((flags & NSShiftKeyMask) != 0)
                    [[self enclosingScrollView] pageUp:self];
                else
                    [[self enclosingScrollView] pageDown:self];
#else
                [self previewAction:self];
#endif
                break;
            default:
                [self interpretKeyEvents:[NSArray arrayWithObject:event]];
        }
    }
    else {
        // no character, so pass it to the next responder
        [super keyDown:event];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    _fvFlags.isMouseDown = YES;
    
    NSPoint p = [event locationInWindow];
    p = [self convertPoint:p fromView:nil];
    _lastMouseDownLocInView = p;

    NSUInteger flags = [event modifierFlags];
    NSUInteger r, c, i;
    
    if (_fvFlags.hasArrows && NSMouseInRect(p, _leftArrowFrame, [self isFlipped])) {
        [_leftArrow trackMouse:event inRect:_leftArrowFrame ofView:self untilMouseUp:YES];
    }
    else if (_fvFlags.hasArrows && NSMouseInRect(p, _rightArrowFrame, [self isFlipped])) {
        [_rightArrow trackMouse:event inRect:_rightArrowFrame ofView:self untilMouseUp:YES];
    }
    // mark this icon for highlight if necessary
    else if ([self _getGridRow:&r column:&c atPoint:p]) {
        
        /*
         Remember _indexForGridRow:column: returns NSNotFound if you're in an empty slot of an 
         existing row/column, but that's a deselect event so we still need to remove all 
         selection indexes and mark for redisplay.
         */
        i = [self _indexForGridRow:r column:c];

        if ([_selectedIndexes containsIndex:i] == NO) {
            
            // deselect all if modifier key was not pressed, or i == NSNotFound
            if ((flags & (NSCommandKeyMask | NSShiftKeyMask)) == 0 || NSNotFound == i) {
                [self setSelectionIndexes:[NSIndexSet indexSet]];
            }
            
            // if there's an icon in this cell, add to the current selection (which we may have just reset)
            if (NSNotFound != i) {
                // add a single index for an unmodified or cmd-click
                // add a single index for shift click only if there is no current selection
                if ((flags & NSShiftKeyMask) == 0 || [_selectedIndexes count] == 0) {
                    [self willChangeValueForKey:NSSelectionIndexesBinding];
                    [_selectedIndexes addIndex:i];
                    [self didChangeValueForKey:NSSelectionIndexesBinding];
                }
                else if ((flags & NSShiftKeyMask) != 0) {
                    /*
                     Shift-click extends by a region; this is equivalent to iPhoto's grid view.  Finder treats 
                     shift-click like cmd-click in icon view, but we have a fixed layout, so this behavior is 
                     convenient and will be predictable.
                     */
                    
                    // at this point, we know that [_selectedIndexes count] > 0
                    NSParameterAssert([_selectedIndexes count]);
                    
                    NSUInteger start = [_selectedIndexes firstIndex];
                    NSUInteger end = [_selectedIndexes lastIndex];

                    if (i < start) {
                        [self willChangeValueForKey:NSSelectionIndexesBinding];
                        [_selectedIndexes addIndexesInRange:NSMakeRange(i, start - i)];
                        [self didChangeValueForKey:NSSelectionIndexesBinding];
                    }
                    else if (i > end) {
                        [self willChangeValueForKey:NSSelectionIndexesBinding];
                        [_selectedIndexes addIndexesInRange:NSMakeRange(end + 1, i - end)];
                        [self didChangeValueForKey:NSSelectionIndexesBinding];
                    }
                    else if (NSNotFound != _lastClickedIndex) {
                        /*
                         This handles the case of clicking in a deselected region between two selected regions.  
                         We want to extend from the last click to the current one, instead of randomly picking 
                         an end to start from.
                         */
                        [self willChangeValueForKey:NSSelectionIndexesBinding];
                        if (_lastClickedIndex > i)
                            [_selectedIndexes addIndexesInRange:NSMakeRange(i, _lastClickedIndex - i)];
                        else
                            [_selectedIndexes addIndexesInRange:NSMakeRange(_lastClickedIndex + 1, i - _lastClickedIndex)];
                        [self didChangeValueForKey:NSSelectionIndexesBinding];
                    }
                }
                [self setNeedsDisplay:YES];     
            }
        }
        else if ((flags & NSCommandKeyMask) != 0) {
            // cmd-clicked a previously selected index, so remove it from the selection
            [self willChangeValueForKey:NSSelectionIndexesBinding];
            [_selectedIndexes removeIndex:i];
            [self didChangeValueForKey:NSSelectionIndexesBinding];
            [self setNeedsDisplay:YES];
        }
        
        // always reset this
        _lastClickedIndex = i;
        
        // change selection first, as Finder does
        if ([event clickCount] > 1 && [self _URLAtPoint:p] != nil) {
            if (flags & NSAlternateKeyMask) {
                [self _getGridRow:&r column:&c atPoint:p];
                [self _previewURL:[self _URLAtPoint:p] forIconInRect:[self _rectOfIconInRow:r column:c]];
            } else {
                [self openSelectedURLs:self];
            }
        }
        
    }
    else if ([_selectedIndexes count]) {
        // deselect all, since we had a previous selection and clicked on a non-icon area
        [self setSelectionIndexes:[NSIndexSet indexSet]];
    }
    else {
        [super mouseDown:event];
    }    
}

static NSRect _rectWithCorners(const NSPoint aPoint, const NSPoint bPoint) {
    NSRect rect;
    rect.origin.x = MIN(aPoint.x, bPoint.x);
    rect.origin.y = MIN(aPoint.y, bPoint.y);
    rect.size.width = fmax(3.0, fmax(aPoint.x, bPoint.x) - rect.origin.x);
    rect.size.height = fmax(3.0, fmax(aPoint.y, bPoint.y) - rect.origin.y);    
    return rect;
}

- (NSIndexSet *)_allIndexesInRubberBandRect
{
    NSMutableIndexSet *indexSet = [NSMutableIndexSet indexSet];
    
    // do a fast check to avoid hit testing every icon in the grid
    NSRange rowRange, columnRange;
    [self _getRangeOfRows:&rowRange columns:&columnRange inRect:_rubberBandRect];
            
    // this is a useful test to see exactly what _getRangeOfRows:columns:inRect: is giving us
    /*
     // _indexForGridRow:column: returns NSNotFound if we're in a short row (empty column)
     NSUInteger iMin = [self _indexForGridRow:rowRange.location column:columnRange.location];
     if (NSNotFound == iMin)
     iMin = 0;
     
     NSUInteger i, j = iMin, nc = [self numberOfColumns];
     for (i = 0; i < rowRange.length; i++) {
         [indexSet addIndexesInRange:NSMakeRange(j, columnRange.length)];
         j += nc;
     }
     return indexSet;
    */
    
    NSUInteger r, rMax = NSMaxRange(rowRange);
    NSUInteger c, cMax = NSMaxRange(columnRange);
    
    NSUInteger idx;
    
    // now iterate each row/column to see if it intersects the rect
    for (r = rowRange.location; r < rMax; r++) 
    {
        for (c = columnRange.location; c < cMax; c++) 
        {    
            if (NSIntersectsRect([self _rectOfIconInRow:r column:c], _rubberBandRect)) {
                idx = [self _indexForGridRow:r column:c];
                if (NSNotFound != idx)
                    [indexSet addIndex:idx];
            }
        }
    }
    
    return indexSet;
}

- (void)mouseUp:(NSEvent *)event
{
    _fvFlags.isMouseDown = NO;
    if (NO == NSIsEmptyRect(_rubberBandRect)) {
        [self setNeedsDisplayInRect:_rubberBandRect];
        _rubberBandRect = NSZeroRect;
    }
}

- (void)mouseDragged:(NSEvent *)event
{
    // in mouseDragged:, we're either tracking an arrow button, drawing a rubber band selection, or initiating a drag
    
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSURL *pointURL = [self _URLAtPoint:p];
    
    // _isMouseDown tells us if the mouseDown: event originated in this view; if not, just ignore it
    
    if (NSEqualRects(_rubberBandRect, NSZeroRect) && nil != pointURL && _fvFlags.isMouseDown) {
        // No previous rubber band selection, so check to see if we're dragging an icon at this point.
        // The condition is also false when we're getting a repeated call to mouseDragged: for rubber band drawing.
        
        NSArray *selectedURLs = nil;
                
        // we may have a selection based on a previous rubber band, but only use that if we dragged one of the icons in it
        selectedURLs = [self _selectedURLs];
        if ([selectedURLs containsObject:pointURL] == NO) {
            selectedURLs = nil;
            [self setSelectionIndexes:[NSIndexSet indexSet]];
        }
        
        NSUInteger i, r, c;

        // not using a rubber band, so select and use the clicked URL if available (mouseDown: should have already done this)
        if (0 == [selectedURLs count] && nil != pointURL && [self _getGridRow:&r column:&c atPoint:p]) {
            selectedURLs = [NSArray arrayWithObject:pointURL];
            i = [self _indexForGridRow:r column:c];
            [self setSelectionIndexes:[NSIndexSet indexSetWithIndex:i]];
        }
        
        // if we have anything to drag, start a drag session
        if ([selectedURLs count]) {
            
            NSPasteboard *pboard = [NSPasteboard pasteboardWithName:NSDragPboard];
            
            // add all URLs (file and other schemes)
            // Finder will create weblocs for us unless schemes are mixed (gives a stupid file busy error message)
            
            if (FVWriteURLsToPasteboard(selectedURLs, pboard)) {
                // OK to pass nil for the image, since we totally ignore it anyway
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
#pragma clang diagnostic ignored "-Wdeprecated"
                [self dragImage:nil at:p offset:NSZeroSize event:event pasteboard:pboard source:self slideBack:YES];
#pragma clang diagnostic pop
            }
        }
        else {
            [super mouseDragged:event];
        }
        
    }
    else if (_fvFlags.isMouseDown) {   
        // no icons to drag, so we must draw the rubber band rectangle
        _rubberBandRect = NSIntersectionRect(_rectWithCorners(_lastMouseDownLocInView, p), [self bounds]);
        [self setSelectionIndexes:[self _allIndexesInRubberBandRect]];
        [self setNeedsDisplayInRect:_rubberBandRect];
        [self autoscroll:event];
        [super mouseDragged:event];
    }
}

#pragma mark Drop target

- (BOOL)_isLocalDraggingInfo:(id <NSDraggingInfo>)sender
{
    return [[sender draggingSource] isEqual:self];
}

- (BOOL)wantsPeriodicDraggingUpdates { return NO; }

- (FVDropOperation)_dropOperationAtPointInView:(NSPoint)point highlightRect:(NSRect *)dropRect insertionIndex:(NSUInteger *)anIndex
{
    NSUInteger r, c;
    FVDropOperation op = FVDropNone;
    NSRect aRect;
    NSUInteger insertIndex = NSNotFound;

    if ([self _getGridRow:&r column:&c atPoint:point]) {
        
        // check to avoid highlighting empty cells as individual icons; that's a DropOnView, not DropOnIcon

        if ([self _indexForGridRow:r column:c] > [_controller numberOfIcons]) {
            aRect = [self visibleRect];
            op = FVDropOnView;
        }
        else {
            aRect = [self _rectOfIconInRow:r column:c];
            op = FVDropOnIcon;
        }
    }
    else {
            
        NSPoint left = NSMakePoint(point.x - _iconSize.width, point.y), right = NSMakePoint(point.x + _iconSize.width, point.y);
        
        // can't insert between nonexistent icons either, so check numberOfIcons first...

        if ([self _getGridRow:&r column:&c atPoint:left] && ([self _indexForGridRow:r column:c] < [_controller numberOfIcons])) {
            
            aRect = [self _rectOfIconInRow:r column:c];
            // rect size is 6, and should be centered between icons horizontally
            aRect.origin.x += _iconSize.width + _padding.width / 2 - INSERTION_HIGHLIGHT_WIDTH / 2;
            aRect.size.width = INSERTION_HIGHLIGHT_WIDTH;    
            op = FVDropInsert;
            insertIndex = [self _indexForGridRow:r column:c] + 1;
        }
        else if ([self _getGridRow:&r column:&c atPoint:right] && ([self _indexForGridRow:r column:c] < [_controller numberOfIcons])) {
            
            aRect = [self _rectOfIconInRow:r column:c];
            aRect.origin.x -= _padding.width / 2 + INSERTION_HIGHLIGHT_WIDTH / 2;
            aRect.size.width = INSERTION_HIGHLIGHT_WIDTH;
            op = FVDropInsert;
            insertIndex = [self _indexForGridRow:r column:c];
        }
        else {
            
            aRect = [self visibleRect];
            op = FVDropOnView;
        }
    }
    
    if (NULL != dropRect) *dropRect = aRect;
    if (NULL != anIndex) *anIndex = insertIndex;
    return op;
}

- (BOOL)_isModifierKeyDown
{
    // +[NSEvent modifierFlags] is cleaner, but requires 10.6 and later
    const NSUInteger modifiers = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    return (kCGEventFlagMaskControl & modifiers || kCGEventFlagMaskAlternate & modifiers || kCGEventFlagMaskCommand & modifiers);
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    NSPoint dragLoc = [sender draggingLocation];
    dragLoc = [self convertPoint:dragLoc fromView:nil];
    NSDragOperation dragOp = NSDragOperationNone;
    
    NSUInteger insertIndex, firstIndex, endIndex;
    // this will set a default highlight based on geometry, but does no validation
    _fvFlags.dropOperation = [self _dropOperationAtPointInView:dragLoc highlightRect:&_dropRectForHighlight insertionIndex:&insertIndex];
    
    // We have to make sure the pasteboard really has a URL here, since most NSStrings aren't valid URLs
    if (FVPasteboardHasURL([sender draggingPasteboard]) == NO) {
        
        dragOp = NSDragOperationNone;
        _dropRectForHighlight = NSZeroRect;
        _fvFlags.dropOperation = FVDropNone;
    }
    else if (FVDropOnIcon == _fvFlags.dropOperation) {
        
        if ([self _isLocalDraggingInfo:sender]) {
                
            dragOp = NSDragOperationNone;
            _dropRectForHighlight = NSZeroRect;
            _fvFlags.dropOperation = FVDropNone;
        } 
        else {
            dragOp = [self _isModifierKeyDown] ? [sender draggingSourceOperationMask] : DEFAULT_DROP_OPERATION;
        }
    } 
    else if (FVDropOnView == _fvFlags.dropOperation) {
        
        // drop on the whole view (add operation) makes no sense for a local drag
        if ([self _isLocalDraggingInfo:sender]) {
            
            dragOp = NSDragOperationNone;
            _dropRectForHighlight = NSZeroRect;
            _fvFlags.dropOperation = FVDropNone;
        } 
        else {
            dragOp = [self _isModifierKeyDown] ? [sender draggingSourceOperationMask] : DEFAULT_DROP_OPERATION;
        }
    } 
    else if (FVDropInsert == _fvFlags.dropOperation) {
        
        // inserting inside the block we're dragging doesn't make sense; this does allow dropping a disjoint selection at some locations within the selection
        if ([self _isLocalDraggingInfo:sender]) {
            firstIndex = [_selectedIndexes firstIndex], endIndex = [_selectedIndexes lastIndex] + 1;
            if ([_selectedIndexes containsIndexesInRange:NSMakeRange(firstIndex, endIndex - firstIndex)] &&
                insertIndex >= firstIndex && insertIndex <= endIndex) {
                dragOp = NSDragOperationNone;
                _dropRectForHighlight = NSZeroRect;
                _fvFlags.dropOperation = FVDropNone;
            } 
            else {
                dragOp = NSDragOperationMove;
            }
        } 
        else {
            dragOp = [self _isModifierKeyDown] ? [sender draggingSourceOperationMask] : DEFAULT_DROP_OPERATION;
        }
    }
    
    [self setNeedsDisplay:YES];
    return dragOp;
}

// this is called as soon as the mouse is moved to start a drag, or enters the window from outside
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    // !!! multiple returns
    
    if ([self _isLocalDraggingInfo:sender])
        return [self _isModifierKeyDown] ? [sender draggingSourceOperationMask] : DEFAULT_DROP_OPERATION;

    NSUInteger count = [FVURLSFromPasteboard([sender draggingPasteboard]) count];
    if ([sender respondsToSelector:@selector(setNumberOfValidItemsForDrop:)])
        [sender setNumberOfValidItemsForDrop:count];
    if (count)
        return [self _isModifierKeyDown] ? [sender draggingSourceOperationMask] : DEFAULT_DROP_OPERATION;
    return NSDragOperationNone;
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
    _dropRectForHighlight = NSZeroRect;
    _fvFlags.dropOperation = FVDropNone;
    [self setNeedsDisplay:YES];
}

// only invoked if performDragOperation returned YES
- (void)concludeDragOperation:(id <NSDraggingInfo>)sender;
{
    _dropRectForHighlight = NSZeroRect;
    _fvFlags.dropOperation = FVDropNone;
    [self reloadIcons];
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    NSPoint dragLoc = [sender draggingLocation];
    dragLoc = [self convertPoint:dragLoc fromView:nil];
    NSPasteboard *pboard = [sender draggingPasteboard];
    
    BOOL didPerform = NO;
    
    // if we return NO, concludeDragOperation doesn't get called
    _dropRectForHighlight = NSZeroRect;
    [self setNeedsDisplay:YES];
    
    NSUInteger r, c, idx;
        
    NSUInteger insertIndex;
    
    // ??? use _fvFlags._dropOperation here?
    FVDropOperation dropOp = [self _dropOperationAtPointInView:dragLoc highlightRect:NULL insertionIndex:&insertIndex];

    // see if we're targeting a particular cell, then make sure that cell is a legal replace operation
    [self _getGridRow:&r column:&c atPoint:dragLoc];
    if (FVDropOnIcon == dropOp && (idx = [self _indexForGridRow:r column:c]) < [_controller numberOfIcons]) {
        
        NSURL *aURL = [FVURLSFromPasteboard(pboard) lastObject];
        
        // only drop a single file on a given cell!
        
        if (nil == aURL && [[pboard types] containsObject:NSFilenamesPboardType]) {
            aURL = [NSURL fileURLWithPath:[[pboard propertyListForType:NSFilenamesPboardType] lastObject]];
        }
        if (aURL) {
            if ([[self dataSource] respondsToSelector:@selector(fileView:replaceURLsAtIndexes:withURLs:dragOperation:)])
                didPerform = [[self dataSource] fileView:self replaceURLsAtIndexes:[NSIndexSet indexSetWithIndex:idx] withURLs:[NSArray arrayWithObject:aURL] dragOperation:[sender draggingSourceOperationMask]];
            else
                didPerform = [[self dataSource] fileView:self replaceURLsAtIndexes:[NSIndexSet indexSetWithIndex:idx] withURLs:[NSArray arrayWithObject:aURL]];
        }
    }
    else if (FVDropInsert == dropOp) {
        
        NSArray *allURLs = FVURLSFromPasteboard([sender draggingPasteboard]);
        
        // move is implemented as delete/insert
        if ([self _isLocalDraggingInfo:sender]) {
            
            // if inserting after the ones we're removing, let the delegate handle the offset the insertion index if necessary
            if ([_selectedIndexes containsIndex:insertIndex] || [_selectedIndexes containsIndex:insertIndex - 1]) {
                didPerform = NO;
            }
            else {
                if ([[self dataSource] respondsToSelector:@selector(fileView:moveURLsAtIndexes:toIndex:dragOperation:)])
                    didPerform = [[self dataSource] fileView:self moveURLsAtIndexes:[self selectionIndexes] toIndex:insertIndex dragOperation:[sender draggingSourceOperationMask]];
                else
                    didPerform = [[self dataSource] fileView:self moveURLsAtIndexes:[self selectionIndexes] toIndex:insertIndex];
            }
        } else {
            NSIndexSet *insertSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertIndex, [allURLs count])];
            if ([[self dataSource] respondsToSelector:@selector(fileView:insertURLs:atIndexes:dragOperation:)])
                [[self dataSource] fileView:self insertURLs:allURLs atIndexes:insertSet dragOperation:[sender draggingSourceOperationMask]];
            else
                [[self dataSource] fileView:self insertURLs:allURLs atIndexes:insertSet];
            didPerform = YES;
        }
    }
    else if ([self _isLocalDraggingInfo:sender] == NO) {
           
        // this must be an add operation, and only non-local drag sources can do that
        NSArray *allURLs = FVURLSFromPasteboard(pboard);
        NSIndexSet *insertSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange([_controller numberOfIcons], [allURLs count])];
        if ([[self dataSource] respondsToSelector:@selector(fileView:insertURLs:atIndexes:dragOperation:)])
            [[self dataSource] fileView:self insertURLs:allURLs atIndexes:insertSet dragOperation:[sender draggingSourceOperationMask]];
        else
            [[self dataSource] fileView:self insertURLs:allURLs atIndexes:insertSet];
        didPerform = YES;

    }
    // reload is handled in concludeDragOperation:
    return didPerform;
}

#pragma mark User interaction

- (BOOL)_tryToPerform:(SEL)aSelector inViewAndDescendants:(NSView *)aView
{
    if ([aView isHiddenOrHasHiddenAncestor])
        return NO;
    
    /*
     Since WebView returns YES from tryToPerform:@selector(pageDown:), but actually does nothing,
     we have to find an enclosing scrollview.  This sucks, but it'll at least work for anything
     in FVPreviewer.
     */
    if ([aView enclosingScrollView] && [[aView enclosingScrollView] tryToPerform:aSelector with:nil])
        return YES;
    
    NSEnumerator *subviewEnum = [[aView subviews] objectEnumerator];
    while ((aView = [subviewEnum nextObject]) != nil) {
        if ([aView isHiddenOrHasHiddenAncestor])
            continue;
        if ([self _tryToPerform:aSelector inViewAndDescendants:aView])
            return YES;
    }
    return NO;
}

- (void)_tryToPerformInPreviewer:(SEL)aSelector
{
    /*
     When you show a Quick Look panel in Finder, arrow keys control Finder icon navigation,
     but page up/page down control the Quick Look panel.  Since the QL panel actually appears
     to intercept pageUp:/pageDown: without sending them to the delegate, this code is 
     currently only called on FVPreviewer.
     
     Implementing pageUp:/pageDown: in FVPreviewer and walking the responder chain
     led to an infinite loop with the PDFView.  Walking subviews is slightly unpleasant, but
     it doesn't (and shouldn't) crash.
     */        
    NSWindow *window = nil;
    if ([[FVPreviewer sharedPreviewer] isPreviewing])
        window = [[FVPreviewer sharedPreviewer] window];
    else if (_fvFlags.controllingQLPreviewPanel)
        window = [QLPreviewPanelClass sharedPreviewPanel];
    
    if ([self _tryToPerform:aSelector inViewAndDescendants:[window contentView]] == NO)
        [super doCommandBySelector:aSelector];
}

- (void)doCommandBySelector:(SEL)aSelector
{
    if (aSelector == @selector(pageUp:) || aSelector == @selector(pageDown:)) {
        
        [self _tryToPerformInPreviewer:aSelector];
    }
    else {
        [super doCommandBySelector:aSelector];
    }
}

- (void)scrollItemAtIndexToVisible:(NSUInteger)anIndex
{
    NSUInteger r = 0, c = 0;
    if ([self _getGridRow:&r column:&c ofIndex:anIndex])
        [self scrollRectToVisible:[self _rectOfIconInRow:r column:c]];
}

- (void)moveUp:(id)sender;
{
    NSUInteger curIdx = [_selectedIndexes firstIndex];
    NSUInteger next = (NSNotFound == curIdx || curIdx < [self numberOfColumns]) ? 0 : curIdx - [self numberOfColumns];
    if (next >= [_controller numberOfIcons]) {
        NSBeep();
    }
    else {
        [self scrollItemAtIndexToVisible:next];
        [self setSelectionIndexes:[NSIndexSet indexSetWithIndex:next]];
    }
}

- (void)moveDown:(id)sender;
{
    NSUInteger curIdx = [_selectedIndexes firstIndex];
    NSUInteger next = NSNotFound == curIdx ? 0 : curIdx + [self numberOfColumns];
    if ([_controller numberOfIcons] == 0) {
        NSBeep();
    }
    else {
        if (next >= [_controller numberOfIcons])
            next = [_controller numberOfIcons] - 1;

        [self scrollItemAtIndexToVisible:next];
        [self setSelectionIndexes:[NSIndexSet indexSetWithIndex:next]];
    }
}

- (void)moveRight:(id)sender;
{
    [self selectNextIcon:self];
}

- (void)moveLeft:(id)sender;
{
    [self selectPreviousIcon:self];
}

- (void)insertTab:(id)sender;
{
    if ([_selectedIndexes firstIndex] == ([_controller numberOfIcons] - 1) && [_selectedIndexes count] == 1) {
        [self deselectAll:sender];
        [[self window] selectNextKeyView:sender];
    }
    else {
        [self selectNextIcon:self];
    }
}

- (void)insertBacktab:(id)sender;
{
    if ([_selectedIndexes firstIndex] == 0 && [_selectedIndexes count] == 1) {
        [self deselectAll:sender];
        [[self window] selectPreviousKeyView:sender];
    }
    else {
        [self selectPreviousIcon:self];
    }
}

- (void)moveToBeginningOfLine:(id)sender;
{
    if ([_selectedIndexes count] == 1) {
        FVIcon *anIcon = [_controller iconAtIndex:[_selectedIndexes firstIndex]];
        if ([anIcon currentPageIndex] > 1) {
            [anIcon showPreviousPage];
            [self _redisplayIconAfterPageChanged:anIcon];
        }
    }
}

- (void)moveToEndOfLine:(id)sender;
{
    if ([_selectedIndexes count] == 1) {
        FVIcon *anIcon = [_controller iconAtIndex:[_selectedIndexes firstIndex]];
        if ([anIcon currentPageIndex] < [anIcon pageCount]) {
            [anIcon showNextPage];
            [self _redisplayIconAfterPageChanged:anIcon];
        }
    }
}

- (void)insertNewline:(id)sender;
{
    if ([_selectedIndexes count])
        [self openSelectedURLs:sender];
}

- (void)deleteForward:(id)sender;
{
    [self delete:self];
}

- (void)deleteBackward:(id)sender;
{
    [self delete:self];
}

// scrollRectToVisible doesn't scroll the entire rect to visible
- (BOOL)scrollRectToVisible:(NSRect)aRect;
{
    NSRect visibleRect = [self visibleRect];
    BOOL didScroll = NO;
    if (NSContainsRect(visibleRect, aRect) == NO) {
        
        CGFloat heightDifference = NSHeight(visibleRect) - NSHeight(aRect);
        if (heightDifference > 0) {
            // scroll to a rect equal in height to the visible rect but centered on the selected rect
            aRect = NSInsetRect(aRect, 0.0, -(heightDifference / 2.0));
        } else {
            // force the top of the selectionRect to the top of the view
            aRect.size.height = NSHeight(visibleRect);
        }
        didScroll = [super scrollRectToVisible:aRect];
    }
    return didScroll;
} 

- (IBAction)selectPreviousIcon:(id)sender;
{
    NSUInteger curIdx = [_selectedIndexes firstIndex];
    NSUInteger previous = NSNotFound;
    
    if (NSNotFound == curIdx)
        previous = 0;
    else if (0 == curIdx && [_controller numberOfIcons] > 0) 
        previous = ([_controller numberOfIcons] - 1);
    else if ([_controller numberOfIcons] > 0)
        previous = curIdx - 1;
    
    if (NSNotFound != previous) {
        [self scrollItemAtIndexToVisible:previous];
        [self setSelectionIndexes:[NSIndexSet indexSetWithIndex:previous]];
    }
}

- (IBAction)selectNextIcon:(id)sender;
{
    NSUInteger curIdx = [_selectedIndexes firstIndex];
    NSUInteger next = NSNotFound == curIdx ? 0 : curIdx + 1;
    if (next >= [_controller numberOfIcons])
        next = 0;

    [self scrollItemAtIndexToVisible:next];
    [self setSelectionIndexes:[NSIndexSet indexSetWithIndex:next]];
}

- (IBAction)revealInFinder:(id)sender
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    [[NSWorkspace sharedWorkspace] selectFile:[[[self _selectedURLs] lastObject] path] inFileViewerRootedAtPath:nil];
#pragma clang diagnostic pop
}

- (IBAction)openSelectedURLs:(id)sender
{
    [self _openURLs:[self _selectedURLs]];
}

- (IBAction)zoomIn:(id)sender;
{
    [self setIconScale:([self iconScale] * sqrt(2))];
}

- (IBAction)zoomOut:(id)sender;
{
    [self setIconScale:([self iconScale] / sqrt(2))];
}

- (IBAction)previewAction:(id)sender;
{
    if ([[FVPreviewer sharedPreviewer] isPreviewing]) {
        [[FVPreviewer sharedPreviewer] stopPreviewing];
    }
    else if (_fvFlags.controllingQLPreviewPanel) {
        [[QLPreviewPanelClass sharedPreviewPanel] orderOut:nil];
        [[QLPreviewPanelClass sharedPreviewPanel] setDataSource:nil];
        [[QLPreviewPanelClass sharedPreviewPanel] setDelegate:nil];
    }
    else if ([_selectedIndexes count] == 1) {
        NSUInteger r, c;
        [self _getGridRow:&r column:&c ofIndex:[_selectedIndexes lastIndex]];
        [self _previewURL:[[self _selectedURLs] lastObject] forIconInRect:[self _rectOfIconInRow:r column:c]];
    }
    else {
        [self _previewURLs:[self _selectedURLs]];
    }
}

- (IBAction)delete:(id)sender;
{
    // pass copy of _selectionIndexes
    if (NO == [self isEditable] || NO == [[self dataSource] fileView:self deleteURLsAtIndexes:[self selectionIndexes]])
        NSBeep();
    else
        [self reloadIcons];
}

- (IBAction)selectAll:(id)sender;
{
    [self setSelectionIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [_controller numberOfIcons])]];
}

- (IBAction)deselectAll:(id)sender;
{
    [self setSelectionIndexes:[NSIndexSet indexSet]];
}

- (IBAction)copy:(id)sender;
{
    if (NO == FVWriteURLsToPasteboard([self _selectedURLs], [NSPasteboard generalPasteboard]))
        NSBeep();
}

- (IBAction)cut:(id)sender;
{
    [self copy:sender];
    [self delete:sender];
}

- (IBAction)paste:(id)sender;
{
    if ([self isEditable]) {
        NSArray *URLs = FVURLSFromPasteboard([NSPasteboard generalPasteboard]);
        NSIndexSet *insertSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange([_controller numberOfIcons], [URLs count])];
        if ([URLs count])
            [[self dataSource] fileView:self insertURLs:URLs atIndexes:insertSet];
        else
            NSBeep();
    }
    else NSBeep();
}

- (IBAction)reloadSelectedIcons:(id)sender;
{
    // callers aren't required to validate based on selection, so make this a noop in that case
    if ([_selectedIndexes count]) {
        NSEnumerator *iconEnum = [[_controller iconsAtIndexes:_selectedIndexes] objectEnumerator];
        FVIcon *anIcon;
        while ((anIcon = [iconEnum nextObject]) != nil)
            [anIcon recache];

        // ensure consistency between controller and icon, since this will require re-reading the URL from disk/net
        [self _reloadIconsAndController:YES];
    }
    else {
        NSBeep();
    }
}

#pragma mark Context menu

- (BOOL)validateMenuItem:(NSMenuItem *)anItem
{
    NSURL *aURL = [[self _selectedURLs] lastObject];  
    SEL action = [anItem action];
    
    // generally only check this for actions that are dependent on single selection
    BOOL isMissing = [aURL isEqual:[FVIcon missingFileURL]];
    BOOL isEditable = [self isEditable];
    NSUInteger selectionCount = [_selectedIndexes count];
    
    if (action == @selector(zoomOut:) || action == @selector(zoomIn:))
        return YES;
    else if (action == @selector(revealInFinder:))
        return [aURL isFileURL] && [_selectedIndexes count] == 1 && NO == isMissing;
    else if (action == @selector(openSelectedURLs:))
        return selectionCount > 0;
    else if (action == @selector(delete:) || action == @selector(cut:))
        return [self isEditable] && selectionCount > 0;
    else if (action == @selector(selectAll:))
        return ([_controller numberOfIcons] > 0);
    else if (action == @selector(previewAction:))
        return selectionCount > 0;
    else if (action == @selector(paste:))
        return [self isEditable];
    else if (action == @selector(copy:))
        return selectionCount > 0;
    else if (action == @selector(submenuAction:))
        return selectionCount > 1 || ([_selectedIndexes count] == 1 && [aURL isFileURL]);
    else if (action == @selector(changeFinderLabel:) || [anItem tag] == FVChangeLabelMenuItemTag) {

        BOOL enabled = NO;
        NSInteger state = NSOffState;

        // if multiple selection, enable unless all the selected URLs are missing or non-files
        if (selectionCount > 1) {
            NSEnumerator *urlEnum = [[self _selectedURLs] objectEnumerator];
            NSURL *url;
            while ((url = [urlEnum nextObject])) {
                // if we find a single file URL that isn't the missing file URL, enable the menu
                if ([url isEqual:[FVIcon missingFileURL]] == NO && [url isFileURL])
                    enabled = YES;
            }
        }
        else if (selectionCount == 1 && NO == isMissing && [aURL isFileURL]) {
            
            NSInteger label = [FVFinderLabel finderLabelForURL:aURL];
            // 10.4
            if (label == [anItem tag])
                state = NSOnState;
            
            // 10.5+
            if ([anItem respondsToSelector:@selector(setView:)])
                [(FVColorMenuView *)[anItem view] selectLabel:label];
            
            enabled = YES;
        }
        
        if ([anItem respondsToSelector:@selector(setView:)])
            [(FVColorMenuView *)[anItem view] setTarget:self];
        
        // no effect on menu items with a custom view
        [anItem setState:state];
        return enabled;
    }
    else if (action == @selector(downloadSelectedLink:)) {
        FVDownload *download = aURL ? [[[FVDownload alloc] initWithDownloadURL:aURL indexInView:[_selectedIndexes firstIndex]] autorelease] : nil;
        BOOL alreadyDownloading = [[_controller downloads] containsObject:download];
        // don't check reachability; just handle the error if it fails
        return NO == isMissing && isEditable && selectionCount == 1 && [aURL isFileURL] == NO && FALSE == alreadyDownloading;
    }
    else if (action == @selector(reloadSelectedIcons:)) {
        return selectionCount > 0;
    }

    // need to handle print: and other actions
    return (action && [self respondsToSelector:action]);
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    _lastMouseDownLocInView = [self convertPoint:[event locationInWindow] fromView:nil];
    NSMenu *menu = [[self class] defaultMenu];
    
    NSUInteger i,r,c,idx = NSNotFound;
    if ([self _getGridRow:&r column:&c atPoint:_lastMouseDownLocInView])
        idx = [self _indexForGridRow:r column:c];
    
    // Finder changes selection only if the clicked item isn't in the current selection
    if (menu && NO == [_selectedIndexes containsIndex:idx])
        [self setSelectionIndexes:idx == NSNotFound ? [NSIndexSet indexSet] : [NSIndexSet indexSetWithIndex:idx]];

    // remove disabled items and double separators
    i = [menu numberOfItems];
    BOOL wasSeparator = YES;
    while (i--) {
        NSMenuItem *menuItem = [menu itemAtIndex:i];
        if ([menuItem isSeparatorItem]) {
            // see if this is a double separator, if so remove it
            if (wasSeparator)
                [menu removeItemAtIndex:i];
            wasSeparator = YES;
        } else if ([self validateMenuItem:menuItem]) {
            if ([menuItem submenu] && [self validateMenuItem:[[menuItem submenu] itemAtIndex:0]] == NO) {
                // disabled submenu item
                [menu removeItemAtIndex:i];
            } else {
                // valid menu item, keep it, and it wasn't a separator
                wasSeparator = NO;
            }
        } else {
            // disabled menu item
            [menu removeItemAtIndex:i];
        }
    }
    // remove a separator at index 0
    if ([menu numberOfItems] > 0 && [[menu itemAtIndex:0] isSeparatorItem])
        [menu removeItemAtIndex:0];
        
    if ([[self delegate] respondsToSelector:@selector(fileView:willPopUpMenu:onIconAtIndex:)])
        [[self delegate] fileView:self willPopUpMenu:menu onIconAtIndex:idx];
    
    if ([menu numberOfItems] == 0)
        menu = nil;

    return menu;
}

// sender must respond to -tag, and may respond to -enclosingMenuItem
- (IBAction)changeFinderLabel:(id)sender;
{
    // Sender tag corresponds to the Finder label integer
    NSInteger label = [sender tag];
    FVAPIAssert1(label >=0 && label <= 7, @"invalid label %ld (must be between 0 and 7)", (unsigned long)label);
    
    NSArray *selectedURLs = [self _selectedURLs];
    NSUInteger i, iMax = [selectedURLs count];
    for (i = 0; i < iMax; i++) {
        [FVFinderLabel setFinderLabel:label forURL:[selectedURLs objectAtIndex:i]];
    }
    
    // _FVController label cache needs to be rebuilt
    [self reloadIcons];
    
    // we have to close the menu manually; FVColorMenuCell returns its control view's menu item
    if ([sender respondsToSelector:@selector(enclosingMenuItem)] && [[[sender enclosingMenuItem] menu] respondsToSelector:@selector(cancelTracking)])
        [[[sender enclosingMenuItem] menu] cancelTracking];
}

static void addFinderLabelsToSubmenu(NSMenu *submenu)
{
    NSInteger i = 0;
    NSRect iconRect = NSZeroRect;
    iconRect.size = NSMakeSize(12, 12);
    NSBezierPath *clipPath = [NSBezierPath fv_bezierPathWithRoundRect:iconRect xRadius:3.0 yRadius:3.0];
    
    for (i = 0; i < 8; i++) {
        NSMenuItem *anItem = [submenu addItemWithTitle:[FVFinderLabel localizedNameForLabel:i] action:@selector(changeFinderLabel:) keyEquivalent:@""];
        [anItem setTag:i];
        
        NSImage *image = [[NSImage alloc] initWithSize:iconRect.size];
        [image lockFocus];
        
        // round off the corners of the swatches, but don't draw the full rounded ends
        [clipPath addClip];
        [FVFinderLabel drawFinderLabel:i inRect:iconRect roundEnds:NO];
        
        // Finder displays an unbordered cross for clearing the label, so we'll do something similar
        [[NSColor darkGrayColor] setStroke];
        if (0 == i) {
            NSBezierPath *p = [NSBezierPath bezierPath];
            [p moveToPoint:NSMakePoint(3, 3)];
            [p lineToPoint:NSMakePoint(9, 9)];
            [p moveToPoint:NSMakePoint(3, 9)];
            [p lineToPoint:NSMakePoint(9, 3)];
            [p setLineWidth:2.0];
            [p setLineCapStyle:NSRoundLineCapStyle];
            [p stroke];
            [p setLineWidth:1.0];
            [p setLineCapStyle:NSButtLineCapStyle];
        }
        else {
            // stroke clip path for a subtle border; stroke is wide enough to display a thin line inside the clip region
            [clipPath stroke];
        }
        [image unlockFocus];
        [anItem setImage:image];
        [image release];
    }
}

+ (NSMenu *)defaultMenu
{
    NSMenuItem *anItem;
    NSMenu *defaultMenu = [[[NSMenu allocWithZone:[NSMenu menuZone]] initWithTitle:@""] autorelease];
    NSBundle *bundle = [NSBundle bundleForClass:[FileView class]];
    
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Quick Look", @"FileView", bundle, @"context menu title") action:@selector(previewAction:) keyEquivalent:@""];
    [anItem setTag:FVQuickLookMenuItemTag];
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Open", @"FileView", bundle, @"context menu title") action:@selector(openSelectedURLs:) keyEquivalent:@""];
    [anItem setTag:FVOpenMenuItemTag];
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Reveal in Finder", @"FileView", bundle, @"context menu title") action:@selector(revealInFinder:) keyEquivalent:@""];
    [anItem setTag:FVRevealMenuItemTag];
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Reload", @"FileView", bundle, @"context menu title") action:@selector(reloadSelectedIcons:) keyEquivalent:@""];
    [anItem setTag:FVReloadMenuItemTag];        
    
    [defaultMenu addItem:[NSMenuItem separatorItem]];
    
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Remove", @"FileView", bundle, @"context menu title") action:@selector(delete:) keyEquivalent:@""];
    [anItem setTag:FVRemoveMenuItemTag];
    
    // Finder labels: submenu on 10.4, NSView on 10.5
    if ([anItem respondsToSelector:@selector(setView:)])
        [defaultMenu addItem:[NSMenuItem separatorItem]];
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Set Finder Label", @"FileView", bundle, @"context menu title") action:NULL keyEquivalent:@""];
    [anItem setTag:FVChangeLabelMenuItemTag];
    
    if ([anItem respondsToSelector:@selector(setView:)]) {
        FVColorMenuView *view = [FVColorMenuView menuView];
        [view setTarget:nil];
        [view setAction:@selector(changeFinderLabel:)];
        [anItem setView:view];
    }
    else {
        NSMenu *submenu = [[NSMenu allocWithZone:[defaultMenu zone]] initWithTitle:@""];
        [anItem setSubmenu:submenu];
        [submenu release];
        addFinderLabelsToSubmenu(submenu);
    }
    
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Download and Replace", @"FileView", bundle, @"context menu title") action:@selector(downloadSelectedLink:) keyEquivalent:@""];
    [anItem setTag:FVDownloadMenuItemTag];
    
    [defaultMenu addItem:[NSMenuItem separatorItem]];
    
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Zoom In", @"FileView", bundle, @"context menu title") action:@selector(zoomIn:) keyEquivalent:@""];
    [anItem setTag:FVZoomInMenuItemTag];
    anItem = [defaultMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Zoom Out", @"FileView", bundle, @"context menu title") action:@selector(zoomOut:) keyEquivalent:@""];
    [anItem setTag:FVZoomOutMenuItemTag];

    return defaultMenu;
}

#pragma mark Download support

- (void)downloadSelectedLink:(id)sender
{
    // validation ensures that we have a single selection, and that there is no current download with this URL
    NSUInteger selIndex = [_selectedIndexes firstIndex];
    if (NSNotFound != selIndex)
        [_controller downloadURLAtIndex:selIndex];
}

#pragma mark Quick Look support

- (void)handlePreviewerWillClose:(NSNotification *)aNote
{
    /*
     Necessary to reset in case of the window close button, which doesn't go through
     our action methods.
     
     !!! Rework this to use QLPreviewPanel delegate methods and unify support.
     */
    _fvFlags.controllingSharedPreviewer = NO;
}

- (void)_previewURLs:(NSArray *)iconURLs
{
    if (_fvFlags.controllingQLPreviewPanel) {
        if ([[FVPreviewer sharedPreviewer] isPreviewing]) {
            [[FVPreviewer sharedPreviewer] stopPreviewing];
        }
        [[QLPreviewPanelClass sharedPreviewPanel] reloadData];
        [[QLPreviewPanelClass sharedPreviewPanel] refreshCurrentPreviewItem];
    }
    else if (QLPreviewPanelClass) {
        if ([[FVPreviewer sharedPreviewer] isPreviewing]) {
            [[FVPreviewer sharedPreviewer] stopPreviewing];
        }
        [[QLPreviewPanelClass sharedPreviewPanel] makeKeyAndOrderFront:nil];        
    }
    else {
        [[FVPreviewer sharedPreviewer] setWebViewContextMenuDelegate:nil];
        [[FVPreviewer sharedPreviewer] previewFileURLs:iconURLs];
    }
}

- (void)_previewURL:(NSURL *)aURL forIconInRect:(NSRect)iconRect
{
    if ([FVPreviewer useQuickLookForURL:aURL] == NO || Nil == QLPreviewPanelClass) {
        iconRect = [self convertRect:iconRect toView:nil];
        iconRect = [[self window] convertRectToScreen:iconRect];
        // note: controllingQLPreviewPanel is only true if QLPreviewPanelClass exists, but clang doesn't know that
        if (_fvFlags.controllingQLPreviewPanel && Nil != QLPreviewPanelClass) {
            iconRect = [[QLPreviewPanelClass sharedPreviewPanel] frame];
            [[QLPreviewPanelClass sharedPreviewPanel] performSelector:@selector(orderOut:) withObject:nil afterDelay:0.0];
        }
        [[FVPreviewer sharedPreviewer] setWebViewContextMenuDelegate:[self delegate]];
        [[FVPreviewer sharedPreviewer] previewURL:aURL forIconInRect:iconRect];    
        _fvFlags.controllingSharedPreviewer = YES;
    }
    else if (_fvFlags.controllingQLPreviewPanel) {
        if ([[FVPreviewer sharedPreviewer] isPreviewing]) {
            [[FVPreviewer sharedPreviewer] stopPreviewing];
        }
        [[QLPreviewPanelClass sharedPreviewPanel] reloadData];
        [[QLPreviewPanelClass sharedPreviewPanel] refreshCurrentPreviewItem];
    }
    else {
        if ([[FVPreviewer sharedPreviewer] isPreviewing]) {
            [[FVPreviewer sharedPreviewer] stopPreviewing];
        }
        [[QLPreviewPanelClass sharedPreviewPanel] makeKeyAndOrderFront:nil]; 
    }
}

// gets sent while doing keyboard navigation when the panel is up
- (BOOL)previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event;
{
    /*
     This works fine if navigating icons via the FileView with arrow keys, but breaks
     down when navigating BibDesk's tableview with arrow keys and the QL panel, since in that
     case the delegate should be the table's delegate.  FVPreviewer works better in that case,
     since it doesn't frob the responder chain like QLPreviewPanel.  This is enough of an edge 
     case that it's not worth a great deal of trouble, though.
     */
    if ([event type] == NSKeyDown) {
        [self interpretKeyEvents:[NSArray arrayWithObject:event]];
        return YES;
    }
    return NO;
}

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel;
{
    return YES;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel;
{
    _fvFlags.controllingQLPreviewPanel = YES;
    [[QLPreviewPanelClass sharedPreviewPanel] setDataSource:self];
    [[QLPreviewPanelClass sharedPreviewPanel] setDelegate:self];
    [[QLPreviewPanelClass sharedPreviewPanel] reloadData];    
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel;
{
    _fvFlags.controllingQLPreviewPanel = NO;
    [[QLPreviewPanelClass sharedPreviewPanel] setDataSource:nil];
    [[QLPreviewPanelClass sharedPreviewPanel] setDelegate:nil];
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel;
{
    return [[self _selectedURLs] count];
}

- (id <QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)idx;
{
    return [[self _selectedURLs] objectAtIndex:idx];
}

- (NSRect)previewPanel:(QLPreviewPanel *)panel sourceFrameOnScreenForPreviewItem:(id <QLPreviewItem>)item;
{
    NSUInteger r, c;
    NSRect iconRect = NSZeroRect;
    if ([self numberOfPreviewItemsInPreviewPanel:panel] == 1 && [self _getGridRow:&r column:&c ofIndex:[_selectedIndexes lastIndex]]) {
        iconRect = [self _rectOfIconInRow:r column:c];
        iconRect = [self convertRect:iconRect toView:nil];
        iconRect = [[self window] convertRectToScreen:iconRect];
    }
    return iconRect;
}

- (_FVController *)_controller { return _controller; }

@end

#ifndef MAC_OS_X_VERSION_10_7
enum {
    NSScrollerStyleLegacy       = 0,
    NSScrollerStyleOverlay      = 1
};
typedef NSInteger NSScrollerStyle;

@interface NSScroller(Lion)
+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)controlSize scrollerStyle:(NSScrollerStyle)scrollerStyle;
+ (NSScrollerStyle)preferredScrollerStyle;
@end
#endif

@implementation FVColumnView

- (NSArray *)exposedBindings;
{
    NSMutableArray *bindings = [[[super exposedBindings] mutableCopy] autorelease];
    [bindings removeObject:@"iconScale"];
    [bindings removeObject:@"maxIconScale"];
    [bindings removeObject:@"minIconScale"];
    return bindings;
}

- (BOOL)_showsSlider { return NO; }

- (NSUInteger)numberOfColumns { return 1; }

// remove icon size/padding interdependencies
- (CGFloat)_leftMargin { return DEFAULT_PADDING / 2; }
- (CGFloat)_rightMargin { return DEFAULT_PADDING / 2; }

- (NSSize)_defaultPaddingForScale:(CGFloat)scale
{    
    NSSize size = [super _defaultPaddingForScale:scale];
    size.width = 0;
    return size;
}

// horizontal padding is always zero, so we extend horizontally by the margin width
- (void)_setNeedsDisplayForIconInRow:(NSUInteger)row column:(NSUInteger)column {
    NSRect iconRect = [self _rectOfIconInRow:row column:column];
    // extend horizontally to account for shadow in case text is narrower than the icon
    // extend upward by 1 unit to account for slight mismatch between icon/placeholder drawing
    // extend downward to account for the text area
    CGFloat horizontalExpansion = floor(MAX([self _leftMargin], [self _rightMargin]));
    NSRect dirtyRect = NSUnionRect(NSInsetRect(iconRect, -horizontalExpansion, -1.0), [self _rectOfTextForIconRect:iconRect]);
    [self setNeedsDisplayInRect:dirtyRect];
}

static NSScrollView * __FVHidingScrollView()
{
    static NSScrollView *scrollView = nil;
    if (nil == scrollView) {
        NSRect frame = NSMakeRect(0, 0, 10, 10);
        scrollView = [[NSScrollView allocWithZone:NULL] initWithFrame:frame];
        NSView *docView = [[NSView allocWithZone:NULL] initWithFrame:frame];
        [scrollView setDocumentView:docView];
        [docView release];
        [scrollView setHasVerticalScroller:YES];
        [scrollView setHasHorizontalScroller:YES];
        [scrollView setAutohidesScrollers:YES];
    }
    return scrollView;
}

static bool __FVScrollViewHasVerticalScroller(NSScrollView *scrollView, FVColumnView *columnView)
{
    if (scrollView == nil || [scrollView autohidesScrollers] == NO)
        return NO;

    if ([scrollView hasVerticalScroller] == NO)
        return NO;
    
    /*
     Not really sure if this is the best behavior, but it works pretty well with the Lion
     overlay scrollers.  The main idea is to avoid insetting the view frame by the width
     of the scroller, as NSScroller no longer draws its background in the overlay case.
     
     There can be some clipping of content when the scroller switches to its fatter width,
     but that's very minimal, and seems to only affect the multicolumn view.  Switching
     layout based on the overlay scroller's presence or absence would likely be even worse,
     so this is probably as good as we can do for now, particularly with the need for
     backwards compatibility.
     
     As of 10.8, the legacy scroller isn't drawn if we have zero rows. Needs testing on
     10.7 and 10.9. Unfortunately, there are multiple cases to consider here:
     
        1) No content in view; even legacy scrollers will be hidden, so we need
           to draw full width. This is easy to catch.
     
        2) Icons fit in the view vertically, so we don't need a vertical scroller
           at all. Apparently legacy scrollers don't draw in that case, either,
           so I get a background color.
     
        3) We need a vertical scroller. In this case, we may or may not use the
           legacy scroller stuff.
     
     Checking -isHidden seems to work on 10.8, but needs more testing.
     
     */
    NSScroller *vscroller = [scrollView verticalScroller];
    if ([vscroller respondsToSelector:@selector(scrollerStyle)])
        return [vscroller scrollerStyle] == NSScrollerStyleLegacy && [columnView numberOfRows] > 0 && [vscroller isHidden] == NO;
    
    NSSize contentSize = [scrollView contentSize];
    NSSize contentSizeWithScroller = [NSScrollView contentSizeForFrameSize:[scrollView frame].size
                                                   horizontalScrollerClass:Nil
                                                     verticalScrollerClass:[[scrollView verticalScroller] class]
                                                                borderType:[scrollView borderType]
                                                               controlSize:[[scrollView verticalScroller] controlSize]
                                                             scrollerStyle:[scrollView scrollerStyle]];

    return ((NSInteger)contentSize.width == (NSInteger)contentSizeWithScroller.width);
}

- (BOOL)willUnhideVerticalScrollerWithFrame:(NSRect)frame
{
    // !!! early return; nothing to do in this case
    if (__FVScrollViewHasVerticalScroller([self enclosingScrollView], self))
        return NO;

    NSScrollView *scrollView = __FVHidingScrollView();
    [scrollView setBorderType:[[self enclosingScrollView] borderType]];
    
    // scrollview has same frame as our enclosing scrollview
    [scrollView setFrame:[[self enclosingScrollView] frame]];    
    [[scrollView documentView] setFrame:frame];
    
    return __FVScrollViewHasVerticalScroller(scrollView, self);
}

- (void)_recalculateGridSize
{
    NSRect minFrame = [self frame];
    
    // using the scrollview's frame is incorrect if it has a border, and using the clip view has other complications
    NSScrollView *sv = [self enclosingScrollView];
    if (sv) {
        minFrame.size = [NSScrollView contentSizeForFrameSize:[sv frame].size
                                      horizontalScrollerClass:Nil
                                        verticalScrollerClass:Nil
                                                   borderType:[sv borderType]
                                                  controlSize:[[sv verticalScroller] controlSize]
                                                scrollerStyle:[sv scrollerStyle]];
    }
    
    _padding = [self _defaultPaddingForScale:[self iconScale]];
    CGFloat length = NSWidth(minFrame) - _padding.width - [self _leftMargin] - [self _rightMargin];    
    _iconSize = NSMakeSize(length, length);
    
    // compute a preliminary guess for the frame size
    NSRect frame = NSZeroRect;
    frame.size.width = NSWidth(minFrame);
    frame.size.height = MAX([self _rowHeight] * [self numberOfRows] + [self _topMargin] + [self _bottomMargin], NSHeight(minFrame));

    NSScroller *verticalScroller = [[self enclosingScrollView] verticalScroller];

    // see if the vertical scroller will show its ugly face and muck up the layout...
    if ([self willUnhideVerticalScrollerWithFrame:frame]) {
        
        CGFloat scrollerWidth = [NSScroller scrollerWidthForControlSize:[verticalScroller controlSize] scrollerStyle:[NSScroller preferredScrollerStyle]];
        
        // shrink by the scroller width and recompute icon size
        length = NSWidth(minFrame) - _padding.width - [self _leftMargin] - [self _rightMargin] - scrollerWidth;    
        _iconSize = NSMakeSize(length, length);
        frame.size.height = MAX([self _rowHeight] * [self numberOfRows] + [self _topMargin] + [self _bottomMargin], NSHeight(minFrame));
        
        // after icon size adjustment, width adjustment may not be necessary since height is smaller
        if ([self willUnhideVerticalScrollerWithFrame:frame] && __FVScrollViewHasVerticalScroller([self enclosingScrollView], self) == NO)
            frame.size.width -= scrollerWidth;
        
        /*
         It should be possible to be more clever here, but NSScrollView has some odd behavior
         when autohiding is enabled.  It's fairly easy to get it into a state where it "has" 
         a scroller but doesn't draw it, or scrolls without a visible scroller.  NB: may be
         fixed by taking border into account now...
         */

    }
    else if (__FVScrollViewHasVerticalScroller([self enclosingScrollView], self)) {
        
        CGFloat scrollerWidth = [NSScroller scrollerWidthForControlSize:[verticalScroller controlSize] scrollerStyle:[NSScroller preferredScrollerStyle]];
        
        // shrink by the scroller width and recompute icon size
        length = NSWidth(minFrame) - _padding.width - [self _leftMargin] - [self _rightMargin] - scrollerWidth;    
        _iconSize = NSMakeSize(length, length);
        frame.size.height = MAX([self _rowHeight] * [self numberOfRows] + [self _topMargin] + [self _bottomMargin], NSHeight(minFrame));   
        frame.size.width -= scrollerWidth;
    }
    
    // handling the willHide case isn't necessary

    // any icon size change will invalidate the selection layer size
    [self _invalidateSelectionOverlay];
    
    // this actually isn't true very often
    if (NSEqualRects(frame, [self frame]) == NO)
        [self setFrame:frame]; 

    // need to call even if frame isn't set
    [[self enclosingScrollView] reflectScrolledClipView:[[self enclosingScrollView] contentView]];

} 
#if 0
- (void)drawRect:(NSRect)aRect
{
    [super drawRect:aRect];
    NSRect bounds = [self bounds];
    NSRect cvFrame = [[[self enclosingScrollView] contentView] frame];
    NSRect svFrame = [[self enclosingScrollView] frame];
    NSString *s = [NSString stringWithFormat:@"self bounds.size = %@\nsv frame.size = %@\ncv frame.size = %@", NSStringFromSize(bounds.size), NSStringFromSize(svFrame.size), NSStringFromSize(cvFrame.size)];
    s = [s stringByAppendingFormat:@"\nscroller frame = %@", NSStringFromRect([[[self enclosingScrollView] verticalScroller] frame])];
    s = [s stringByAppendingFormat:@"\niconSize = %@", NSStringFromSize(_iconSize)];
    NSPoint p = { 2, 2 };
    [s drawAtPoint:p withAttributes:nil];
}
#endif
- (void)setIconScale:(double)scale;
{
    // may be called by initWithCoder:
}

- (NSBezierPath *)_insertionHighlightPathInRect:(NSRect)aRect
{
    NSBezierPath *p;
    NSRect rect = aRect;
    // similar to NSTableView's between-row drop indicator
    rect.size.width = NSHeight(aRect);
    p = [NSBezierPath bezierPathWithOvalInRect:rect];
    
    NSPoint point = NSMakePoint(NSMaxX(rect), NSMidY(aRect));
    [p moveToPoint:point];
    point = NSMakePoint(NSMaxX(aRect) - NSHeight(aRect), NSMidY(aRect));
    [p lineToPoint:point];
    
    rect = aRect;
    rect.origin.x = NSMaxX(aRect) - NSHeight(aRect);
    rect.size.width = NSHeight(aRect);
    [p appendBezierPathWithOvalInRect:rect];
    
    return p;
}

- (FVDropOperation)_dropOperationAtPointInView:(NSPoint)point highlightRect:(NSRect *)dropRect insertionIndex:(NSUInteger *)anIndex
{
    NSUInteger r, c;
    FVDropOperation op;
    NSRect aRect;
    NSUInteger insertIndex = NSNotFound;
    
    if ([self _getGridRow:&r column:&c atPoint:point]) {
        
        // check to avoid highlighting empty cells as individual icons; that's a DropOnView, not DropOnIcon
        
        if ([self _indexForGridRow:r column:c] > [[self _controller] numberOfIcons]) {
            aRect = [self visibleRect];
            op = FVDropOnView;
        }
        else {
            aRect = [self _rectOfIconInRow:r column:c];
            op = FVDropOnIcon;
        }
    }
    else {
        
        NSPoint lower = NSMakePoint(point.x, point.y - _iconSize.width), upper = NSMakePoint(point.x, point.y + _iconSize.width);
        
        // can't insert between nonexisting cells either, so check numberOfIcons first...
        
        if ([self _getGridRow:&r column:&c atPoint:lower] && ([self _indexForGridRow:r column:c] < [[self _controller] numberOfIcons])) {

            aRect = [self _rectOfIconInRow:r column:c];
            // rect size is 6, and should be centered between icons horizontally
            aRect.origin.y += _iconSize.height + _padding.height - INSERTION_HIGHLIGHT_WIDTH / 2;
            aRect.size.height = INSERTION_HIGHLIGHT_WIDTH;    
            op = FVDropInsert;
            insertIndex = [self _indexForGridRow:r column:c] + 1;
        }
        else if ([self _getGridRow:&r column:&c atPoint:upper] && ([self _indexForGridRow:r column:c] < [[self _controller] numberOfIcons])) {
            
            aRect = [self _rectOfIconInRow:r column:c];
            aRect.origin.y -= INSERTION_HIGHLIGHT_WIDTH / 2;
            aRect.size.height = INSERTION_HIGHLIGHT_WIDTH;
            op = FVDropInsert;
            insertIndex = [self _indexForGridRow:r column:c];
        }
        else {
            
            aRect = [self visibleRect];
            op = FVDropOnView;
        }
    }
    
    if (NULL != dropRect) *dropRect = aRect;
    if (NULL != anIndex) *anIndex = insertIndex;
    return op;
}

- (BOOL)validateMenuItem:(NSMenuItem *)anItem
{
    SEL action = [anItem action];
    return (action == @selector(zoomOut:) || action == @selector(zoomIn:)) ? NO : [super validateMenuItem:anItem];
}    

@end

#pragma mark -

@implementation _FVBinding

- (id)initWithObservable:(id)observable keyPath:(NSString *)keyPath options:(NSDictionary *)options
{
    self = [super init];
    if (self) {
        _observable = [observable retain];
        _keyPath = [keyPath copyWithZone:[self zone]];
        _options = [options copyWithZone:[self zone]];
    }
    return self;
}

- (void)dealloc
{
    [_observable release];
    [_keyPath release];
    [_options release];
    [super dealloc];
}

@end
