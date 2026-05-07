#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// vcam124-style cached transfer pipeline.
///
/// SLOW PATH (rebuild, runs once per (srcFrameID, dstW, dstH, dstFmt) tuple):
///   src (BGRA, source video resolution + orientation)
///       → VTPixelTransferSession with rotation/scale baked in
///       → cachedBuffer (matches dst dim + format + orientation)
///
/// FAST PATH (every emit, cache hit):
///   cachedBuffer → VTPixelTransferSession → dst
///   Both buffers same dim/fmt/orientation, so VT runs as a hardware blit
///   (~50µs even at 1080p+) instead of the multi-millisecond software fallback
///   forced by orientation/scale mismatch.
@interface GPUImageProcessor : NSObject

/// Transfer the latest source frame into `dst` in place. `srcID` is the
/// monotonic frame counter from LocalVideoPlayer; when it changes, the cache
/// is rebuilt. When dst dimensions/format change, the cache is also rebuilt.
- (BOOL)transferFrom:(CVPixelBufferRef)src
               srcID:(uint64_t)srcID
                into:(CVPixelBufferRef)dst;

// Stats for VCamCore.dumpStats
- (uint64_t)vtCallCount;
- (uint64_t)vtTotalNs;
- (uint64_t)vtMaxNs;
- (uint64_t)cacheHitCount;
- (uint64_t)cacheRebuildCount;
- (uint64_t)cacheRebuildTotalNs;

@end

NS_ASSUME_NONNULL_END
