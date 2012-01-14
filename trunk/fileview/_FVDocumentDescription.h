//
//  _FVDocumentDescription.h
//  FileView
//
//  Created by Adam Maxwell on 07/15/08.
/*
 This software is Copyright (c) 2008-2012
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

/** @internal @brief Cached document attributes.
 
 This object enables instantation of an icon entirely from pre-cached objects, so it is no longer necessary to load the document just to figure out the size and number of pages.  This is mainly intended for use with PDF/PS documents, which can be expensive to open and parse. */
@interface _FVDocumentDescription : FVObject {
@public
    size_t   _pageCount;
    NSSize   _fullSize;
}

/** @internal @brief Get a description for a previously stored key.
 
 @param aKey A key object conforming to &lt;NSCopying&gt;
 @return A description or nil if not previously stored. */
+ (_FVDocumentDescription *)descriptionForKey:(id)aKey;

/** @internal @brief Cache a description for the given key.
 
 @param description A document description object
 @param aKey A key object conforming to &lt;NSCopying&gt;. */
+ (void)setDescription:(_FVDocumentDescription *)description forKey:(id <NSObject, NSCopying>)aKey;

@end
