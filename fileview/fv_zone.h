/*
 *  fv_zone.h
 *  FileView
 *
 *  Created by Adam Maxwell on 11/14/08.
 *
 */
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

#ifndef _FVZONE_H_
#define _FVZONE_H_

#import <malloc/malloc.h>

__BEGIN_DECLS

/** @file fv_zone.h @brief Allocator for moderate-to-large blocks.
 
 This allocator is primarily intended for use when many blocks >16K are needed repeatedly.  Each block is retained in a cache for some time after being freed, so reuse of similarly sized blocks should be fast.  Blocks of memory returned are not zeroed; the caller is responsible for this as needed.  In fact, a primary advantage of this allocator is that it doesn't waste time zeroing memory before returning it.  Typical usage is to provide a block of memory for a CGBitmapContext, vImage_Buffer, or backing for a CGDataProvider.  In the latter case, you can use CFDataCreateWithBytesNoCopy()/CGDataProviderCreateWithCFData() to good advantage, particularly for repeated creation/destruction of short-lived/same-sized images.
 
 This is <b>not</b> a general-purpose replacement for the system allocator(s), and the code doesn't draw from tcmalloc or Apple's malloc implementation.  For some background on the problem, see this thread:  http://lists.apple.com/archives/perfoptimization-dev/2008/Apr/msg00018.html which indicates that waiting for a solution from Apple is probably not going to be very gratifying. 
 
 It's also worth noting that some of Apple's performance tool frameworks, used by Instruments and MallocDebug, hardcode zone names.  Consequently, even though I've gone to the trouble of implementing the zone introspection functions here, they're unused.  If you change the zone's name to one of Apple's zone names, the introspection functions are called, but the system gets really confused.  Shark at least records allocations from this zone in a Malloc Trace, whereas allocations using vm_allocate directly are not recorded, so there's some gain.  <b>NB: his restriction is lifted in Instruments, as of 10.6.  The zone introspection callbacks are now used.</b>
 
 @warning If allocations are sized such that you can't reuse them, this allocator is not for you.
 @warning You must not use this to replace the system's malloc zone, since the implementation uses malloc.
 */

/** @internal @brief Malloc zone.
 
 The zone is thread safe.  All zones share a common garbage collection thread that runs periodically or when a high water mark is reached.  There is typically little benefit from creating multiple zones, and destruction has all the caveats of Apple's zone functions. 
 @return A new malloc zone structure. */
FV_PRIVATE_EXTERN malloc_zone_t * fv_create_zone_named(const char *name);

__END_DECLS

#endif /* _FV_ZONE_H_ */
