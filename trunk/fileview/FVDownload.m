//
//  FVDownload.m
//  FileView
//
//  Created by Adam Maxwell on 2/15/08.
/*
 This software is Copyright (c) 2008-2010
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

#import "FVDownload.h"
#import "FVProgressIndicatorCell.h"
#import <WebKit/WebKit.h>

/*
 FVDownload associates a URL/index combination, and stores the download destination (temp directory) for a given download, along with some other data (download progress, progress indicator rotation angle for indeterminate indicators).
 
 FVDownload can be used in a hashing collection.
 */

@implementation FVDownload

- (id)initWithDownloadURL:(NSURL *)aURL indexInView:(NSUInteger)indexInView;
{
    NSParameterAssert(nil != aURL);
    NSParameterAssert(NSNotFound != indexInView);
    self = [super init];
    if (self) {
        _downloadURL = [aURL copyWithZone:[self zone]];
        _indexInView = indexInView;
        _fileURL = nil;
        _expectedLength = 0;
        _receivedLength = 0;
        _progressIndicator = [[FVProgressIndicatorCell alloc] init];
    }
    return self;
}

- (CGFloat)currentProgress;
{
    // drawing doesn't like negative/nan/inf values!
    if (0 == _expectedLength)
        return 0;
    
    // some illusion of progress?
    if (NSURLResponseUnknownLength == _expectedLength)
        return NSURLResponseUnknownLength;
    
    CGFloat a = _receivedLength;
    CGFloat b = _expectedLength;
    return a / b;
}

- (void)dealloc
{
    [_downloadURL release];
    [_fileURL release];
    [_progressIndicator release];
    [super dealloc];
}

- (NSUInteger)hash { return _indexInView; }
- (BOOL)isEqual:(FVDownload *)other
{ 
    return ([other isKindOfClass:[self class]] && [other->_downloadURL isEqual:_downloadURL] && other->_indexInView == _indexInView); 
}

- (NSURL *)fileURL { return _fileURL; }
- (void)setFileURL:(NSURL *)fileURL
{
    NSAssert1(nil == _fileURL, @"Error: attempt to set _fileURL when it is already set to %@", _fileURL);
    NSParameterAssert([fileURL isFileURL]);
    [_fileURL autorelease];
    _fileURL = [fileURL copy];
    [_download setDestination:[_fileURL path] allowOverwrite:NO];
}

- (void)setExpectedLength:(long long)expectedLength
{ 
    _expectedLength = expectedLength; 
    if (NSURLResponseUnknownLength == expectedLength)
        [_progressIndicator setStyle:FVProgressIndicatorIndeterminate];
    else
        [_progressIndicator setStyle:FVProgressIndicatorDeterminate];
}
- (long long)expectedLength { return _expectedLength; }

- (long long)receivedLength { return _receivedLength; }
- (void)setReceivedLength:(long long)receivedLength
{ 
    _receivedLength = receivedLength; 
    [_progressIndicator setCurrentProgress:[self currentProgress]];
}

- (void)incrementReceivedLengthBy:(NSUInteger)length;
{
    _receivedLength += length;
    [_progressIndicator setCurrentProgress:[self currentProgress]];
}

- (NSURL *)downloadURL { return _downloadURL; }
- (NSUInteger)indexInView { return _indexInView; }

- (FVProgressIndicatorCell *)progressIndicator { return _progressIndicator; }

- (void)start
{
    NSAssert1(nil == _download, @"Error: already called -start on %@", self);
    _download = [[WebDownload alloc] initWithRequest:[NSURLRequest requestWithURL:_downloadURL] delegate:self];
}

- (void)cancel
{
    [_download cancel];
    [_download release];
    _download = nil;
}

- (void)download:(NSURLDownload *)download decideDestinationWithSuggestedFilename:(NSString *)filename;
{
    if ([_delegate respondsToSelector:@selector(download:setDestinationWithSuggestedFilename:)])
        [_delegate download:self setDestinationWithSuggestedFilename:filename];
}

- (void)download:(NSURLDownload *)download didReceiveResponse:(NSURLResponse *)response;
{
    long long expectedLength = [response expectedContentLength];
    [self setExpectedLength:expectedLength];
    if ([_delegate respondsToSelector:@selector(downloadUpdated:)])
        [_delegate downloadUpdated:self];
}

- (void)download:(NSURLDownload *)download didReceiveDataOfLength:(NSUInteger)length;
{
    [self incrementReceivedLengthBy:length];
    if ([_delegate respondsToSelector:@selector(downloadUpdated:)])
        [_delegate downloadUpdated:self];
}

- (void)downloadDidFinish:(NSURLDownload *)download;
{
    if ([_delegate respondsToSelector:@selector(downloadFinished:)])
        [_delegate downloadFinished:self];
}

- (void)download:(NSURLDownload *)download didFailWithError:(NSError *)error;
{
    if ([_delegate respondsToSelector:@selector(downloadFailed:)])
        [_delegate downloadFailed:self];
}

- (id)delegate { return _delegate; }

- (void)setDelegate:(id)obj { _delegate = obj; }

@end

