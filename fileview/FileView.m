//
//  FileView.m
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

#import <FileView/FileView.h>
#import <FileView/FVFinderLabel.h>
#import <FileView/FVPreviewer.h>

#import <QTKit/QTKit.h>
#import <WebKit/WebKit.h>

#import "FVIcon.h"
#import "FVArrowButtonCell.h"
#import "FVUtilities.h"
#import "FVDownload.h"
#import "FVSlider.h"
#import "FVColorMenuView.h"
#import "FVViewController.h"

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
- (BOOL)_hasArrows;
- (BOOL)_showsSlider;
- (void)_reloadIconsAndController:(BOOL)shouldReloadController;

@end

enum {
    FVDropOnIcon,
    FVDropOnView,
    FVDropInsert
};
typedef NSUInteger FVDropOperation;

static NSString *FVWeblocFilePboardType = @"CorePasteboardFlavorType 0x75726C20";

#define DEFAULT_ICON_SIZE ((NSSize) { 64, 64 })
#define DEFAULT_PADDING   ((CGFloat) 32)         // 16 per side
#define MINIMUM_PADDING   ((CGFloat) 10)
#define MARGIN_BASE       ((CGFloat) 10)

#define DROP_MESSAGE_MIN_FONTSIZE ((CGFloat) 8.0)
#define DROP_MESSAGE_MAX_INSET    ((CGFloat) 20.0)

// draws grid and margin frames
#define DEBUG_GRID 0

static NSDictionary *_titleAttributes = nil;
static NSDictionary *_labeledAttributes = nil;
static NSDictionary *_subtitleAttributes = nil;
static CGFloat _titleHeight = 0.0;
static CGFloat _subtitleHeight = 0.0;
static CGColorRef _shadowColor = NULL;

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
    
    NSMutableDictionary *ta = [NSMutableDictionary dictionary];
    [ta setObject:[NSFont systemFontOfSize:12.0] forKey:NSFontAttributeName];
    [ta setObject:[NSColor darkGrayColor] forKey:NSForegroundColorAttributeName];
    NSMutableParagraphStyle *ps = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    // Apple uses this in IKImageBrowserView
    [ps setLineBreakMode:NSLineBreakByTruncatingTail];
    [ps setAlignment:NSCenterTextAlignment];
    [ta setObject:ps forKey:NSParagraphStyleAttributeName];
    [ps release];
    _titleAttributes = [ta copy];
    
    [ta setObject:[NSColor blackColor] forKey:NSForegroundColorAttributeName];
    _labeledAttributes = [ta copy];
    
    [ta setObject:[NSFont systemFontOfSize:10.0] forKey:NSFontAttributeName];
    [ta setObject:[NSColor grayColor] forKey:NSForegroundColorAttributeName];
    _subtitleAttributes = [ta copy];
    
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    _titleHeight = [lm defaultLineHeightForFont:[_titleAttributes objectForKey:NSFontAttributeName]];
    _subtitleHeight = [lm defaultLineHeightForFont:[_subtitleAttributes objectForKey:NSFontAttributeName]];
    [lm release];
    
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    CGFloat shadowComponents[] = { 0, 0, 0, 0.4 };
    _shadowColor = CGColorCreate(cspace, shadowComponents);
    CGColorSpaceRelease(cspace);
    
    // QTMovie raises if +initialize isn't sent on the AppKit thread
    [QTMovie class];
    
    // binding an NSSlider in IB 3 results in a crash on 10.4
    [self exposeBinding:@"iconScale"];
    [self exposeBinding:@"content"];
    [self exposeBinding:@"selectionIndexes"];
    [self exposeBinding:@"backgroundColor"];
}

+ (NSColor *)defaultBackgroundColor
{
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

// not part of the API because padding is private, and that's a can of worms
- (CGFloat)_columnWidth { return _iconSize.width + _padding.width; }
- (CGFloat)_rowHeight { return _iconSize.height + _padding.height; }

- (void)_commonInit 
{
    _dataSource = nil;
    _controller = [[FVViewController allocWithZone:[self zone]] initWithView:self];
    // initialize to one; we always have one or more columns, but may have zero rows
    _numberOfColumns = 1;
    _iconSize = DEFAULT_ICON_SIZE;
    _padding = [self _defaultPaddingForScale:1.0];
    _lastMouseDownLocInView = NSZeroPoint;
    _dropRectForHighlight = NSZeroRect;
    _isRescaling = NO;
    _scheduledLiveResize = NO;
    _selectedIndexes = [[NSMutableIndexSet alloc] init];
    _lastClickedIndex = NSNotFound;
    _rubberBandRect = NSZeroRect;
    _isMouseDown = NO;
    _isEditable = NO;
    [self setBackgroundColor:[[self class] defaultBackgroundColor]];
    _selectionOverlay = NULL;
        
    CFAllocatorRef alloc = CFAllocatorGetDefault();
    
    _lastOrigin = NSZeroPoint;
    _timeOfLastOrigin = CFAbsoluteTimeGetCurrent();
    _trackingRectMap = CFDictionaryCreateMutable(alloc, 0, &FVIntegerKeyDictionaryCallBacks, &FVIntegerValueDictionaryCallBacks);
        
    _leftArrow = [[FVArrowButtonCell alloc] initWithArrowDirection:FVArrowLeft];
    [_leftArrow setTarget:self];
    [_leftArrow setAction:@selector(leftArrowAction:)];
    
    _rightArrow = [[FVArrowButtonCell alloc] initWithArrowDirection:FVArrowRight];
    [_rightArrow setTarget:self];
    [_rightArrow setAction:@selector(rightArrowAction:)];
    
    _leftArrowFrame = NSZeroRect;
    _rightArrowFrame = NSZeroRect;
    
    // don't waste memory on this for single-column case
    if ([self _showsSlider]) {
        _sliderWindow = [[FVSliderWindow alloc] init];
        FVSlider *slider = [_sliderWindow slider];
        // binding & unbinding is handled in viewWillMoveToSuperview:
        [slider setMaxValue:15];
        [slider setMinValue:1.0];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSliderMouseExited:) name:FVSliderMouseExitedNotificationName object:slider];
    }
    // always initialize this to -1
    _sliderTag = -1;
    
    _selectionBinding = nil;
    _isObservingSelectionIndexes = NO;
    
}

#pragma mark NSView overrides

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    [self _commonInit];
    return self;
}

- (id)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    [self _commonInit];
    return self;
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
    FVAPIAssert2(nil == _selectionBinding, @"failed to remove unbind %@ from %@; leaking observation info", ((_FVBinding *)_selectionBinding)->_observable, self);
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
    return _isDrawingDragImage ? [NSColor clearColor] : _backgroundColor;
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
#if __LP64__
        desiredRect.origin.y = rint(NSMinY(bounds) + scrollPosition.y * (NSHeight(bounds) - NSHeight(desiredRect)));
#else
        desiredRect.origin.y = rintf(NSMinY(bounds) + scrollPosition.y * (NSHeight(bounds) - NSHeight(desiredRect)));
