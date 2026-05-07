#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Background AVAssetReader-driven video decoder. Loops indefinitely.
/// Holds the most recently decoded frame as a CVPixelBuffer (BGRA32).
/// Thread-safe: latestFrameRetained may be called from any queue.
@interface LocalVideoPlayer : NSObject

- (instancetype)initWithPath:(NSString *)path;

- (void)start;
- (void)stop;

/// Returns a retained snapshot of the latest decoded frame, or NULL.
- (nullable CVPixelBufferRef)latestFrameRetained CF_RETURNS_RETAINED;

/// Monotonic counter incremented every time the decoder produces a new frame.
/// GPUImageProcessor uses this to invalidate the cached rotated buffer when
/// the source frame content changes (~30 changes/sec at 30fps source). The
/// emit hook calls this 1000+/sec but the ID only changes ~30/sec, so the
/// fast path (cache hit) runs ~970× per source frame.
- (uint64_t)latestFrameID;

@end

NS_ASSUME_NONNULL_END
