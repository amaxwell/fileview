//
//  FVColorMenuView.h
//  colormenu
//
//  Created by Adam Maxwell on 02/20/08.
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

@class FVColorMenuMatrix;

@interface FVColorMenuView : NSControl
{
    IBOutlet FVColorMenuMatrix *_matrix;
    IBOutlet NSTextField       *_labelField;
    IBOutlet NSTextField       *_labelNameField;
    SEL                         _action;
    id                          _target;
}

// returns a new instance of the view
+ (FVColorMenuView *)menuView;

// select a given Finder label
- (void)selectLabel:(NSUInteger)label;

// implements -tag to return the selected Finder label

- (id)target;
- (void)setTarget:(id)target;

- (SEL)action;
- (void)setAction:(SEL)action;

@end

@interface FVColorMenuCell : NSButtonCell
@end

@interface FVColorMenuMatrix : NSMatrix
{
    NSInteger _boxedRow;
    NSInteger _boxedColumn;
}
- (NSString *)boxedLabelName;

@end
