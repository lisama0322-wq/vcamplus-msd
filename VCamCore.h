#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@class LocalVideoPlayer;
@class GPUImageProcessor;

NS_ASSUME_NONNULL_BEGIN

/// Central state holder for the mediaserverd-side virtual camera.
/// Owns the video decoder, GPU processor, and the per-call replacement logic.
@interface VCamCore : NSObject

@property (class, nonatomic, readonly) VCamCore *shared;
@property (nonatomic, strong, readonly) LocalVideoPlayer *videoPlayer;
@property (nonatomic, strong, readonly) GPUImageProcessor *gpuProcessor;

/// Cheap, cached check for whether replacement should run. Cached ~200ms.
- (BOOL)isEnabled;

/// Build a replacement CMSampleBuffer that mimics `original` (same format, size,
/// timing) but with our virtual frame as pixel content. Returns NULL on any
/// failure, in which case the caller MUST forward the original unchanged.
/// Returned buffer is retained — caller releases.
- (nullable CMSampleBufferRef)replaceSampleBuffer:(CMSampleBufferRef)original CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
