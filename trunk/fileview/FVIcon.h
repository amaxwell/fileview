//
//  FVIcon.h
//  FileViewTest
//
//  Created by Adam Maxwell on 08/31/07.
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

@interface FVIcon : NSObject

/*
 Note: the +iconWith... class methods are designed to be cheap, in that they do no rendering, and will require very little memory or disk access just for initialization.  Only after calling -renderOffscreen will memory usage increase substantially, as data is cached and bitmaps created.  Icons that won't be displayed for some time (scrolled out of sight) should be sent a -releaseResources message by the view in order to free up (some) of the cached data.
 
 This class is thread safe, at least within reason.
 */

// Returns a URL that is appropriate for a missing file.  Don't rely on the scheme or path for anything.
+ (NSURL *)missingFileURL;

// Will accept any URL type and return a file thumbnail, file icon, or appropriate icon for the given URL scheme.
+ (id)iconWithURL:(NSURL *)representedURL;

// Possibly releases cached resources for icons that won't be displayed.  The only way to guarantee a decrease in memory usage is to release all references to the object, though, as this call may be a noop for some subclasses.
- (void)releaseResources;
- (BOOL)canReleaseResources;

// Returns NO if the icon already has a cached version for this size; if it returns YES, this method sets the desired size in the case of Finder icons, and the caller should then send -renderOffscreen from the render thread.
- (BOOL)needsRenderForSize:(NSSize)size;

// Renders the icon into an offscreen bitmap context; should be called from a dedicated rendering thread after needsRenderForSize: has been called.  This call may be expensive, but it's required for correct drawing.
- (void)renderOffscreen;

/*
 - the image will be scaled proportionally and centered in the destination rect
 - the view is responsible for using -centerScanRect: as appropriate, but images may not end up on pixel boundaries
 - any changes to the CGContextRef are wrapped by CGContextSaveGState/CGContextRestoreGState
 - specific compositing operations should be set in the context before calling this method
 - shadow will be respected (the clip path is only changed when rendering text)
 - needsRenderForSize: and renderOffscreen must be called first, to check/set size
 - don't bother calling -renderOffscreen if -needsRenderForSize: returns NO
 - a placeholder icon will be drawn if -renderOffscreen has not been called or finished working
 */
- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;

// fastDrawInRect: draws a lower quality version if available, using the same semantics as drawInRect:ofContext:
- (void)fastDrawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;

// get rid of any cached representations; next time the icon is redrawn, its data will be reloaded
- (void)recache;

@end

@interface FVIcon (Pages)

// The -currentPageIndex return value is 1-based, as in CGPDFDocumentGetPageCount; only useful for multi-page formats such as PDF and PS.  Multi-page TIFFs and text documents are not supported, and calling the showNextPage/showPreviousPage methods will have no effect.
- (NSUInteger)pageCount;
- (NSUInteger)currentPageIndex;
- (void)showNextPage;
- (void)showPreviousPage;

@end
