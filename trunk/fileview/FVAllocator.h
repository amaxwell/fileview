//
//  FVAllocator.h
//  FileView
//
//  Created by Adam Maxwell on 08/01/08.
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

/** @file FVAllocator.h @brief Allocator for moderate-to-large blocks.
 
 This allocator is primarily intended for use when many blocks >16K are needed repeatedly.  Each block is retained in a cache for some time after being freed, so reuse of similarly sized blocks should be fast.  Blocks of memory returned are not zeroed; the caller is responsible for this as needed.  In fact, a primary advantage of this allocator is that it doesn't waste time zeroing memory before returning it.  Typical usage is to provide a block of memory for a CGBitmapContext, vImage_Buffer, or backing for a CGDataProvider.  In the latter case, you can use CFDataCreateWithBytesNoCopy()/CGDataProviderCreateWithCFData() to good advantage, particularly for repeated creation/destruction of short-lived/same-sized images.
 
 This is <b>not</b> a general-purpose replacement for the system allocator(s), and the code doesn't draw from tcmalloc or Apple's malloc implementation.  There's no guarantee of good scalability with this, but it's quite fast with a few hundred cached pointers, and doesn't spend time in spinlocks like Apple's malloc does.  If profiling turns up bottlenecks, there'll likely be some obvious wins; using a hash table instead of a binary search, for example.
 
 For some background on the problem, see this thread:  http://lists.apple.com/archives/perfoptimization-dev/2008/Apr/msg00018.html which indicates that waiting for a solution from Apple is probably not going to be very gratifying. 
 
 @warning If allocations are sized such that you can't reuse them, this allocator is not for you.
 
 */

/** @internal @brief Allocator for moderate-to-large blocks.
 
 The allocator is thread-safe.
 @return The shared allocator instance. */
FV_PRIVATE_EXTERN CFAllocatorRef FVAllocatorGetDefault(void);

/** @internal @brief Print allocator statistics.
 Logs various information about allocator usage, particularly the number and size of the free blocks currently available.  This should be used for debugging only.  */
FV_PRIVATE_EXTERN void FVAllocatorShowStats(void);
