#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Background AVAssetReader-driven video decoder. Loops indefinitely.
/// Holds the most recently decoded frame as a CVPixelBuffer (BGRA32).
/// Thread-safe: latestFrameRetained may be called from any queue.
@interface LocalVideoPlayer : NSObject

- (instancetype)initWithPath:(NSString *)path;

/// Start the decode loop on a background queue. Idempotent.
- (void)start;

/// Stop the decode loop. Releases the cached frame.
- (void)stop;

/// Returns a retained snapshot of the latest decoded frame, or NULL if not
/// yet ready or the decoder has stopped. Caller must CFRelease().
- (nullable CVPixelBufferRef)latestFrameRetained CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