#endif
        if (NSMinY(desiredRect) < NSMinY(bounds))
            desiredRect.origin.y = NSMinY(bounds);
        else if (NSMaxY(desiredRect) > NSMaxY(bounds))
            desiredRect.origin.y = NSMaxY(bounds) - NSHeight(desiredRect);
    }
    
    // Horizontal position
    if (NSWidth(desiredRect) < NSWidth(bounds)) {
        scrollPosition.x = MAX(scrollPosition.x, 0.0);
        scrollPosition.x = MIN(scrollPosition.x, 1.0);
#if __LP64__
        desiredRect.origin.x = rint(NSMinX(bounds) + scrollPosition.x * (NSWidth(bounds) - NSWidth(desiredRect)));
#else
        desiredRect.origin.x = rintf(NSMinX(bounds) + scrollPosition.x * (NSWidth(bounds) - NSWidth(desiredRect)));
#endif
        if (NSMinX(desiredRect) < NSMinX(bounds))
            desiredRect.origin.x = NSMinX(bounds);
        else if (NSMaxX(desiredRect) > NSMaxX(bounds))
            desiredRect.origin.x = NSMaxX(bounds) - NSHeight(desiredRect);
    }
    
    [self scrollPoint:desiredRect.origin];
}

- (void)setIconScale:(CGFloat)scale;
{
    FVAPIAssert(scale > 0, @"scale must be greater than zero");
    _iconSize.width = DEFAULT_ICON_SIZE.width * scale;
    _iconSize.height = DEFAULT_ICON_SIZE.height * scale;
    
    // arrows out of place now, they will be added again when required when resetting the tracking rects
    [self _hideArrows];
    
    CGLayerRelease(_selectionOverlay);
    _selectionOverlay = NULL;
    
    NSPoint scrollPoint = [self scrollPercentage];
    
    // the grid and cursor rects have changed
    [self _reloadIconsAndController:NO];
    [self setScrollPercentage:scrollPoint];
    
    // Schedule a reload so we always have the correct quality icons, but don't do it while scaling in response to a slider.
    // This will also scroll to the first selected icon; maintaining scroll position while scaling is too jerky.
    if (NO == _isRescaling) {
        _isRescaling = YES;
        // this is only sent in the default runloop mode, so it's not sent during event tracking
        [self performSelector:@selector(_rescaleComplete) withObject:nil afterDelay:0.0];
    }
}

- (CGFloat)iconScale;
{
    return _iconSize.width / DEFAULT_ICON_SIZE.width;
}
    
- (void)_registerForDraggedTypes
{
    if (_isEditable && _dataSource) {
        const SEL selectors[] = 
        { 
            @selector(fileView:insertURLs:atIndexes:),
            @selector(fileView:replaceURLsAtIndexes:withURLs:), 
            @selector(fileView:moveURLsAtIndexes:toIndex:),
            @selector(fileView:deleteURLsAtIndexes:) 
        };
        NSUInteger i, iMax = sizeof(selectors) / sizeof(SEL);
        for (i = 0; i < iMax; i++)
            FVAPIAssert1([_dataSource respondsToSelector:selectors[i]], @"datasource must implement %@", NSStringFromSelector(selectors[i]));

        [self registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType, NSURLPboardType, FVWeblocFilePboardType, (NSString *)kUTTypeURL, (NSString *)kUTTypeUTF8PlainText, NSStringPboardType, nil]];
    } else {
        [self registerForDraggedTypes:nil];
    }
}

- (void)awakeFromNib
{
    if ([[FileView superclass] instancesRespondToSelector:@selector(awakeFromNib)])
        [super awakeFromNib];
    // if the datasource connection is made in the nib, the drag type setup doesn't get done
    [self _registerForDraggedTypes];
}

- (void)setDataSource:(id)obj;
{
    if (obj) {
        FVAPIAssert1([obj respondsToSelector:@selector(numberOfIconsInFileView:)], @"datasource must implement %@", NSStringFromSelector(@selector(numberOfIconsInFileView:)));
        FVAPIAssert1([obj respondsToSelector:@selector(fileView:URLAtIndex:)], @"datasource must implement %@", NSStringFromSelector(@selector(fileView:URLAtIndex:)));
    }
    _dataSource = obj;
    [_controller setDataSource:obj];
    
    [self _registerForDraggedTypes];
    
    // datasource may implement subtitles, which affects our drawing layout (padding height)
    [self reloadIcons];
}

- (id)dataSource { return _dataSource; }

- (BOOL)isEditable 
{ 
    return _isEditable;
}

