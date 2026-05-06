#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps a single VTPixelTransferSession configured for camera real-time use:
///   kVTPixelTransferPropertyKey_RealTime = kCFBooleanTrue
///   kVTPixelTransferPropertyKey_ScalingMode = kVTScalingMode_CropSourceToCleanAperture
/// Both properties match vcam124's setupPixelTransferSession (analyzed at
/// 0x1e6ec) and are required for VT to take its low-latency hardware blit
/// path. Without them, default VT does high-quality bilinear scaling and
/// can be 5-10× slower per call — at mediaserverd's emit rate this
/// accumulates and hangs the camera daemon.
@interface GPUImageProcessor : NSObject

/// Write `src` into `dst` in place. Returns YES on success. Thread-safe via
/// NSRecursiveLock.
- (BOOL)transferFrom:(CVPixelBufferRef)src into:(CVPixelBufferRef)dst;

/// Per-frame VT latency stats. All in nanoseconds. Read by VCamCore for the
/// stats dump file.
- (uint64_t)vtCallCount;
- (uint64_t)vtTotalNs;
- (uint64_t)vtMaxNs;

@end

NS_ASSUME_NONNULL_END
