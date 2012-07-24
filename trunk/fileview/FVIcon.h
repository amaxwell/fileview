//
//  FVIcon.h
//  FileViewTest
//
//  Created by Adam Maxwell on 08/31/07.
/*
 This software is Copyright (c) 2007-2012
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
#import "FVObject.h"

/** Abstract class used for drawing in FileView
 
 FVIcon is a class cluster.  You should typically never receive an instance of FVIcon from its initializer, but will instead get an instance of a concrete subclass that correctly handles a given URL scheme or file type.

 The iconWithURL: factory method is designed to be cheap, in that it does no rendering, should will require very little memory or disk access just for initialization.  Only after calling renderOffscreen will memory usage increase substantially, as data is cached and bitmaps created.  Icons that won't be displayed for some time (scrolled out of sight) should be sent a releaseResources message by the view in order to free up (some) of the cached data.  Subsequent calls to renderOffscreen should be substantially less expensive, since data will be read from the disk cache.
 
 This class is thread safe, but it is not reentrant.  You can abuse it to create deadlocks.  Don't do that. */
@interface FVIcon : FVObject

/** Shared instance representing a missing file.
 
 @return A URL that is appropriate for a missing file to be passed to iconWithURL:.  Don't rely on the scheme or path for anything. */
+ (NSURL *)missingFileURL;

/** Override default behavior or add a custom icon.
 
 If no Finder icon or Quick Look importer provides a useful icon, this is more convenient than doing a full-blown subclass and adding it to the class cluster.  It will burn some memory, so should not be used for many different file types.  A Quick Look generator is a better solution, but may not be possible in all cases. */
+ (void)useImage:(NSImage *)image forUTI:(NSString *)type;

/** Only public factory method.
 
 Decides which concrete subclass to return based on the scheme and/or UTI of the URL or its target.
 @param representedURL Any URL type
 @return A file thumbnail, file icon, or appropriate icon for the given URL scheme. */
+ (id)iconWithURL:(NSURL *)representedURL;

/** Initializer.
 In subclasses, do not call -[super initWithURL:] ([super init] is superclass initializer).
 @param aURL Any NSURL instance. */
- (id)initWithURL:(NSURL *)aURL;

/** Releases cached resources.
 
 Send this to icons that won't be displayed "soon."  The only way to guarantee a decrease in memory usage is to release all references to the object, though, as this call may be a noop for some subclasses. */
- (void)releaseResources;

/** Determine if releaseResources is possible.
 
 @return NO if releaseResources will be a no-op or otherwise is not possible. */
- (BOOL)canReleaseResources;

/** Determine if renderOffscreen is required.
 
 Clients (i.e. FileView) calls this in order to see if renderOffscreen should be called.  If it returns YES, this method sets the desired size in the case of Finder icons, and the caller should then send renderOffscreen.  By the same token, if this returns NO, don't waste time on renderOffscreen.
 
 @param size The desired icon size in points.  Subclasses are free to ignore this.
 @return NO if the icon already has a cached version for this size. */
- (BOOL)needsRenderForSize:(NSSize)size;

/** Primitive method.
 
 Draws the icon into an offscreen bitmap context.  Subclasses must override this.
 
 This is typically the most expensive call for an FVIcon subclass.  In general it should be called from a dedicated thread after needsRenderForSize: has been called, unless you're planning to draw synchronously.  This is required for correct drawing, since a placeholder will typically be drawn if the bitmap is not available. */
- (void)renderOffscreen;

/** Primitive drawing method.
 
 Subclasses must override this.  The drawing has the following semantic requirements and guarantees at present:
 
 \li the image will be scaled proportionally and centered in the destination rect
 \li the view is responsible for using -[NSView centerScanRect:] as appropriate, but images may not end up on pixel boundaries
 \li any changes to the CGContextRef are wrapped by CGContextSaveGState/CGContextRestoreGState
 \li specific compositing operations should be set in the context before calling this method
 \li shadow will be respected (the clip path is only changed when rendering text)
 \li needsRenderForSize: and renderOffscreen must be called first, to check/set size
 \li a placeholder icon will be drawn if renderOffscreen has not been called or finished working
 
 @param dstRect Destination rect for drawing in the passed-in context's coordinate space.
 @param context CGContext for drawing content. */
- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;

/** Optional drawing method.
 
 Draws a lower quality version if available, using the same semantics as FVIcon::drawInRect:ofContext:.
 @param dstRect Destination rect for drawing in the passed-in context's coordinate space.
 @param context CGContext for drawing content. */ 
- (void)fastDrawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;

/** Purge bitmap caches.
 
 Optional override.  Get rid of any cached representations; next time the icon is redrawn, its data will be recreated in renderOffscreen. */
- (void)recache;

@end

@interface FVIcon (Pages)

/** Number of pages if multipage drawing is supported.
 
 Only useful for multi-page formats such as PDF and PS.  Multi-page TIFFs and text documents are not supported, and calling the showNextPage/showPreviousPage methods will have no effect. 
 @return Number of pages available for drawing. */
- (NSUInteger)pageCount;
/** The index of the current page.
 
 @return The return value is 1-based, as in CGPDFDocumentGetPageCount. */
- (NSUInteger)currentPageIndex;

/** Increments the internal page index.
 
 This does not redisplay the icon; needsRenderForSize: and renderOffscreen must be called to redraw. */
- (void)showNextPage;

/** Decrements the internal page index.
 
 This does not redisplay the icon; needsRenderForSize: and renderOffscreen must be called to redraw. */
- (void)showPreviousPage;

@end
