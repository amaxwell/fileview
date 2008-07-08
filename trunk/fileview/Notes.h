/*
 
 This is a header file only so that doxygen will pick it up!
 
 */

#error do not include this file

/** \mainpage Conceptual Documentation
 Last update: 07 July 2008

 \section sec_intro Introduction
 The FileView framework provides a gridded view with scaling and automatic layout of icons.  Each icon represents an NSURL instance, and drawing is handled per-URL.  Either Cocoa Bindings or a standard datasource paradigm may be used to provide the view with NSURL instances, and an optional delegate may be used to override some behavior.  
 
 Rearranging and editing in the view is supported via datasource methods.  Drag-and-drop is implemented using standard URL and filename pasteboard types.
 
 The framework is extensively multithreaded, and optimized for reduced memory usage.  Most operations in the view itself should not block.
  
 \subsection sec_types Supported Types
 Many file and URL types are supported by default.  These include:
 
  @li PDF/PostScript?
  @li <a href="http://skim-app.sourceforge.net/">Skim</a> PDFD
  @li Anything NSAttributedString can read
  @li http/ftp URLs and local HTML files using WebView
  @li QuickTime movies
  @li Anything <a href="http://developer.apple.com/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_intro/chapter_1_section_1.html">ImageIO</a> can read
  @li Quick Look thumbnails (on 10.5)
  @li Icon Services as a last resort
 
 \section sec_design Design and Implementation
 
 @li \ref page0
 @li \ref page1
 @li \ref page2
 @li \ref page3
 @li \ref page4
 
*/

/** @page page0 FileView API
 
 FileView has a limited API by design.  The framework itself is relatively immature, and a small API allows substantial internal revision without breaking any previous contracts or assumptions.  In particular, grid geometry, icons, caching, and drop targeting should be considered implementation details.  You can modify the FileView.h header to expose whatever you want, of course, but integrating future changes from upstream will be more difficult.
 
 \section sec_internal Internal Classes
 Many classes in the framework documentation are marked for internal use only.  This means that usage is only supported within the framework, and implementation details and API are subject to change.  You are free to make project headers into public headers in Xcode, but be advised that they are subject to change without warning.
 
 \section sec_stable Stable Classes
 Having said that, some of the classes should have stable API:  FVThread, FVOperationQueue, FVOperation, and FVPriorityQueue, so making them public is reasonably safe.  They are not exposed because they don't fit the purpose of the framework, and are not necessary to any of its API (i.e. NSOperationQueue and NSOperation could be used in future).  They could be factored out into a separate framework, but creating an umbrella framework would be tricky and I don't want to deal with the linkage problems.
 
 \section sec_c_internal C Functions
 Most C functions are only available exported to the framework itself, and exporting those globally would be a bad idea at any time.  FVCGImageUtilities.h is a possible exception to this rule, but FVUtilities, FVBitmapContext.h and FVImageBuffer (which are all included by FVCGImageUtilities.h) are implementation details that should remain internal.

 */

/** @page page1 FVIcon Discussion
 
 \section sec_DesignNotes Design Notes
The primary file type the view was intended for is PDF, so much of the caching strategy and design is oriented towards that.   NSImage and NSBitmapImageRep are not used because performance was inadequate in earlier trials (excessive memory consumption).  Of the two, NSBitmapImageRep had better drawing quality, particularly in view of the need to scale from small (< 48x48) to large (> 512x512) image sizes.  NSImage is too clever for its own good.

 \section sec_Purpose Purpose
For drawing, I created the FVIcon abstract class, with a variety of concrete subclasses (all private to the framework), initialized based on UTI or sniffing.  FVIcon is designed to be fairly lightweight, and typically uses a fallback of a Quick Look or Finder icon, depending on the platform.  The FVIcon has some provision for caching and explicitly flushing a cache; it's lazy about creating high-resolution images in order to keep memory requirements down.  In the simplest case, it's basically a wrapper around an NSURL instance and a CGImageRef.  I'm using CGImage instead of NSBitmapImageRep for consistency, since ImageIO and QuickLook return CGImage instances directly.
 
 \section sec_ThreadSafety Thread Safety
Drawing to offscreen bitmap contexts is performed in FVIcon::renderOffscreen, and that should generally be called from a secondary thread.  If you need synchronous rendering, call the FVIcon::renderOffscreen method, wait until it's done, then draw the icon.  Locking details are private to each subclass, but they conform to \<NSLocking\> for convenience sake.
 
 \section sec_Bitmaps Why Bitmaps?
CGLayer could be used instead of a CGImage, but there's no way to get the underlying data from the CGLayer and cache it to disk.  CGImage allows copying the bitmap data from its data provider, so we can store that along with all the necessary bitmap details.
 
 \subsection sec_Scaling Image Scaling
 Bitmap scaling is generally performed using vImage.  Drawing into a new CGBitmapContext is faster, but can result in excessive memory usage, especially when scaling multiple large bitmaps simultaneously; it's actually fairly easy to run out of address space in 32 bit mode.  A test program called ImageShear is provided for playing with the vImage and scaling/tiling engine, which could certainly be improved.  I've no idea how "real" graphics programs implement tiling, so came up with my own scheme.  It works reasonably well, but has striping artifacts under some conditions.  This is seldom an issue with the image sizes I've encountered, since none of the artifacts are relevant for thumbnails.  Most importantly, the framework's memory usage is minimized.

 \section sec_Subclassing Subclassing
 
If you want to draw custom content without hacking the view, create an FVIcon subclass for a private URL scheme, such as x-customview-identifier:, and add a case for that scheme to the FVIcon::iconWithURL: implementation.  If you do synchronous drawing, implement FVIcon::needsRenderForSize: to always return NO and FVIcon::renderOffscreen to do nothing, then do whatever drawing you want in FVIcon::drawInRect:ofContext:.
 
FVIcon is designed for subclassing.  There are two headers to understand:
 
 @li FVIcon (API internal to the framework)
 @li FVIcon_Private.h (API internal to FVIcon instances)
 
FVIcon.h is fairly simple, but caching and threading add complexity, and FVIcon_Private helps abstract a few of those.  Once you understand the subclass requirements, you can add your subclass to the cluster in FVIcon::iconWithURL:, which is basically a long if/else list to determine which subclass should be instantiated for a given URL.  This is generally based on either URL scheme or UTI.
 
 */

