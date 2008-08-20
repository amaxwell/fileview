#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import "FVBitmapContext.h"
#import "FVAllocator.h"
#import "FVUtilities.h"
#import <libkern/OSAtomic.h>

CGContextRef FVCFIconBitmapContextCreateWithSize(size_t width, size_t height)
{
    size_t bitsPerComponent = 8;
    size_t nComponents = 4;
    size_t bytesPerRow = FVPaddedRowBytesForWidth(nComponents, width);
    
    size_t requiredDataSize = bytesPerRow * height;
    
    /* 
     CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB) gives us a device independent colorspace, but we don't care in this case, since we're just drawing to the screen, and color conversion when blitting the CGImageRef is a pretty big hit.  See http://www.cocoabuilder.com/archive/message/cocoa/2002/10/31/56768 for additional details, including a recommendation to use alpha in the highest 8 bits (ARGB) and use kCGRenderingIntentAbsoluteColorimetric for rendering intent.
     */
    
    /*
     From John Harper on quartz-dev: http://lists.apple.com/archives/Quartz-dev/2008/Feb/msg00045.html
     "Since you are creating the images you give to CA in the GenericRGB color space, CA will have to copy each image and color-match it to the display before they can be uploaded to the GPU. So the first thing I would try is using a DisplayRGB colorspace when you create the bitmap context. Also, to avoid having the graphics card make another copy, you should align the row bytes of the new image to at least 64 bytes. Finally, it's normally best to create BGRA images on intel machines and ARGB on ppc, so that would be the image format (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host)."
     
     Based on the older post outlined above, I was already using a device RGB colorspace, but former information indicated that 16 byte row alignment was best, and I was using ARGB on both ppc and x86.  Not sure if the alignment comment is completely applicable since I'm not interacting directly with the GPU, but it shouldn't hurt.
     */
    
    char *bitmapData = CFAllocatorAllocate(NULL, requiredDataSize, 0);
    if (NULL == bitmapData) return NULL;
    
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctxt;
    CGBitmapInfo bitmapInfo = (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    ctxt = CGBitmapContextCreate(bitmapData, width, height, bitsPerComponent, bytesPerRow, cspace, bitmapInfo);
    CGColorSpaceRelease(cspace);
    
    CGContextSetRenderingIntent(ctxt, kCGRenderingIntentAbsoluteColorimetric);
    
    // note that bitmapData and the context itself are allocated and not freed here
    
    return ctxt;
}

void FVCFIconBitmapContextDispose(CGContextRef ctxt)
{
    void *bitmapData = CGBitmapContextGetData(ctxt);
    if (bitmapData) CFAllocatorDeallocate(NULL, bitmapData);
    CGContextRelease(ctxt);
}

#define NUM_IMAGES 20000

static void func1()
{
    const size_t dimension = 256;
    CGRect fillRect = CGRectMake(0, 0, dimension, dimension);
    const CGFloat fill[4] = { 0.5, 0.3, 0.2, 0 };
    
    CFAbsoluteTime t1, t2;
    t1 = CFAbsoluteTimeGetCurrent();
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    NSMutableArray *array = [NSMutableArray new];
    for (int i = 0; i < NUM_IMAGES; i++) {    
        CGContextRef context = FVIconBitmapContextCreateWithSize(dimension, dimension);
        CGContextSetFillColor(context, fill);
        CGContextFillRect(context, fillRect);
        CFDataRef cfData = CFDataCreateWithBytesNoCopy(NULL, CGBitmapContextGetData(context), CGBitmapContextGetBytesPerRow(context) * dimension, FVAllocatorGetDefault());
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(cfData);
        CFRelease(cfData);
        CGImageRef anImage = CGImageCreate(dimension, dimension, 8, 32, CGBitmapContextGetBytesPerRow(context), cspace, (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host), provider, NULL, true, kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        CGContextRelease(context);
        //FVIconBitmapContextDispose(context);
        [array addObject:(id)anImage];
        CGImageRelease(anImage);
        if (i % 200 == 0) [array removeAllObjects];
    }
    [array release];
    t2 = CFAbsoluteTimeGetCurrent();
    FVLog(@"FVAllocator: %.2f seconds for %d iterations", t2 - t1, NUM_IMAGES);    
}

static void func2()
{
    const size_t dimension = 256;
    CGRect fillRect = CGRectMake(0, 0, dimension, dimension);
    const CGFloat fill[4] = { 0.5, 0.3, 0.2, 0 };
    
    CFAbsoluteTime t1, t2;
    t1 = CFAbsoluteTimeGetCurrent();
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    NSMutableArray *array = [NSMutableArray new];
    for (int i = 0; i < NUM_IMAGES; i++) {    
        CGContextRef context = FVCFIconBitmapContextCreateWithSize(dimension, dimension);
        CGContextSetFillColor(context, fill);
        CGContextFillRect(context, fillRect);
        CFDataRef cfData = CFDataCreateWithBytesNoCopy(NULL, CGBitmapContextGetData(context), CGBitmapContextGetBytesPerRow(context) * dimension, CFAllocatorGetDefault());
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(cfData);
        CFRelease(cfData);
        CGImageRef anImage = CGImageCreate(dimension, dimension, 8, 32, CGBitmapContextGetBytesPerRow(context), cspace, (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host), provider, NULL, true, kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);     
        CGContextRelease(context);
        //FVCFIconBitmapContextDispose(context);
        [array addObject:(id)anImage];
        CGImageRelease(anImage);
        if (i % 200 == 0) [array removeAllObjects];
    }
    [array release];
    t2 = CFAbsoluteTimeGetCurrent();
    FVLog(@"CFAllocator: %.2f seconds for %d iterations", t2 - t1, NUM_IMAGES);
}

static volatile int32_t _threadCount = 0;

@interface ThreadObject1 : NSObject
@end

@implementation ThreadObject1

- (id)init
{
    OSAtomicIncrement32Barrier(&_threadCount);
    return [super init];
}

- (void)run
{
    func1();
    OSAtomicDecrement32Barrier(&_threadCount);
}

@end

@interface ThreadObject2 : ThreadObject1
@end

@implementation ThreadObject2

- (void)run
{
    func2();
    OSAtomicDecrement32Barrier(&_threadCount);
}

@end

#define USE_THREADS 1
#define THREADCOUNT 3
#define USE_FVALLOCATOR 1
#define USE_CFALLOCATOR 1

int main (int argc, const char * argv[]) {
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    
#if USE_THREADS
    for (int j = THREADCOUNT; j <= THREADCOUNT; j++) {
    FVLog(@"Number of threads: %d", j);
#if USE_FVALLOCATOR
    for (int i = 0; i < j; i++) {
        [NSThread detachNewThreadSelector:@selector(run) toTarget:[[ThreadObject1 new] autorelease] withObject:nil];
    }
    while (0 < _threadCount) {
        [NSThread sleepForTimeInterval:1.0];
    }
    [pool drain];
    pool = [NSAutoreleasePool new];
#endif /* USE_FVALLOCATOR */
    
#if USE_CFALLOCATOR  
    for (int i = 0; i < j; i++) {
        [NSThread detachNewThreadSelector:@selector(run) toTarget:[[ThreadObject2 new] autorelease] withObject:nil];
    }
    while (0 < _threadCount) {
        [NSThread sleepForTimeInterval:1.0];
    }
    [pool drain];
    pool = [NSAutoreleasePool new];
    }
#endif /* USE_CFALLOCATOR */
#else
#if USE_FVALLOCATOR
    func1();
#endif /* USE_FVALLOCATOR */
    
#if USE_CFALLOCATOR  
    func2();
#endif /* USE_CFALLOCATOR */

#endif /* USE_THREADS */
    
    [pool drain];
    return 0;
}
