#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@class LocalVideoPlayer;
@class GPUImageProcessor;

NS_ASSUME_NONNULL_BEGIN

/// Mediaserverd-side virtual camera coordinator. Owns the video decoder and
/// GPU transfer session. Mutates camera frames in place — the original
/// CMSampleBuffer / CVPixelBuffer / IOSurface objects are preserved, only
/// their pixel content is overwritten.
@interface VCamCore : NSObject

@property (class, nonatomic, readonly) VCamCore *shared;
@property (nonatomic, strong, readonly) LocalVideoPlayer *videoPlayer;
@property (nonatomic, strong, readonly) GPUImageProcessor *gpuProcessor;

/// Cached ~200ms. Returns YES when a vcam.mp4 source is ready.
- (BOOL)isEnabled;

/// Overwrite the pixel content of `sampleBuffer` with the latest frame from
/// the virtual video source. The sample buffer's format desc, timing,
/// attachments, and IOSurface bindings are all left untouched. Returns YES
/// when content was successfully written; NO when the caller should pass the
/// sample buffer through unchanged.
- (BOOL)replaceInPlace:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END
