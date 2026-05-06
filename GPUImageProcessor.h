#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Hardware-accelerated pixel buffer format conversion + scaling, backed by
/// VTPixelTransferSession. Maintains a cache of CVPixelBufferPools keyed by
/// (format, width, height) so per-frame work is amortised.
@interface GPUImageProcessor : NSObject

/// Convert `src` into a new buffer matching `format`/`width`/`height`.
/// Returns retained CVPixelBuffer (caller releases) or NULL on failure.
- (nullable CVPixelBufferRef)convertPixelBuffer:(CVPixelBufferRef)src
                                       toFormat:(OSType)format
                                          width:(size_t)width
                                         height:(size_t)height CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
