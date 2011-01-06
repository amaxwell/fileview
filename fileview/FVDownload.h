//
//  FVDownload.h
//  FileView
//
//  Created by Adam Maxwell on 2/15/08.
/*
 This software is Copyright (c) 2008-2011
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

@class FVProgressIndicatorCell;

@interface FVDownload : NSObject
{
@private;
    NSURL                   *_downloadURL;
    NSURL                   *_fileURL;
    NSUInteger               _indexInView;
    long long                _expectedLength;
    long long                _receivedLength;
    FVProgressIndicatorCell *_progressIndicator;
    id                       _delegate;
    NSURLDownload           *_download;
}
- (id)initWithDownloadURL:(NSURL *)aURL indexInView:(NSUInteger)indexInView;

- (void)setDelegate:(id)obj;
- (id)delegate;

- (NSURL *)downloadURL;
- (NSUInteger)indexInView;

- (void)setFileURL:(NSURL *)fileURL;
- (NSURL *)fileURL;

- (void)setExpectedLength:(long long)expectedLength;
- (long long)expectedLength;

- (void)incrementReceivedLengthBy:(NSUInteger)length;
- (FVProgressIndicatorCell *)progressIndicator;

- (void)start;
- (void)cancel;

@end

@interface NSObject (FVDownloadDelegate)
- (void)downloadUpdated:(FVDownload *)download;
- (void)downloadFinished:(FVDownload *)download;
- (void)downloadFailed:(FVDownload *)download;
- (void)download:(FVDownload *)download setDestinationWithSuggestedFilename:(NSString *)filename;
@end