/** @page page2 Framework Conventions
 
 \section sec_Naming Naming
In the framework, private methods and ivars begin with a leading underscore so I can keep track of them more easily (this was really a huge help during development).  Apple seems to have backed off on the no-underscores-on-ivars requirement these days, and the private methods are named such that there's a low chance of collision (zero on 10.4--10.5).  
 
 \section sec_Private Private Methods
 <b>Private methods are generally private because they may have unintended side effects</b>.  For instance, some of the drawing methods assume that focus is locked and they can screw with the graphics state without saving/restoring as an optimization.  Don't use private methods unless you understand what they do.
 
 I've tried to avoid One Big Method where the work can be factored out; this really helped with sanity in the drawing code, but it also implies that some methods are only called once.  This is intentional, since I find short blocks of code easier to figure out.  I've also tried to avoid multiple exit points, but a few have crept in.
 
 \section sec_ApplePrivate Apple SPI Usage
 <b>Using Apple SPI is a bad idea.</b>  Only one private function is used, and it's noted in the header that it may fail at any time.  FVCGImageUtilities.h::__FVCGImageGetBytePtr has a huge performance benefit, but calls an undocumented function to read data from a CGDataProvider without copying.  Scaling multiple large bitmaps simultaneously is only possible using this function, since copying the entire bitmap can blow out the address space unless you compile with 64 bit support.
 
 */

/** @page page3 Caching

Caching in FileView is moderately complicated, and uses heuristics that I've profiled on a dual G5 (1.8), a PowerBook G4 (1.33), and a MacBook Pro 2.2.  Performance should be adequate even on older hardware, but multiple processors will definitely help.

\section sec_DiskCaching Disk Cache
 FVIcon instances use an on-disk cache (FVIconCache) for storing rendered CGImageRef data for fast reinitialization of large bitmaps.  This was a big performance win, especially for PDF files.  These are never removed, so the cache can grow without bound.  Up to 500 PDF files, cache sizes are under 20 MB with the zlib compression I'm using, so I'm not too concerned about it.  The disk cache is fast and thread safe, but not designed for persistent storage; it's blown away when the app quits.

 \section sec_ViewCache View Cache
Some bindings support exists, mainly for optimized datasources.  However, FileView maintains its own cache mapping NSURL->FVIcon.  This works pretty well, since clients should not be expected to understand the internals or caching requirements.  However, it leads to some storage of redundant information.  In the worst case, a master detail view might have 1000 NSURLs that are each only touched once while the user scrolls through the master interface, yet FileView creates a cache entry for each of those.  To work around this, the cache is periodically checked against the datasource to reap "zombie" icons that no longer have a relationship to the datasource.  This is a fairly low-impact operation, providing the datasource is reasonably efficient.

*/

/** @page page4 Queueing Operations
 
FVOperation and FVOperationQueue were designed as minimal replacements for NSOperation on 10.4, but with some changes.  In particular, FVOperation does not support dependencies as NSOperation does, since I don't need that feature.  FVOperationQueue also ignores repeat operations, so if the same operation is added to the queue multiple times (as determined by FVOperation::isEqual:, it's only invoked once.  In addition, one queue is dedicated to the main thread for convenience; it's conceptually equivalent to using performSelectorOnMainThread:withObject:waitUntilDone:modes: with waitUntilDone = NO and modes = kCFRunLoopCommonModes.  FVMIMEIcon and FVTextIcon have an example of how to use the main thread queue in a blocking manner.
 
*/
