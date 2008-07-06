/*
 
 This is a header file only so that doxygen will pick it up!
 
 */

#error do not include this file

/** \mainpage FileView Framework Conceptual Documentation
 Last update: 24 May 2008

 \section sec_DesignNotes Design Notes
 
 \subsection sec_Background Background
The primary file type I expect is PDF, so much of the caching strategy and design is oriented towards PDF.  I'm not using NSImage or NSBitmapImageRep because performance was inadequate in my earlier trials (excessive memory consumption).  Of the two, NSBitmapImageRep had better drawing quality, particularly in view of the need to scale from small (< 48x48) to large (> 512x512) image sizes.  NSImage is too clever for its (and my) own good.

 \subsection sec_FVIconNotes FVIcon Notes
For drawing, I created the FVIcon abstract class, with a variety of concrete subclasses (all private to the framework), initialized based on UTI or sniffing.  The fallback is a QuickLook or Finder icon, depending on the platform.  The FVIcon has some provision for caching and explicitly flushing a cache; it's lazy about creating high-resolution images in order to keep memory requirements down.  In the simplest case, it's basically a wrapper around an NSURL instance and a CGImageRef.  I'm using CGImage instead of NSBitmapImageRep for consistency, since ImageIO and QuickLook return CGImage instances directly.

FVIcon is designed to be thread safe, and still fairly lightweight.  Drawing to offscreen bitmap contexts is performed in -[FVIcon renderOffscreen], and that should generally be called from a secondary thread.  If you need synchronous rendering, call the renderOffscreen method, wait until it's done, then draw the icon.

 \subsection sec_NamingConventions Naming Conventions
In the framework, private methods and ivars begin with a leading underscore so I can keep track of them more easily (this was really a huge help during development).  Apple seems to have backed off on the no-underscores-on-ivars requirement these days, and the private methods are named such that there's a low chance of collision (zero on 10.4--10.5).  NOTE: Private methods are generally private because they may have unintended side effects (some of the drawing methods assume that focus is locked and they can screw with the graphics state without saving/restoring, for instance, as an optimization).  I've tried to avoid One Big Method where the work can be factored out; this really helped with sanity in the drawing code, but it also implies that some methods are only called once.  This is intentional, since I find short blocks of code easier to figure out.  I've also tried to avoid multiple exit points and continue statements in loops, but a few have crept in.

 \subsection sec_FileViewCaching Caching
Caching in FileView is moderately complicated, and uses heuristics that I've profiled on a dual G5 (1.8), a PowerBook G4 (1.33), and a MacBook Pro 2.2.  Performance should be adequate even on older hardware, but multiple processors will definitely help.

FileView expects an ordered list of NSURL instances, which may be file: scheme or other schemes (allowing non-file: URLs was an afterthought, hence the name).  If you want to draw custom content without hacking the view, create an FVIcon subclass for a private URL scheme, such as x-customview-identifier:, and add a case for that scheme to the FVIcon::iconWithURL: implementation.  If you do synchronous drawing, implement FVIcon::needsRenderForSize: to always return NO and FVIcon::renderOffscreen to do nothing, then do whatever drawing you want in FVIcon::drawInRect:ofContext:.  It would likely be easier to just gut the queuing and caching code if you aren't using it, though, since it will spawn threads whether you use them or not.

Some bindings support exists, mainly for optimized datasources.  However, FileView maintains its own cache mapping NSURL->FVIcon.  This works pretty well, since clients should not be expected to understand the internals or caching requirements.  However, it leads to some storage of redundant information.  In the worst case, a master detail view might have 1000 NSURLs that are each only touched once while the user scrolls through the master interface, yet FileView creates a cache entry for each of those.  To work around this, the cache is periodically checked against the datasource to reap "zombie" icons that no longer have a relationship to the datasource.  This is a fairly low-impact operation, providing the datasource is reasonably efficient.

FVIcon instances use an on-disk cache (FVIconCache) for storing rendered CGImageRef data for fast reinitialization of large bitmaps.  This was a big performance win, especially for PDF files.  These are never removed, so the cache can grow without bound.  Up to 500 PDF files, cache sizes are under 20 MB with the zlib compression I'm using, so I'm not too concerned about it.  The disk cache is fast and thread safe, but not designed for persistent storage; it's blown away when the app quits.

 \subsection sec_Operations Queueing Operations
FVOperation and FVOperationQueue were designed as minimal replacements for NSOperation on 10.4, but with some changes.  In particular, FVOperation does not support dependencies as NSOperation does, since I don't need that feature.  FVOperationQueue also ignores repeat operations, so if the same operation is added to the queue multiple times (as determined by FVOperation::isEqual:, it's only invoked once.  In addition, one queue is dedicated to the main thread for convenience; it's conceptually equivalent to using performSelectorOnMainThread:withObject:waitUntilDone:modes: with waitUntilDone = NO and modes = kCFRunLoopCommonModes.  FVMIMEIcon and FVTextIcon have an example of how to use the main thread queue in a blocking manner.

 \subsection sec_Scaling Image Scaling
Bitmap scaling is generally performed using vImage.  Drawing into a new CGBitmapContext is faster, but can result in excessive memory usage, especially when scaling multiple large bitmaps simultaneously; it's actually fairly easy to run out of address space in 32 bit mode.  A test program called ImageShear is provided for playing with the vImage and scaling/tiling engine, which could certainly be improved.  I've no idea how "real" graphics programs implement tiling, so came up with my own scheme.  It works reasonably well, but has striping artifacts under some conditions.  This is seldom an issue with the image sizes I've encountered, since none of the artifacts are relevant for thumbnails.  Most importantly, the framework's memory usage is minimized.
 
*/
