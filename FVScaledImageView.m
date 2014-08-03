//
//  FVScaledImageView.m
//  FileView
//
//  Created by Adam Maxwell on 09/22/07.
/*
 This software is Copyright (c) 2007-2013
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

#import "FVScaledImageView.h"
#import "FVIcon.h"

@implementation FVScaledImageView

- (void)makeText
{
    NSMutableDictionary *ta = [NSMutableDictionary dictionary];
    [ta setObject:[NSFont systemFontOfSize:[NSFont systemFontSize]] forKey:NSFontAttributeName];
    [ta setObject:[NSColor darkGrayColor] forKey:NSForegroundColorAttributeName];
    NSMutableParagraphStyle *ps = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    [ps setAlignment:NSCenterTextAlignment];
    [ta setObject:ps forKey:NSParagraphStyleAttributeName];
    [ps release];
    
    NSMutableAttributedString *fileDescription = [[NSMutableAttributedString alloc] initWithString:[[NSFileManager defaultManager] displayNameAtPath:[_fileURL path]]];
    [fileDescription addAttributes:ta range:NSMakeRange(0, [fileDescription length])];
    [fileDescription addAttribute:NSFontAttributeName value:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]] range:NSMakeRange(0, [fileDescription length])];
    
    MDItemRef mdItem = MDItemCreate(NULL, (CFStringRef)[_fileURL path]);
    NSDictionary *mdAttributes = nil;
    if (NULL != mdItem) {
        mdAttributes = [(id)MDItemCopyAttributeList(mdItem, kMDItemKind, kMDItemPixelHeight, kMDItemPixelWidth) autorelease];
        CFRelease(mdItem);
    }
    
    NSBundle *bundle = [NSBundle bundleForClass:[FVScaledImageView class]];
    
    if (nil != mdAttributes) {
        NSMutableAttributedString *kindString = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n\n%@", [mdAttributes objectForKey:(id)kMDItemKind]] attributes:ta];
        if ([mdAttributes objectForKey:(id)kMDItemPixelHeight] && [mdAttributes objectForKey:(id)kMDItemPixelWidth])
            [[kindString mutableString] appendFormat:NSLocalizedStringFromTableInBundle(@"\n%@ by %@ pixels", @"FileView", bundle, @"two string format specifiers"), [mdAttributes objectForKey:(id)kMDItemPixelWidth], [mdAttributes objectForKey:(id)kMDItemPixelHeight]];
        [fileDescription appendAttributedString:kindString];
        [kindString release];
    }
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
    NSDictionary *fattrs = [[NSFileManager defaultManager] attributesOfItemAtPath:[_fileURL path] error:NULL];
#else
    NSDictionary *fattrs = [[NSFileManager defaultManager] fileAttributesAtPath:[_fileURL path] traverseLink:NO];
#endif
    if (fattrs) {
        NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
        [formatter setFormatterBehavior:NSDateFormatterBehavior10_4];
        [formatter setDateStyle:NSDateFormatterLongStyle];
        [formatter setTimeStyle:NSDateFormatterMediumStyle];
        
        unsigned long long fsize = [[fattrs objectForKey:NSFileSize] longLongValue];
        CGFloat mbsize = fsize / 1024.0f;
        NSString *label = @"KB";
        if (mbsize > 1024.0f) {
            mbsize /= 1024.0f;
            label = @"MB";
        }
        if (mbsize > 1024.0f) {
            mbsize /= 1024.0f;
            label = @"GB";
        }
        NSMutableAttributedString *details = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"\n\nSize: %.1f %@\nCreated: %@\nModified: %@", @"FileView", bundle, @"message displayed in preview"), mbsize, label, [formatter stringFromDate:[fattrs objectForKey:NSFileCreationDate]], [formatter stringFromDate:[fattrs objectForKey:NSFileModificationDate]]] attributes:ta];
        [details addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]] range:NSMakeRange(0, [details length])];
        [fileDescription appendAttributedString:details];
        [details release];
    }
    [_text autorelease];
    _text = fileDescription;
}

- (void)dealloc
{
    [_icon release];
    [_text release];
    [super dealloc];
}

- (void)setIcon:(FVIcon *)anIcon
{
    [_icon autorelease];
    _icon = [anIcon retain];
}

- (void)setFileURL:(NSURL *)aURL
{
    [_fileURL autorelease];
    _fileURL = [aURL copy];
}

- (void)displayIconForURL:(NSURL *)aURL
{
    [self setFileURL:aURL];
    [self setIcon:[FVIcon iconWithURL:aURL]];
    [self makeText];
}

- (void)displayImageAtURL:(NSURL *)aURL;
{
    [self setFileURL:aURL];
    [self setIcon:[FVIcon iconWithURL:aURL]];
    [_text autorelease];
    _text = nil;
}

- (void)viewDidEndLiveResize;
{
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)aRect
{
    [super drawRect:aRect];
    
    CGContextRef ctxt = [[NSGraphicsContext currentContext] graphicsPort];
    if ([_icon needsRenderForSize:aRect.size])
        [_icon renderOffscreen];
    
    aRect = NSInsetRect([self bounds], 25, 25);
    NSRect iconRect = aRect;
    
    // originally was drawing text for all types, but QL just displays the image
    if (nil != _text) {
        NSRect textRect;
        NSDivideRect(aRect, &iconRect, &textRect, NSWidth(aRect) / 2, NSMinXEdge);
        
        // draw text before messing with the graphics state
        NSRect boundRect = [_text boundingRectWithSize:textRect.size options:NSStringDrawingUsesLineFragmentOrigin];
        if (NSWidth(boundRect) < NSWidth(textRect)) {
            CGFloat delta = NSWidth(textRect) - NSWidth(boundRect);
            textRect.origin.x += delta;
            textRect.size.width -= delta;
            iconRect.size.width += delta;
        }
        textRect.origin.y = textRect.origin.y - (NSHeight(textRect) - NSHeight(boundRect)) / 2;
        [_text drawWithRect:textRect options:NSStringDrawingUsesLineFragmentOrigin];
    }
    
    // always antialias the text
    if ([self inLiveResize]) {
        CGContextSetShouldAntialias(ctxt, false);
        CGContextSetInterpolationQuality(ctxt, kCGInterpolationNone);
    }
    else {
        CGContextSetShouldAntialias(ctxt, true);
        CGContextSetInterpolationQuality(ctxt, kCGInterpolationHigh);
    }     
    [_icon drawInRect:NSInsetRect(iconRect, 5.0f, 5.0f) ofContext:ctxt];
    
}

@end
