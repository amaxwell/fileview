//
//  FVBitmapContextCache.h
//  FileView
//
//  Created by Adam Maxwell on 10/21/07.
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

#ifndef _FVBITMAPCONTEXT_H_
#define _FVBITMAPCONTEXT_H_

#import <Cocoa/Cocoa.h>

__BEGIN_DECLS

/** @file FVBitmapContext.h  Bitmap context creation and disposal. */

/** @typedef CGContextRef FVBitmapContextRef
 This typedef mainly exists to silence clang's retain/release heuristic warnings, which unfortunately look for CF/CG as the release function prefix.  Should file a bug with llvm, but this is easier than dealing with bugzilla. */
typedef CGContextRef FVBitmapContextRef;

/** @internal @brief Row bytes for pixel width.
 
 Computes the appropriate number of bytes per row for 64-byte alignment.  Algorithm borrowed from Apple's sample code.
 @param bytesPerSample Bytes per pixel (e.g. an 8-bits-per-channel ARGB image has 32 bits per pixel, so uses 4 bytes per pixel).
 @param pixelsWide Width of the image in pixels.
 @return Number of bytes to allocate per row. */
FV_PRIVATE_EXTERN size_t FVPaddedRowBytesForWidth(const size_t bytesPerSample, const size_t pixelsWide);

/** @internal @brief Bitmap context creation.
 
 Create a new ARGB (ppc) or BGRA (x86) bitmap context of the given size, with rows padded appropriately and Device RGB colorspace.  The context should be released using FVIconBitmapContextRelease.  The context may contain garbage, so clear it first if you're drawing transparent content.
 @param width Width in pixels.
 @param height Height in pixels. 
 @return A new CGBitmapContext or NULL if it could not be created. */
FV_PRIVATE_EXTERN FVBitmapContextRef FVIconBitmapContextCreateWithSize(size_t width, size_t height);

/** @internal @brief Bitmap context disposal.
 
 Destroys a CGBitmapContext created using FVIconBitmapContextCreateWithSize.  @warning This deallocates the bitmap data associated with the context, rather than decrementing a reference count.
 @arg ctxt The context to release. */
FV_PRIVATE_EXTERN void FVIconBitmapContextRelease(FVBitmapContextRef ctxt);

/** @internal @brief See if an image is compatible with caching assumptions.
 
 If this returns false, the image should be redrawn into a bitmap context created with FVIconBitmapContextCreateWithSize, and CGBitmapContextCreateImage() should be used to create a new CGImage that can be cached.
 @return true if the image does not need to be redrawn. 
 @todo Move this elsewhere. */
FV_PRIVATE_EXTERN bool FVImageIsIncompatible(CGImageRef image);

__END_DECLS

#endif /* _FVBITMAPCONTEXT_H_ */