- (void)setEditable:(BOOL)flag 
{
    if (_isEditable != flag) {
        _isEditable = flag;
        
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
- (CGFloat)_topMargin { return _titleHeight; }
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
#if __LP64__
    CGFloat extraMargin = round(4.0 * scale);
#else
    CGFloat extraMargin = roundf(4.0 * scale);
#endif
    size.width = MINIMUM_PADDING + extraMargin;
    size.height = _titleHeight + 4.0 + extraMargin;
    if ([_dataSource respondsToSelector:@selector(fileView:subtitleAtIndex:)])
        size.height += _subtitleHeight;
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
#if __LP64__
    CGFloat horizontalExpansion = floor(_padding.width / 2.0);
#else
    CGFloat horizontalExpansion = floorf(_padding.width / 2.0);
#endif
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
        _sliderTag = [self addTrackingRect:sliderRect owner:self userData:_sliderWindow assumeInside:NSPointInRect(mouseLoc, sliderRect)];  
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
                    BOOL mouseInside = NSPointInRect(mouseLoc, iconRect);
                    
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
        [_controller reload];
        
        // Follow NSTableView's example and clear selection outside the current range of indexes
        NSUInteger lastSelIndex = [_selectedIndexes lastIndex];
        if (NSNotFound != lastSelIndex && lastSelIndex >= [_controller numberOfIcons]) {
            [self willChangeValueForKey:@"selectionIndexes"];
            [_selectedIndexes removeIndexesInRange:NSMakeRange([_controller numberOfIcons], lastSelIndex + 1 - [_controller numberOfIcons])];
            [self didChangeValueForKey:@"selectionIndexes"];
        }
    }
    
    [self _recalculateGridSize];
    
    // grid may have changed, so do a full redisplay
    [self setNeedsDisplay:YES];
    
    /* 
     Any time the number of icons or scale changes, cursor rects are garbage and need to be reset.  The approved way to do this is by calling invalidateCursorRectsForView:, and the docs say to never invoke -[NSView resetCursorRects] manually.  Unfortunately, tracking rects are still active even though the window isn't key, and we show buttons for non-key windows.  As a consequence, if the number of icons just changed from (say) 3 to 1 in a non-key view, it can receive mouseEntered: events for the now-missing icons.  Possibly we don't need to reset cursor rects since they only change for the key window, but we'll reset everything manually just in case.  Allow NSWindow to handle it if the window is key.
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

- (void)setContent:(id)content { [self setIconURLs:content]; }
- (id)content { return [self iconURLs]; }

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"selectionIndexes"]) {
        
        _FVBinding *selBinding = _selectionBinding;
        
        NSParameterAssert(context == self || context == selBinding);
        if (selBinding && context == self) {
            // update the controller's selection; this call will cause a KVO notification that we'll also observe
            [selBinding->_observable setValue:_selectedIndexes forKeyPath:selBinding->_keyPath];
            
            // since this will be called multiple times for a single event, we should only run the preview once
            FVPreviewer *previewer = [FVPreviewer sharedPreviewer];
            if ([previewer isPreviewing] && NSNotFound != [_selectedIndexes firstIndex]) {
                [previewer setWebViewContextMenuDelegate:[self delegate]];
                [previewer previewURL:[_controller URLAtIndex:[_selectedIndexes firstIndex]] forIconInRect:[[previewer window] frame]];
            }
        }
        else if (selBinding && context == selBinding) {
            NSIndexSet *controllerSet = [selBinding->_observable valueForKeyPath:selBinding->_keyPath];
            // since we manipulate _selectedIndexes directly, this won't cause a looping notification
            if ([controllerSet isEqualToIndexSet:_selectedIndexes] == NO) {
                [_selectedIndexes removeAllIndexes];
                [_selectedIndexes addIndexes:controllerSet];
            }
        }
        else {
            NSLog(@"*** error *** unhandled case in %@", NSStringFromSelector(_cmd));
        }
        [self setNeedsDisplay:YES];
    }
}

- (void)bind:(NSString *)binding toObject:(id)observable withKeyPath:(NSString *)keyPath options:(NSDictionary *)options;
{
    // Note: we don't bind to this, some client does.  We do register as an observer, but that's a different code path.
    if ([binding isEqualToString:@"selectionIndexes"]) {
        
        FVAPIAssert3(nil == _selectionBinding, @"attempt to bind %@ to %@ when bound to %@", keyPath, observable, ((_FVBinding *)_selectionBinding)->_observable);
        
        // Create an object to handle the binding mechanics manually; it's deallocated when the client unbinds.
        _selectionBinding = [[_FVBinding alloc] initWithObservable:observable keyPath:keyPath options:options];
        [observable addObserver:self forKeyPath:keyPath options:0 context:_selectionBinding];
    }
    
    // ??? the IB inspector doesn't show values properly unless I call super for that case as well
    [super bind:binding toObject:observable withKeyPath:keyPath options:options];
}

- (void)unbind:(NSString *)binding
{    
    [super unbind:binding];

    if ([binding isEqualToString:@"selectionIndexes"]) {
        FVAPIAssert2(nil != _selectionBinding, @"%@: attempt to unbind %@ when unbound", self, binding);
        [_selectionBinding release];
        _selectionBinding = nil;
    }
    else if ([binding isEqualToString:@"iconURLs"]) {
        [_controller setIconURLs:nil];
        // Calling -[super unbind:binding] after this may cause selection to be reset; this happens with the controller in the demo project, since it unbinds in the wrong order.  We should be resilient against that, so we unbind first.
        [self setSelectionIndexes:[NSIndexSet indexSet]];
    }
    [self reloadIcons];
}

- (NSDictionary *)infoForBinding:(NSString *)binding;
{
    NSDictionary *info = nil;
    if ([binding isEqualToString:@"selectionIndexes"] && nil != _selectionBinding) {
        NSMutableDictionary *bindingInfo = [NSMutableDictionary dictionary];
        _FVBinding *selBinding = _selectionBinding;
        if (selBinding->_observable) [bindingInfo setObject:selBinding->_observable forKey:NSObservedObjectKey];
        if (selBinding->_keyPath) [bindingInfo setObject:selBinding->_keyPath forKey:NSObservedKeyPathKey];
        if (selBinding->_options) [bindingInfo setObject:selBinding->_options forKey:NSOptionsKey];
        info = bindingInfo;
    }
    else {
        info = [super infoForBinding:binding];
    }
    return info;
}

- (void)viewWillMoveToSuperview:(NSView *)newSuperview
{
    [super viewWillMoveToSuperview:newSuperview];
    
    // mmalc's example unbinds here for a nil superview, but that causes problems if you remove the view and add it back in later (and also can cause crashes as a side effect, if we're not careful with the datasource)
    if (nil == newSuperview) {

        if (_isObservingSelectionIndexes) 
            [self removeObserver:self forKeyPath:@"selectionIndexes"];

        [_controller cancelQueuedOperations];
        
        // break a retain cycle; binding is retaining this view
        [[_sliderWindow slider] unbind:@"value"];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:FVSliderMouseExitedNotificationName object:nil];
    }
    else {
        
        if (NO == _isObservingSelectionIndexes)
            [self addObserver:self forKeyPath:@"selectionIndexes" options:0 context:self];
        
        // bind here (noop if we don't have a slider)
        FVSlider *slider = [_sliderWindow slider];
        [slider bind:@"value" toObject:self withKeyPath:@"iconScale" options:nil];
        if (slider)
            [[NSNotificationCenter defaultCenter] addObserver:self 
                                                     selector:@selector(handleSliderMouseExited:) 
                                                         name:FVSliderMouseExitedNotificationName 
                                                       object:slider];      
    }
}

- (void)setIconURLs:(NSArray *)anArray;
{
    [_controller setIconURLs:anArray];
    [self setSelectionIndexes:[NSIndexSet indexSet]];
    // datasource methods all trigger a redisplay, so we have to do the same here
    [self reloadIcons];
}

- (NSArray *)iconURLs;
{
    return [_controller iconURLs];
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
    
    // Required frame using default padding.  The only time we don't use NSWidth(minFrame) is when we have a single column of icons, and the scale is such that icons are clipped horizontally (i.e. we have a horizontal scroller).
    frame.size.width = MAX([self _columnWidth] * [self _numberOfColumnsInFrame:minFrame] + 2 * MARGIN_BASE, NSWidth(minFrame));
    frame.size.height = MAX([self _rowHeight] * [self numberOfRows] + [self _topMargin] + [self _bottomMargin], NSHeight(minFrame));

    // Add a column, then see if we can shrink padding enough to fit it in.  If not, expand padding so we have uniform spacing across the grid.
    NSUInteger ncolumns = [self _numberOfColumnsInFrame:frame] + 1;

    // Compute the number of rows to match our adjusted number of columns
    NSUInteger ni = [_controller numberOfIcons];
    NSUInteger nrows = ni / ncolumns + (ni % ncolumns > 0 ? 1 : 0);
    
    // may not be enough columns to fill a single row; this causes a single icon to be centered across the view
    if (1 == nrows) ncolumns = ni;
    
    // Note: side margins are f(padding), so frameWidth = 2 * (padding / 2 + MARGIN_BASE) + width_icon * ncolumns + padding * (ncolumns - 1).  Top and bottom margins are constant, so the accessors are used.
    CGFloat horizontalPadding = (NSWidth(frame) - 2 * MARGIN_BASE - _iconSize.width * ncolumns) / ((CGFloat)ncolumns);
    
    if (horizontalPadding < MINIMUM_PADDING) {
        // recompute based on default number of rows and columns
        ncolumns -= 1;
        nrows = ni / ncolumns + (ni % ncolumns > 0 ? 1 : 0);
        horizontalPadding = (NSWidth(frame) - 2 * MARGIN_BASE - _iconSize.width * ncolumns) / ((CGFloat)ncolumns);
    }

    NSParameterAssert(horizontalPadding > 0);    
    _padding.width = horizontalPadding;
    
    frame.size.width = MAX([self _columnWidth] * ncolumns + 2 * MARGIN_BASE, NSWidth(minFrame));
    frame.size.height = MAX([self _rowHeight] * nrows + [self _topMargin] + [self _bottomMargin], NSHeight(minFrame));

    // this is a hack to avoid edge cases when resizing; sometimes computing it based on width would give an inconsistent result
    _numberOfColumns = ncolumns;

    // reentrancy:  setFrame: may cause the scrollview to call resizeWithOldSuperviewSize:, so set all state before calling it
    if (NSEqualRects(frame, [self frame]) == NO) {
        [self setFrame:frame];  
        
        // Occasionally the scrollview with autohiding scrollers shows a horizontal scroller unnecessarily; it goes away as soon as the view is scrolled, with no change to the frame or padding.  Sending -[scrollView tile] doesn't seem to fix it, nor does setNeedsDisplay:YES; it seems to be an edge case with setting the frame when the last row of icon subtitles are near the bottom of the view.  Using reflectScrollClipView: seems to work reliably, and should at least be harmless.
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
    _isRescaling = NO;
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

- (void)_drawDropHighlightInRect:(NSRect)aRect;
{
    static NSColor *strokeColor = nil;
    static NSColor *fillColor = nil;
    if (nil == strokeColor) {
        fillColor = [[[[NSColor alternateSelectedControlColor] colorWithAlphaComponent:0.2] colorUsingColorSpaceName:NSDeviceRGBColorSpace] retain];
        strokeColor = [[[[NSColor alternateSelectedControlColor] colorWithAlphaComponent:0.8] colorUsingColorSpaceName:NSDeviceRGBColorSpace] retain];
    }
    [strokeColor setStroke];
    [fillColor setFill];
    
    CGFloat lineWidth = 2.0;
    NSBezierPath *p;
    NSUInteger r, c;
    
    if (NSEqualRects(aRect, [self visibleRect]) || [self _getGridRow:&r column:&c atPoint:NSMakePoint(NSMidX(aRect), NSMidY(aRect))]) {
        // it's either a drop on the whole table or on top of a cell
        p = [NSBezierPath fv_bezierPathWithRoundRect:NSInsetRect(aRect, 0.5 * lineWidth, 0.5 * lineWidth) xRadius:7 yRadius:7];
    }
    else {
        
        // similar to NSTableView's between-row drop indicator
        NSRect rect = aRect;
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
    }
    [p setLineWidth:lineWidth];
    [p stroke];
    [p fill];
    [p setLineWidth:1.0];
}

- (void)_drawHighlightInRect:(NSRect)aRect;
{
    CGContextRef drawingContext = [[NSGraphicsContext currentContext] graphicsPort];
    
    // drawing into a CGImage and then overlaying it keeps the rubber band highlight much more responsive
    if (NULL == _selectionOverlay) {
        
        _selectionOverlay = CGLayerCreateWithContext(drawingContext, CGSizeMake(NSWidth(aRect), NSHeight(aRect)), NULL);
        CGContextRef layerContext = CGLayerGetContext(_selectionOverlay);
        NSRect imageRect = NSZeroRect;
        CGSize layerSize = CGLayerGetSize(_selectionOverlay);
        imageRect.size.height = layerSize.height;
        imageRect.size.width = layerSize.width;
        CGContextClearRect(layerContext, *(CGRect *)&imageRect);
        
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
    // make sure we use source over for drawing the image
    CGContextSaveGState(drawingContext);
    CGContextSetBlendMode(drawingContext, kCGBlendModeNormal);
    CGContextDrawLayerInRect(drawingContext, *(CGRect *)&aRect, _selectionOverlay);
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

static NSArray * _wordsFromAttributedString(NSAttributedString *attributedString)
{
    NSString *string = [attributedString string];
    
    // !!! early return on 10.4
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
#if __LP64__
    return ceil(width);
#else
    return ceilf(width);
#endif
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

- (void)handleKeyNotification:(NSNotification *)aNote
{
    [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToWindow;
{
    // for redrawing background color
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSWindow *window = [self window];
    if (window) {
        [nc addObserver:self selector:@selector(handleKeyNotification:) name:NSWindowDidBecomeKeyNotification object:window];
        [nc addObserver:self selector:@selector(handleKeyNotification:) name:NSWindowDidResignKeyNotification object:window];
    }
    else {
        [nc removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
        [nc removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    }
}

// redraw at full quality after a resize
- (void)viewDidEndLiveResize
{
    [self setNeedsDisplay:YES];
    _scheduledLiveResize = NO;
}

// only invoked when autoscrolling or in response to user action
- (NSRect)adjustScroll:(NSRect)proposedVisibleRect
{    
    NSRect r = [super adjustScroll:proposedVisibleRect];
    _timeOfLastOrigin = CFAbsoluteTimeGetCurrent();
    _lastOrigin = [self visibleRect].origin;
    
    return r;
}

// positive = scroller moving down
// negative = scroller moving upward
- (CGFloat)_scrollVelocity
{
    return ([self visibleRect].origin.y - _lastOrigin.y) / (CFAbsoluteTimeGetCurrent() - _timeOfLastOrigin);
}

// This method is conservative.  It doesn't test icon rects for intersection in the rect argument, but simply estimates the maximum range of rows and columns required for complete drawing in the given rect.  Hence, it can't be used for determining rubber band selection indexes or anything requiring a precise range (this is why it's private), but it's guaranteed to be fast.
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

    // this method is now called with only the icons being drawn, not necessarily everything that's visible; we need to compute visibility to avoid calling -releaseResources on the wrong icons
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
        
    // Call this only for icons that we're not going to display "soon."  The problem with this approach is that if you only have a single icon displayed at a time (say in a master-detail view), FVIcon cache resources will continue to be used up since each one is cached and then never touched again (if it doesn't show up in this loop, that is).  We handle this by using a timer that culls icons which are no longer present in the datasource.  I suppose this is only a symptom of the larger problem of a view maintaining a cache of model objects...but expecting a client to be aware of our caching strategy and icon management is a bit much.  
    
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
            // Since the same FVIcon instance is returned for duplicate URLs, the same icon instance may receive -renderOffscreen and -releaseResources in the same pass if it represents a visible icon and a hidden icon.
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
    if (isResizing || _isRescaling) {
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
            
    BOOL isDrawingToScreen = [ctxt isDrawingToScreen];
    
    // we should use the fast path when scrolling at small sizes; PDF sucks in that case...
    
    BOOL useFastDrawingPath = (isResizing || _isRescaling || ([self _isFastScrolling] && _iconSize.height <= 256));
    
    // redraw at high quality after scrolling
    if (useFastDrawingPath && NO == _scheduledLiveResize && [self _isFastScrolling]) {
        _scheduledLiveResize = YES;
        [self performSelector:@selector(viewDidEndLiveResize) withObject:nil afterDelay:0 inModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
    }
    
    // shadow needs to be scaled as the icon scale changes to approximate the IconServices shadow
    CGFloat shadowBlur = 2.0 * [self iconScale];
    CGSize shadowOffset = CGSizeMake(0.0, -[self iconScale]);
    
    // iterate each row/column to see if it's in the dirty rect, and evaluate the current cache state
    for (r = rMin; r < rMax; r++) 
    {
        for (c = cMin; c < cMax && NSNotFound != (i = [self _indexForGridRow:r column:c]); c++) 
        {
            // if we're creating a drag image, only draw selected icons
            if (NO == _isDrawingDragImage || [_selectedIndexes containsIndex:i]) {
            
                NSRect fileRect = [self _rectOfIconInRow:r column:c];
                NSURL *aURL = [_controller URLAtIndex:i];
                NSRect textRect = [self _rectOfTextForIconRect:fileRect];
                
                // always draw icon and text together, as they may overlap due to shadow and finder label, and redrawing a part may look odd
                BOOL willDrawIcon = _isDrawingDragImage || [self needsToDrawRect:NSUnionRect(NSInsetRect(fileRect, -2.0 * [self iconScale], 0), textRect)];

                if (willDrawIcon) {

                    FVIcon *image = [_controller iconAtIndex:i];
                    
                    // note that iconRect will be transformed for a flipped context
                    NSRect iconRect = fileRect;
                    
                    // draw highlight, then draw icon over it, as Finder does
                    if ([_selectedIndexes containsIndex:i])
                        [self _drawHighlightInRect:NSInsetRect(fileRect, -4, -4)];
                    
                    CGContextSaveGState(cgContext);
                    
                    // draw a shadow behind the image/page
                    CGContextSetShadowWithColor(cgContext, shadowOffset, shadowBlur, _shadowColor);
                    
                    // possibly better performance by caching all bitmaps in a flipped state, but bookkeeping is a pain
                    CGContextTranslateCTM(cgContext, 0, NSMaxY(iconRect));
                    CGContextScaleCTM(cgContext, 1, -1);
                    iconRect.origin.y = 0;
                    
                    // Note: don't use integral rects here to avoid res independence issues (on Tiger, centerScanRect: just makes an integral rect).  The icons may create an integral bitmap context, but it'll still be drawn into this rect with correct scaling.
                    iconRect = [self centerScanRect:iconRect];
                    
                    if (NO == isDrawingToScreen && [image needsRenderForSize:_iconSize])
                        [image renderOffscreen];
                                    
                    if (useFastDrawingPath)
                        [image fastDrawInRect:iconRect ofContext:cgContext];
                    else
                        [image drawInRect:iconRect ofContext:cgContext];
                    
                    CGContextRestoreGState(cgContext);
                    CGContextSaveGState(cgContext);
                    
                    textRect = [self centerScanRect:textRect];
                    
                    // draw Finder label and text over the icon/shadow
                    
                    NSString *name, *subtitle = [_controller subtitleAtIndex:i];
                    NSUInteger label;
                    [_controller getDisplayName:&name andLabel:&label forURL:aURL];
                    NSStringDrawingOptions stringOptions = NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingOneShot;
                    
                    if (label > 0) {
                        CGRect labelRect = *(CGRect *)&textRect;
                        labelRect.size.height = _titleHeight;                        
                        [FVFinderLabel drawFinderLabel:label inRect:labelRect ofContext:cgContext flipped:YES roundEnds:YES];
                        
                        // labeled title uses black text for greater contrast; inset horizontally because of the rounded end caps
                        NSRect titleRect = NSInsetRect(textRect, _titleHeight / 2.0, 0);
                        [name drawWithRect:titleRect options:stringOptions attributes:_labeledAttributes];
                    }
                    else {
                        [name drawWithRect:textRect options:stringOptions attributes:_titleAttributes];
                    }
                    
                    if (subtitle) {
                        textRect.origin.y += _titleHeight;
                        textRect.size.height -= _titleHeight;
                        [subtitle drawWithRect:textRect options:stringOptions attributes:_subtitleAttributes];
                    }
                    CGContextRestoreGState(cgContext);
                } 
#if DEBUG_GRID
                [NSGraphicsContext saveGraphicsState];
                if (c % 2 && !(r % 2))
                    [[NSColor redColor] setFill];
                else
                    [[NSColor greenColor] setFill];
                NSFrameRect(NSUnionRect(NSInsetRect(fileRect, -2.0 * [self iconScale], 0), textRect));                
                [NSGraphicsContext restoreGraphicsState];
#endif
            }
        }
    }
    
    // avoid hitting the cache thread while a live resize is in progress, but allow cache updates while scrolling
    // use the same range criteria that we used in iterating icons
    NSUInteger iMin = indexRange.location, iMax = NSMaxRange(indexRange);
    if (NO == isResizing && NO == _isRescaling && isDrawingToScreen)
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

- (void)drawRect:(NSRect)rect;
{
    [super drawRect:rect];
    
    BOOL isDrawingToScreen = [[NSGraphicsContext currentContext] isDrawingToScreen];

    if (isDrawingToScreen) {
        [[self backgroundColor] setFill];
        NSRectFillUsingOperation(rect, NSCompositeCopy);
    }
        
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
        
        if ([self _hasArrows] && _isDrawingDragImage == NO) {
            if (NSIntersectsRect(rect, _leftArrowFrame))
                [_leftArrow drawWithFrame:_leftArrowFrame inView:self];
            if (NSIntersectsRect(rect, _rightArrowFrame))
                [_rightArrow drawWithFrame:_rightArrowFrame inView:self];
        }
        
        // drop highlight and rubber band are mutually exclusive
        if (NSIsEmptyRect(_dropRectForHighlight) == NO) {
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
        [[self dataSource] fileView:self deleteURLsAtIndexes:_selectedIndexes];
        [self setSelectionIndexes:[NSIndexSet indexSet]];
        [self reloadIcons];
    }
}

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    // Adding NSDragOperationLink for non-local drags gives us behavior similar to the NSDocument proxy icon, allowing the receiving app to decide what is appropriate; hence, in Finder it now defaults to alias, and you can use option to force a copy.
    NSDragOperation mask = NSDragOperationCopy | NSDragOperationLink;
    if (isLocal)
        mask |= NSDragOperationMove;
    else if ([self isEditable])
        mask |= NSDragOperationDelete;
    return mask;
}

- (void)dragImage:(NSImage *)anImage at:(NSPoint)viewLocation offset:(NSSize)unused event:(NSEvent *)event pasteboard:(NSPasteboard *)pboard source:(id)sourceObj slideBack:(BOOL)slideFlag;
{            
    NSScrollView *scrollView = [self enclosingScrollView] ? [self enclosingScrollView] : (id)self;
    NSRect boundsRect = scrollView ? [scrollView convertRect:[scrollView documentVisibleRect] fromView:self] : [self bounds];
    
    NSPoint dragPoint = [scrollView bounds].origin;
    dragPoint.y += NSHeight([scrollView bounds]);
    dragPoint = [scrollView convertPoint:dragPoint toView:self];
    
    // this will force a redraw of the entire area into the cached image
    NSBitmapImageRep *imageRep = [scrollView bitmapImageRepForCachingDisplayInRect:boundsRect];
    
    // set a flag so only the selected icons are drawn and background is set to clear
    _isDrawingDragImage = YES;    
    [scrollView cacheDisplayInRect:boundsRect toBitmapImageRep:imageRep];
    _isDrawingDragImage = NO;

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

- (void)_updateButtonsForIcon:(FVIcon *)anIcon;
{
    NSUInteger curPage = [anIcon currentPageIndex];
    [_leftArrow setEnabled:curPage != 1];
    [_rightArrow setEnabled:curPage != [anIcon pageCount]];
    NSUInteger r, c;
    // _getGridRow should always succeed.  Drawing entire icon since a mouseover can occur between the time the icon is loaded and drawn, so only the part of the icon below the buttons is drawn (at least, I think that's what happens...)
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

- (BOOL)_hasArrows {
    return [_leftArrow representedObject] != nil;
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
            CGFloat side;
#if __LP64__
            side = round(NSHeight(iconRect) / 5);
#else
            side = roundf(NSHeight(iconRect) / 5);
#endif
            side = MIN(side, 32);
            side = MAX(side, 10);
            // 2 pixels between arrows horizontally, and 4 pixels between bottom of arrow and bottom of iconRect
            _leftArrowFrame = _rightArrowFrame = NSMakeRect(NSMidX(iconRect) + 2, NSMaxY(iconRect) - side - 4, side, side);
            _leftArrowFrame.origin.x -= side + 4;
            
            [_leftArrow setRepresentedObject:anIcon];
            [_rightArrow setRepresentedObject:anIcon];
            
            // set enabled states
            [self _updateButtonsForIcon:anIcon];
            
            [self setNeedsDisplayInRect:NSUnionRect(_leftArrowFrame, _rightArrowFrame)];
        }
    }
}

- (void)_hideArrows
{
    if ([self _hasArrows]) {
        [_leftArrow setRepresentedObject:nil];
        [_rightArrow setRepresentedObject:nil];
        [self setNeedsDisplayInRect:NSUnionRect(_leftArrowFrame, _rightArrowFrame)];
    }
}

- (void)mouseEntered:(NSEvent *)event;
{
    const NSTrackingRectTag tag = [event trackingNumber];
    NSUInteger anIndex;
    
    // Finder doesn't show buttons unless it's the front app.  If Finder is the front app, it shows them for any window, regardless of main/key state, so we'll do the same.
    if ([NSApp isActive]) {
        if (CFDictionaryGetValueIfPresent(_trackingRectMap, (const void *)tag, (const void **)&anIndex))
            [self _showArrowsForIconAtIndex:anIndex];
        else if ([self _showsSlider] && [event userData] == _sliderWindow) {
            
            if ([[[self window] childWindows] containsObject:_sliderWindow] == NO) {
                NSRect sliderRect = [self _sliderRect];
                sliderRect = [self convertRect:sliderRect toView:nil];
                sliderRect.origin = [[self window] convertBaseToScreen:sliderRect.origin];
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

// we can't do this in mouseExited: since it's received as soon as the mouse enters the slider's window (and checking the mouse location just postpones the problems)
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
             [[self delegate] fileView:self shouldOpenURL:aURL] == YES))
            [[NSWorkspace sharedWorkspace] openURL:aURL];
    }
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)userData
{
    NSURL *theURL = [self _URLAtPoint:point];
    NSString *name;
    if ([theURL isFileURL] && noErr == LSCopyDisplayNameForURL((CFURLRef)theURL, (CFStringRef *)&name))
        name = [name autorelease];
    else
        name = [theURL absoluteString];
    return name;
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
        unichar ch = [[event characters] characterAtIndex:0];
        NSUInteger flags = [event modifierFlags];
        
        switch(ch) {
            case 0x0020:
                if ((flags & NSShiftKeyMask) != 0)
                    [[self enclosingScrollView] pageUp:self];
                else
                    [[self enclosingScrollView] pageDown:self];
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
    _isMouseDown = YES;
    
    NSPoint p = [event locationInWindow];
    p = [self convertPoint:p fromView:nil];
    _lastMouseDownLocInView = p;

    NSUInteger flags = [event modifierFlags];
    NSUInteger r, c, i;
    
    if ([self _hasArrows] && NSMouseInRect(p, _leftArrowFrame, [self isFlipped])) {
        [_leftArrow trackMouse:event inRect:_leftArrowFrame ofView:self untilMouseUp:YES];
    }
    else if ([self _hasArrows] && NSMouseInRect(p, _rightArrowFrame, [self isFlipped])) {
        [_rightArrow trackMouse:event inRect:_rightArrowFrame ofView:self untilMouseUp:YES];
    }
    // mark this icon for highlight if necessary
    else if ([self _getGridRow:&r column:&c atPoint:p]) {
        
        // remember _indexForGridRow:column: returns NSNotFound if you're in an empty slot of an existing row/column, but that's a deselect event so we still need to remove all selection indexes and mark for redisplay
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
                    [self willChangeValueForKey:@"selectionIndexes"];
                    [_selectedIndexes addIndex:i];
                    [self didChangeValueForKey:@"selectionIndexes"];
                }
                else if ((flags & NSShiftKeyMask) != 0) {
                    // Shift-click extends by a region; this is equivalent to iPhoto's grid view.  Finder treats shift-click like cmd-click in icon view, but we have a fixed layout, so this behavior is convenient and will be predictable.
                    
                    // at this point, we know that [_selectedIndexes count] > 0
                    NSParameterAssert([_selectedIndexes count]);
                    
                    NSUInteger start = [_selectedIndexes firstIndex];
                    NSUInteger end = [_selectedIndexes lastIndex];

                    if (i < start) {
                        [self willChangeValueForKey:@"selectionIndexes"];
                        [_selectedIndexes addIndexesInRange:NSMakeRange(i, start - i)];
                        [self didChangeValueForKey:@"selectionIndexes"];
                    }
                    else if (i > end) {
                        [self willChangeValueForKey:@"selectionIndexes"];
                        [_selectedIndexes addIndexesInRange:NSMakeRange(end + 1, i - end)];
                        [self didChangeValueForKey:@"selectionIndexes"];
                    }
                    else if (NSNotFound != _lastClickedIndex) {
                        // This handles the case of clicking in a deselected region between two selected regions.  We want to extend from the last click to the current one, instead of randomly picking an end to start from.
                        [self willChangeValueForKey:@"selectionIndexes"];
                        if (_lastClickedIndex > i)
                            [_selectedIndexes addIndexesInRange:NSMakeRange(i, _lastClickedIndex - i)];
                        else
                            [_selectedIndexes addIndexesInRange:NSMakeRange(_lastClickedIndex + 1, i - _lastClickedIndex)];
                        [self didChangeValueForKey:@"selectionIndexes"];
                    }
                }
                [self setNeedsDisplay:YES];     
            }
        }
        else if ((flags & NSCommandKeyMask) != 0) {
            // cmd-clicked a previously selected index, so remove it from the selection
            [self willChangeValueForKey:@"selectionIndexes"];
            [_selectedIndexes removeIndex:i];
            [self didChangeValueForKey:@"selectionIndexes"];
            [self setNeedsDisplay:YES];
        }
        
        // always reset this
        _lastClickedIndex = i;
        
        // change selection first, as Finder does
        if ([event clickCount] > 1 && [self _URLAtPoint:p] != nil) {
            if (flags & NSAlternateKeyMask) {
                FVPreviewer *previewer = [FVPreviewer sharedPreviewer];
                [previewer setWebViewContextMenuDelegate:[self delegate]];
                [self _getGridRow:&r column:&c atPoint:p];
                NSRect iconRect = [self _rectOfIconInRow:r column:c];
                iconRect = [self convertRect:iconRect toView:nil];
                NSPoint origin = [[self window] convertBaseToScreen:iconRect.origin];
                iconRect.origin = origin;
                [previewer previewURL:[self _URLAtPoint:p] forIconInRect:iconRect];
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

static NSRect _rectWithCorners(NSPoint aPoint, NSPoint bPoint) {
    NSRect rect;
    rect.origin.x = MIN(aPoint.x, bPoint.x);
    rect.origin.y = MIN(aPoint.y, bPoint.y);
#if __LP64__
    rect.size.width = fmax(3.0, fmax(aPoint.x, bPoint.x) - NSMinX(rect));
    rect.size.height = fmax(3.0, fmax(aPoint.y, bPoint.y) - NSMinY(rect));
#else
    rect.size.width = fmaxf(3.0, fmaxf(aPoint.x, bPoint.x) - NSMinX(rect));
    rect.size.height = fmaxf(3.0, fmaxf(aPoint.y, bPoint.y) - NSMinY(rect));
#endif    
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
    _isMouseDown = NO;
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
    
    if (NSEqualRects(_rubberBandRect, NSZeroRect) && nil != pointURL && _isMouseDown) {
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
                [self dragImage:nil at:p offset:NSZeroSize event:event pasteboard:pboard source:self slideBack:YES];
            }
        }
        else {
            [super mouseDragged:event];
        }
        
    }
    else if (_isMouseDown) {   
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
    FVDropOperation op;
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
        
        // can't insert between nonexisting cells either, so check numberOfIcons first...

        if ([self _getGridRow:&r column:&c atPoint:left] && ([self _indexForGridRow:r column:c] < [_controller numberOfIcons])) {
            
            aRect = [self _rectOfIconInRow:r column:c];
            // rect size is 6, and should be centered between icons horizontally
            aRect.origin.x += _iconSize.width + _padding.width / 2 - 3.0;
            aRect.size.width = 6.0;    
            op = FVDropInsert;
            insertIndex = [self _indexForGridRow:r column:c] + 1;
        }
        else if ([self _getGridRow:&r column:&c atPoint:right] && ([self _indexForGridRow:r column:c] < [_controller numberOfIcons])) {
            
            aRect = [self _rectOfIconInRow:r column:c];
            aRect.origin.x -= _padding.width / 2 + 3.0;
            aRect.size.width = 6.0;
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

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    NSPoint dragLoc = [sender draggingLocation];
    dragLoc = [self convertPoint:dragLoc fromView:nil];
    NSDragOperation dragOp = NSDragOperationNone;
    
    NSUInteger insertIndex, firstIndex, endIndex;
    // this will set a default highlight based on geometry, but does no validation
    FVDropOperation dropOp = [self _dropOperationAtPointInView:dragLoc highlightRect:&_dropRectForHighlight insertionIndex:&insertIndex];
    
    // We have to make sure the pasteboard really has a URL here, since most NSStrings aren't valid URLs
    if (FVPasteboardHasURL([sender draggingPasteboard]) == NO) {
        
        dragOp = NSDragOperationNone;
        _dropRectForHighlight = NSZeroRect;
    }
    else if (FVDropOnIcon == dropOp) {
        
        if ([self _isLocalDraggingInfo:sender]) {
                
            dragOp = NSDragOperationNone;
            _dropRectForHighlight = NSZeroRect;
        } 
        else {
            dragOp = NSDragOperationLink;
        }
    } 
    else if (FVDropOnView == dropOp) {
        
        // drop on the whole view (add operation) makes no sense for a local drag
        if ([self _isLocalDraggingInfo:sender]) {
            
            dragOp = NSDragOperationNone;
            _dropRectForHighlight = NSZeroRect;
        } 
        else {
            dragOp = NSDragOperationLink;
        }
    } 
    else if (FVDropInsert == dropOp) {
        
        // inserting inside the block we're dragging doesn't make sense; this does allow dropping a disjoint selection at some locations within the selection
        if ([self _isLocalDraggingInfo:sender]) {
            firstIndex = [_selectedIndexes firstIndex], endIndex = [_selectedIndexes lastIndex] + 1;
            if ([_selectedIndexes containsIndexesInRange:NSMakeRange(firstIndex, endIndex - firstIndex)] &&
                insertIndex >= firstIndex && insertIndex <= endIndex) {
                dragOp = NSDragOperationNone;
                _dropRectForHighlight = NSZeroRect;
            } 
            else {
                dragOp = NSDragOperationMove;
            }
        } 
        else {
            dragOp = NSDragOperationLink;
        }
    }
    
    [self setNeedsDisplay:YES];
    return dragOp;
}

// this is called as soon as the mouse is moved to start a drag, or enters the window from outside
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    if ([self _isLocalDraggingInfo:sender] || FVPasteboardHasURL([sender draggingPasteboard]))
        return NSDragOperationLink;
    else
        return NSDragOperationNone;
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
    _dropRectForHighlight = NSZeroRect;
    [self setNeedsDisplay:YES];
}

// only invoked if performDragOperation returned YES
- (void)concludeDragOperation:(id <NSDraggingInfo>)sender;
{
    _dropRectForHighlight = NSZeroRect;
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
    FVDropOperation dropOp = [self _dropOperationAtPointInView:dragLoc highlightRect:NULL insertionIndex:&insertIndex];

    // see if we're targeting a particular cell, then make sure that cell is a legal replace operation
    [self _getGridRow:&r column:&c atPoint:dragLoc];
    if (FVDropOnIcon == dropOp && (idx = [self _indexForGridRow:r column:c]) < [_controller numberOfIcons]) {
        
        NSURL *aURL = [FVURLSFromPasteboard(pboard) lastObject];
        
        // only drop a single file on a given cell!
        
        if (nil == aURL && [[pboard types] containsObject:NSFilenamesPboardType]) {
            aURL = [NSURL fileURLWithPath:[[pboard propertyListForType:NSFilenamesPboardType] lastObject]];
        }
        if (aURL)
            didPerform = [[self dataSource] fileView:self replaceURLsAtIndexes:[NSIndexSet indexSetWithIndex:idx] withURLs:[NSArray arrayWithObject:aURL]];
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
                didPerform = [[self dataSource] fileView:self moveURLsAtIndexes:[self selectionIndexes] toIndex:insertIndex];
            }
        } else {
            NSIndexSet *insertSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertIndex, [allURLs count])];
            [[self dataSource] fileView:self insertURLs:allURLs atIndexes:insertSet];
            didPerform = YES;
        }
    }
    else if ([self _isLocalDraggingInfo:sender] == NO) {
           
        // this must be an add operation, and only non-local drag sources can do that
        NSArray *allURLs = FVURLSFromPasteboard(pboard);
        NSIndexSet *insertSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange([_controller numberOfIcons], [allURLs count])];
        [[self dataSource] fileView:self insertURLs:allURLs atIndexes:insertSet];
        didPerform = YES;

    }
    // reload is handled in concludeDragOperation:
    return didPerform;
}

#pragma mark User interaction

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
    [self selectNextIcon:self];
}

- (void)insertBacktab:(id)sender;
{
    [self selectPreviousIcon:self];
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
- (void)scrollRectToVisible:(NSRect)aRect
{
    NSRect visibleRect = [self visibleRect];

    if (NSContainsRect(visibleRect, aRect) == NO) {
        
        CGFloat heightDifference = NSHeight(visibleRect) - NSHeight(aRect);
        if (heightDifference > 0) {
            // scroll to a rect equal in height to the visible rect but centered on the selected rect
            aRect = NSInsetRect(aRect, 0.0, -(heightDifference / 2.0));
        } else {
            // force the top of the selectionRect to the top of the view
            aRect.size.height = NSHeight(visibleRect);
        }
        [super scrollRectToVisible:aRect];
    }
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
    [[NSWorkspace sharedWorkspace] selectFile:[[[self _selectedURLs] lastObject] path] inFileViewerRootedAtPath:nil];
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
    FVPreviewer *previewer = [FVPreviewer sharedPreviewer];
    if ([previewer isPreviewing]) {
        [previewer stopPreviewing];
    }
    else if ([_selectedIndexes count] == 1) {
        [[FVPreviewer sharedPreviewer] setWebViewContextMenuDelegate:[self delegate]];
        NSUInteger r, c;
        [self _getGridRow:&r column:&c ofIndex:[_selectedIndexes lastIndex]];
        NSRect iconRect = [self _rectOfIconInRow:r column:c];
        iconRect = [self convertRect:iconRect toView:nil];
        NSPoint origin = [[self window] convertBaseToScreen:iconRect.origin];
        iconRect.origin = origin;
        [previewer previewURL:[[self _selectedURLs] lastObject] forIconInRect:iconRect];
    }
    else {
        [previewer setWebViewContextMenuDelegate:nil];
        [previewer previewFileURLs:[self _selectedURLs]];
    }
}

- (IBAction)delete:(id)sender;
{
    if (NO == [self isEditable] || NO == [[self dataSource] fileView:self deleteURLsAtIndexes:_selectedIndexes])
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

- (void)reloadSelectedIcons:(id)sender;
{
    NSEnumerator *iconEnum = [[_controller iconsAtIndexes:[self selectionIndexes]] objectEnumerator];
    FVIcon *anIcon;
    while ((anIcon = [iconEnum nextObject]) != nil)
        [anIcon recache];
    [self setNeedsDisplay:YES];
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
    else if (action == @selector(delete:) || action == @selector(copy:) || action == @selector(cut:))
        return [self isEditable] && selectionCount > 0;
    else if (action == @selector(selectAll:))
        return ([_controller numberOfIcons] > 0);
    else if (action == @selector(previewAction:))
        return selectionCount > 0;
    else if (action == @selector(paste:))
        return [self isEditable];
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
    NSMenu *menu = [[[[self class] defaultMenu] copyWithZone:[NSMenu menuZone]] autorelease];
    
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
    FVAPIAssert1(label >=0 && label <= 7, @"invalid label %d (must be between 0 and 7)", label);
    
    NSArray *selectedURLs = [self _selectedURLs];
    NSUInteger i, iMax = [selectedURLs count];
    for (i = 0; i < iMax; i++) {
        [FVFinderLabel setFinderLabel:label forURL:[selectedURLs objectAtIndex:i]];
    }
    [self setNeedsDisplay:YES];
    
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
    static NSMenu *sharedMenu = nil;
    if (nil == sharedMenu) {
        NSMenuItem *anItem;
        
        sharedMenu = [[NSMenu allocWithZone:[NSMenu menuZone]] initWithTitle:@""];
        NSBundle *bundle = [NSBundle bundleForClass:[FileView class]];
        
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Quick Look", @"FileView", bundle, @"context menu title") action:@selector(previewAction:) keyEquivalent:@""];
        [anItem setTag:FVQuickLookMenuItemTag];
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Open", @"FileView", bundle, @"context menu title") action:@selector(openSelectedURLs:) keyEquivalent:@""];
        [anItem setTag:FVOpenMenuItemTag];
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Reveal in Finder", @"FileView", bundle, @"context menu title") action:@selector(revealInFinder:) keyEquivalent:@""];
        [anItem setTag:FVRevealMenuItemTag];
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Reload", @"FileView", bundle, @"context menu title") action:@selector(reloadSelectedIcons:) keyEquivalent:@""];
        [anItem setTag:FVReloadMenuItemTag];        
        
        [sharedMenu addItem:[NSMenuItem separatorItem]];
        
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Remove", @"FileView", bundle, @"context menu title") action:@selector(delete:) keyEquivalent:@""];
        [anItem setTag:FVRemoveMenuItemTag];
        
        // Finder labels: submenu on 10.4, NSView on 10.5
        if ([anItem respondsToSelector:@selector(setView:)])
            [sharedMenu addItem:[NSMenuItem separatorItem]];
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Set Finder Label", @"FileView", bundle, @"context menu title") action:NULL keyEquivalent:@""];
        [anItem setTag:FVChangeLabelMenuItemTag];
        
        if ([anItem respondsToSelector:@selector(setView:)]) {
            FVColorMenuView *view = [FVColorMenuView menuView];
            [view setTarget:nil];
            [view setAction:@selector(changeFinderLabel:)];
            [anItem setView:view];
        }
        else {
            NSMenu *submenu = [[NSMenu allocWithZone:[sharedMenu zone]] initWithTitle:@""];
            [anItem setSubmenu:submenu];
            [submenu release];
            addFinderLabelsToSubmenu(submenu);
        }
        
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Download and Replace", @"FileView", bundle, @"context menu title") action:@selector(downloadSelectedLink:) keyEquivalent:@""];
        [anItem setTag:FVDownloadMenuItemTag];
        
        [sharedMenu addItem:[NSMenuItem separatorItem]];
        
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Zoom In", @"FileView", bundle, @"context menu title") action:@selector(zoomIn:) keyEquivalent:@""];
        [anItem setTag:FVZoomInMenuItemTag];
        anItem = [sharedMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Zoom Out", @"FileView", bundle, @"context menu title") action:@selector(zoomOut:) keyEquivalent:@""];
        [anItem setTag:FVZoomOutMenuItemTag];

    }
    return sharedMenu;
}

#pragma mark Download support

- (void)downloadSelectedLink:(id)sender
{
    // validation ensures that we have a single selection, and that there is no current download with this URL
    NSUInteger selIndex = [_selectedIndexes firstIndex];
    if (NSNotFound != selIndex)
        [_controller downloadURLAtIndex:selIndex];
}

@end

@implementation FVColumnView

- (NSArray *)exposedBindings;
{
    NSMutableArray *bindings = [NSMutableArray array];
    [bindings addObjectsFromArray:[super exposedBindings]];
    [bindings removeObject:@"iconScale"];
    return bindings;
}

- (BOOL)_showsSlider { return NO; }

- (NSUInteger)numberOfColumns { return 1; }

// remove icon size/padding interdependencies
- (CGFloat)_leftMargin { return DEFAULT_PADDING / 2; }
- (CGFloat)_rightMargin { return DEFAULT_PADDING / 2; }

- (NSSize)_defaultPaddingForScale:(CGFloat)unused
{    
    NSSize size = NSZeroSize;
    size.height = _titleHeight + 4.0;
    if ([_dataSource respondsToSelector:@selector(fileView:subtitleAtIndex:)])
        size.height += _subtitleHeight;
    return size;
}

// horizontal padding is always zero, so we extend horizontally by the margin width
- (void)_setNeedsDisplayForIconInRow:(NSUInteger)row column:(NSUInteger)column {
    NSRect iconRect = [self _rectOfIconInRow:row column:column];
    // extend horizontally to account for shadow in case text is narrower than the icon
    // extend upward by 1 unit to account for slight mismatch between icon/placeholder drawing
    // extend downward to account for the text area
#if __LP64__
    CGFloat horizontalExpansion = floor(MAX([self _leftMargin], [self _rightMargin]));
#else
    CGFloat horizontalExpansion = floorf(MAX([self _leftMargin], [self _rightMargin]));
#endif
    NSRect dirtyRect = NSUnionRect(NSInsetRect(iconRect, -horizontalExpansion, -1.0), [self _rectOfTextForIconRect:iconRect]);
    [self setNeedsDisplayInRect:dirtyRect];
}

- (void)_recalculateGridSize
{
    NSClipView *cv = [[self enclosingScrollView] contentView];
    NSRect minFrame = cv ? [cv bounds] : [self frame];
    NSRect frame = NSZeroRect;
    
    _padding = [self _defaultPaddingForScale:0];
    CGFloat length = NSWidth(minFrame) - _padding.width - [self _leftMargin] - [self _rightMargin];    
    _iconSize = NSMakeSize(length, length);
    
    frame.size.width = NSWidth(minFrame);
    frame.size.height = MAX([self _rowHeight] * [self numberOfRows] + [self _topMargin] + [self _bottomMargin], NSHeight(minFrame));
    
    if (NSEqualRects(frame, [self frame]) == NO)
        [self setFrame:frame];       
} 

- (void)setIconScale:(CGFloat)scale;
{
    FVAPIAssert(0, @"attempt to call setIconScale: on a view that automatically scales");
}

- (CGFloat)iconScale;
{
    return _iconSize.width / DEFAULT_ICON_SIZE.width;
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
        _keyPath = [keyPath copy];
        _options = [options copy];
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
