/*
 *  FVIcon_Private.h
 *  FileView
 *
 *  Created by Adam Maxwell on 10/21/07.
 *
 */
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
#import "FVIcon.h"

// subclasses use various functions from these headers
#import "FVBitmapContextCache.h"
#import "FVIconCache.h"
#import <pthread.h>
#import <libkern/OSAtomic.h>
#import "FVCGImageUtilities.h"
#import "FVUtilities.h"

@interface FVIcon (Private) <NSLocking>

// called from +initialize
+ (void)_initializeCategory;

// Call for classes that should avoid multiple render requests for the same icon; useful for multiple views, since the operation queue only ensures uniqueness of rendering requests per-view.  Requires synchronous caching to be effective, and must be called as [[self class] _startRenderingForKey:aKey] rather than [FVIcon _startRenderingForKey:aKey] in order to achieve proper granularity.  Each start must be matched by a stop, or bad things will happen.
+ (void)_startRenderingForKey:(id)aKey;
+ (void)_stopRenderingForKey:(id)aKey;

// returns YES if the file at aURL needs a badge, and always returns a copy of the correct target URL by reference (which makes it a simple initializer for most subclasses, which retain the URL anyway)
+ (BOOL)_shouldDrawBadgeForURL:(NSURL *)aURL copyTargetURL:(NSURL **)linkTarget;

// override in subclasses; do not call -[super initWithURL:] ([super init] is superclass initializer)
- (id)initWithURL:(NSURL *)aURL;

// size should only be used for computing an aspect ratio; don't rely on it as a pixel size
- (NSSize)size;

- (CGRect)_drawingRectWithRect:(NSRect)iconRect;
- (void)_drawPlaceholderInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
- (void)_badgeIconInRect:(NSRect)dstRect ofContext:(CGContextRef)context;

// add to NSLocking; NSLocking is private to FVIcon instances themselves
- (BOOL)tryLock;

@end

// Desired size: should be the same size passed to -[FVIcon needsRenderForSize:] and -[FVIcon _drawingRectWithRect:], not the return value of _drawingRectWithRect:.  Thumbnail size: current size of the instance's thumbnail image, if it has one (and if not, it shouldn't be calling this).
static inline bool FVShouldDrawFullImageWithThumbnailSize(const NSSize desiredSize, const NSSize thumbnailSize)
{
    return (desiredSize.height > 1.2 * thumbnailSize.height || desiredSize.width > 1.2 * thumbnailSize.width);
}

// best not to use these at all, but FVMaxThumbnailDimension is exported for the QL icon bundle
extern const size_t FVMaxThumbnailDimension;
FV_PRIVATE_EXTERN const size_t FVMaxImageDimension;

FV_PRIVATE_EXTERN const NSSize FVDefaultPaperSize;
FV_PRIVATE_EXTERN const CGFloat FVTopMargin;
FV_PRIVATE_EXTERN const CGFloat FVSideMargin;

// Returns true if the size pointer was modified; these are used by the resampling functions below.
FV_PRIVATE_EXTERN bool FVIconLimitFullImageSize(NSSize *size);
FV_PRIVATE_EXTERN bool FVIconLimitThumbnailSize(NSSize *size);

// Create images using the predefined sizes for FVIcon.  Both functions will simply retain the argument and return it if possible.
FV_PRIVATE_EXTERN CGImageRef FVCreateResampledThumbnail(CGImageRef image);
FV_PRIVATE_EXTERN CGImageRef FVCreateResampledFullImage(CGImageRef image);
