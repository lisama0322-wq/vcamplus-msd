#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps a single VTPixelTransferSession so the source frame can be written
/// directly into the destination camera pixel buffer in place. No format
/// conversion or pool allocation needed — VT handles size/format match
/// internally for any IOSurface-backed destination, including Apple's private
/// formats (e.g. '-8f0' that the system Camera app emits at 2304x1650).
@interface GPUImageProcessor : NSObject

/// Write `src` into `dst` in place. Returns YES on success. Thread-safe.
- (BOOL)transferFrom:(CVPixelBufferRef)src into:(CVPixelBufferRef)dst;

@end

NS_ASSUME_NONNULL_END
