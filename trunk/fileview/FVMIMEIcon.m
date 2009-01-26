//
//  FVMIMEIcon.m
//  FileView
//
//  Created by Adam Maxwell on 02/12/08.
/*
 This software is Copyright (c) 2008-2009
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

#import "FVMIMEIcon.h"
#import "FVOperationQueue.h"
#import "FVInvocationOperation.h"

@implementation FVMIMEIcon

static IconRef _networkIcon = NULL;
static NSMutableDictionary *_iconTable = nil;
static NSLock *_iconTableLock = nil;
static Class FVMIMEIconClass = Nil;
static FVMIMEIcon *defaultPlaceholderIcon = nil;

+ (void)initialize
{
    FVINITIALIZE(FVMIMEIcon);
    
    if ([FVMIMEIcon class] == self) {
        FVMIMEIconClass = self;
        GetIconRef(kOnSystemDisk, kSystemIconsCreator, kGenericNetworkIcon, &_networkIcon);
        _iconTable = [NSMutableDictionary new];
        _iconTableLock = [[NSLock alloc] init];
        defaultPlaceholderIcon = (FVMIMEIcon *)NSAllocateObject(FVMIMEIconClass, 0, [self zone]);
    }
    
}

+ (id)allocWithZone:(NSZone *)aZone
{
    return defaultPlaceholderIcon;
}

- (id)_initWithMIMEType:(NSString *)type;
{
    NSAssert2(pthread_main_np() != 0, @"*** threading violation *** +[%@ %@] requires main thread", self, NSStringFromSelector(_cmd));
    NSParameterAssert(defaultPlaceholderIcon != self);
    self = [super init];
    if (self) {
        OSStatus err;
        err = GetIconRefFromTypeInfo(0, 0, NULL, (CFStringRef)type, kIconServicesNormalUsageFlag, &_icon);
        if (err) _icon = NULL;
        // don't return nil; we'll just draw the network icon
    }
    return self;
}

- (void)dealloc
{
    FVAPIAssert1(0, @"attempt to deallocate %@", self);
    [super dealloc];
}

- (BOOL)tryLock { return NO; }
- (void)lock { /* do nothing */ }
- (void)unlock { /* do nothing */ }

- (void)renderOffscreen
{
    // no-op
}

- (NSSize)size { return (NSSize){ FVMaxThumbnailDimension, FVMaxThumbnailDimension }; }   

// We always ignore the result of +allocWithZone: since we may return a previously allocated instance.  No need to do [self release] on the placeholder.
- (id)initWithMIMEType:(NSString *)type;
{
    NSParameterAssert(nil != type);
    NSParameterAssert(defaultPlaceholderIcon == self);
    [_iconTableLock lock];
    FVMIMEIcon *icon = [_iconTable objectForKey:type];
    if (nil == icon) {
        icon = (FVMIMEIcon *)NSAllocateObject(FVMIMEIconClass, 0, [self zone]);
        FVInvocationOperation *operation = [[FVInvocationOperation alloc] initWithTarget:icon selector:@selector(_initWithMIMEType:) object:type];
        [operation setConcurrent:NO];
        // make sure this operation gets invoked first when we run the runloop
        [operation setQueuePriority:FVOperationQueuePriorityVeryHigh];
        [[FVOperationQueue mainQueue] addOperation:operation];
        [operation autorelease];
        // If this is already the main thread, running it in the default runloop mode should cause the operation to complete, but may lead to a deadlock since webview callouts can be sent multiple times due to server push or multiple views loading the same icon simultaneously (and this method is not reentrant).  The problem is that it can flush all pending operations.
        while (NO == [operation isFinished])
            CFRunLoopRunInMode((CFStringRef)FVMainQueueRunLoopMode, 0.1, YES);
        
        icon = [operation result];
        if (icon) {
            [_iconTable setObject:icon forKey:type];
            [icon release];
        }
    }
    [_iconTableLock unlock];    
    return [icon retain];
}

- (void)drawInRect:(NSRect)dstRect ofContext:(CGContextRef)context;
{
    CGRect rect = [self _drawingRectWithRect:dstRect];            
    CGContextSaveGState(context);
    // get rid of any shadow, as the image draws it
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    
    if (_icon)
        PlotIconRefInContext(context, &rect, kAlignAbsoluteCenter, kTransformNone, NULL, kIconServicesNoBadgeFlag, _icon);
    
    // slight inset and draw partially transparent
    CGRect networkRect = CGRectInset(rect, CGRectGetWidth(rect) / 7, CGRectGetHeight(rect) / 7);
    CGContextSetAlpha(context, 0.6);
    if (_networkIcon)
        PlotIconRefInContext(context, &networkRect, kAlignAbsoluteCenter, kTransformNone, NULL, kIconServicesNoBadgeFlag, _networkIcon);  
    
    CGContextRestoreGState(context);
}

@end
