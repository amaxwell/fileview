//
//  FVCoreTextIcon.m
//  FileView
//
//  Created by Adam Maxwell on 6/14/08.
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

#import "FVCoreTextIcon.h"

@implementation FVCoreTextIcon

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)

- (CGImageRef)_newImageWithAttributedString:(NSMutableAttributedString *)attrString documentAttributes:(NSDictionary *)documentAttributes
{
    CFMutableAttributedStringRef cfAttrString = (CFMutableAttributedStringRef)attrString;
    
    // set up page layout parameters
    CGRect paperRect;
    paperRect.origin = CGPointZero;
    paperRect.size = NSSizeToCGSize(FVDefaultPaperSize);
    // use a symmetric margin
    CGRect textRect;
    textRect.origin = CGPointZero;
    textRect = CGRectInset(paperRect, FVSideMargin, FVTopMargin);

    // white page background
    CGFloat backgroundComps[4] = { 1.0, 1.0, 1.0, 1.0 };
    
    FVBitmapContextRef ctxt = FVIconBitmapContextCreateWithSize(CGRectGetWidth(paperRect), CGRectGetHeight(paperRect));    
    CGContextSaveGState(ctxt);

    // use a monospaced font for plain text
    if (nil == documentAttributes || [[documentAttributes objectForKey:NSDocumentTypeDocumentAttribute] isEqualToString:NSPlainTextDocumentType]) {
        CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUserFixedPitchFontType, 0, NULL);
        CFAttributedStringSetAttribute(cfAttrString, CFRangeMake(0, [attrString length]), kCTFontAttributeName, font);
        CFRelease(font);
    }
    else if (nil != documentAttributes) {
        
        CGFloat left, right, top, bottom;
        
        left = [[documentAttributes objectForKey:NSLeftMarginDocumentAttribute] floatValue];
        right = [[documentAttributes objectForKey:NSRightMarginDocumentAttribute] floatValue];
        top = [[documentAttributes objectForKey:NSTopMarginDocumentAttribute] floatValue];
        bottom = [[documentAttributes objectForKey:NSBottomMarginDocumentAttribute] floatValue];
        NSSize paperSize = [[documentAttributes objectForKey:NSPaperSizeDocumentAttribute] sizeValue];
        textRect.size.width = paperSize.width - left - right;
        textRect.size.height = paperSize.height - top - bottom;
        textRect.origin.x = left;
        textRect.origin.y = bottom;
        
        NSColor *nsColor = [documentAttributes objectForKey:NSBackgroundColorDocumentAttribute];
        nsColor = [nsColor colorUsingColorSpaceName:NSDeviceRGBColorSpace];  
        [nsColor getRed:&backgroundComps[0] green:&backgroundComps[1] blue:&backgroundComps[2] alpha:&backgroundComps[3]];
    }
    
    if (NULL == cfAttrString) {
        // display a mildly unhelpful error message
        NSBundle *bundle = [NSBundle bundleForClass:[FVCoreTextIcon class]];
        
        NSString *err = [NSLocalizedStringFromTableInBundle(@"Unable to read text file ", @"FileView", bundle, @"error message with single trailing space") stringByAppendingString:[_fileURL path]];
        cfAttrString = (CFMutableAttributedStringRef)[[[NSMutableAttributedString alloc] initWithString:err] autorelease];
    }  
    
    CGContextSetTextMatrix(ctxt, CGAffineTransformIdentity);
    CGContextSetRGBFillColor(ctxt, backgroundComps[0], backgroundComps[1], backgroundComps[2], backgroundComps[3]);
    CGContextFillRect(ctxt, paperRect);
    
    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(cfAttrString);
    
    CGMutablePathRef framePath = CGPathCreateMutable();
    CGPathAddRect(framePath, NULL, textRect);
    CTFrameRef frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), framePath, NULL);
    CFRelease(framePath);
    CFRelease(framesetter);
    
    /*
     NSGraphicsContext is required for NSColor attributes.  See http://lists.apple.com/archives/Quartz-dev/2008/Jun/msg00043.html  Unfortunately, colored underlines apparently aren't supported by CT; CTStringAttributes.h says that the color of those attributes is taken from the foreground text color, which is kind of lame.  Strikethrough apparently isn't supported at all.
     */
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:ctxt flipped:NO]];
    
    CTFrameDraw(frame, ctxt);
    CGContextFlush(ctxt);
    CFRelease(frame);
    
    [NSGraphicsContext restoreGraphicsState];
    
    // restore the bitmap context's state (although it's gone after this operation)
    CGContextRestoreGState(ctxt);
    
    CGImageRef image = CGBitmapContextCreateImage(ctxt);
    FVIconBitmapContextRelease(ctxt);
    
    return image;
}

#else
#warning FVCoreTextIcon not used
#endif

@end


