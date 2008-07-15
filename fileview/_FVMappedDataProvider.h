//
//  _FVMappedDataProvider.h
//  FileView
//
//  Created by Adam Maxwell on 7/14/08.
/*
 This software is Copyright (c) 2008
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

/** @internal @brief Memory-mapped data provider.
 
 This object is currently used by FVPDFIcon, and probably should not be used anywhere else.  It provides a way to keep PDF files open so scrolling back-and-forth at high magnification doesn't require creating a new PDF data provider.  This class may go away in future. */
@interface _FVMappedDataProvider : NSObject 

/** @internal @brief Determine if too much data is mapped */
+ (BOOL)maxSizeExceeded;

/** @internal @brief Get a mapped data provider. 
 
 Retaining this object is not required, since the internal cache keeps a valid reference to it until you call removeProviderReferenceForURL: to dispose of it. */
+ (CGDataProviderRef)dataProviderForURL:(NSURL *)aURL;

/** @internal @brief Dispose of a mapped data provider. 
 
 Decrements the provider's retain count.  Must be balanced with calls to dataProviderForURL: or the object will be released prematurely. */
+ (void)removeProviderReferenceForURL:(NSURL *)aURL;

@end
