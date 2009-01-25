//
//  FVArrowButtonCell.h
//  FileViewTest
//
//  Created by Adam Maxwell on 09/21/07.
/*
 This software is Copyright (c) 2007-2009
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

/** @file FVArrowButtonCell.h  Arrow button for page changes. */

enum { 
    FVArrowRight = 0, 
    FVArrowLeft  = 1
};
typedef NSUInteger FVArrowDirection;

/** @internal @brief Circular arrow button.
 
 FVArrowButtonCell is a circle with an arrow inside, used as a page change button.  Modeled after the page change button that Finder shows for PDF files on 10.5 in column mode preview.  */
@interface FVArrowButtonCell : NSButtonCell {
    FVArrowDirection _arrowDirection;
}

/** Designated initializer.
 
 @param anArrowDirection Whether the arrow points left or right.
 @return An initialized cell. */
- (id)initWithArrowDirection:(FVArrowDirection)anArrowDirection;
@end

/** @typedef NSUInteger FVArrowDirection 
 FVArrowButtonCell direction.
 */

/** @var FVArrowRight 
 Right-pointing arrow.
 */
/** @var FVArrowLeft 
 Left-pointing arrow.
 */

