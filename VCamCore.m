#import "VCamCore.h"
#import "LocalVideoPlayer.h"
#import "GPUImageProcessor.h"

#import <mach/mach_time.h>
#import <sys/stat.h>

// vcam124 uses DCIM because mediaserverd has native R/W access to it,
// avoiding any RootHide jbroot path patching headaches.
static NSString *const kVCamSourceVideo = @"/var/mobile/Media/DCIM/vcam.mp4";

// Anything that touches mediaserverd's hot path (1000+ calls/sec) MUST be
// fast. We cache isEnabled() for 200ms so the file stat is amortized.
static const uint64_t kEnabledCacheTTLNs = 200ULL * NSEC_PER_MSEC;

@interface VCamCore ()
@property (nonatomic, strong, readwrite) LocalVideoPlayer *videoPlayer;
@property (nonatomic, strong, readwrite) GPUImageProcessor *gpuProcessor;
@end

@implementation VCamCore {
    uint64_t _enabledCacheTime;
    BOOL _enabledCached;
    BOOL _playerStarted;
}

+ (instancetype)shared {
    static VCamCore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamCore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _gpuProcessor = [GPUImageProcessor new];
        _videoPlayer = [[LocalVideoPlayer alloc] initWithPath:kVCamSourceVideo];
    }
    return self;
}

- (BOOL)isEnabled {
    uint64_t now = mach_absolute_time();
    static mach_timebase_info_data_t tb = {0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    uint64_t nowNs = now * tb.numer / tb.denom;
    if (nowNs - _enabledCacheTime < kEnabledCacheTTLNs) return _enabledCached;

    struct stat st;
    BOOL exists = (stat([kVCamSourceVideo fileSystemRepresentation], &st) == 0 && st.st_size > 0);

    if (exists && !_playerStarted) {
        [_videoPlayer start];
        _playerStarted = YES;
        NSLog(@"[vcam-msd] enabled -> player started");
    } else if (!exists && _playerStarted) {
        [_videoPlayer stop];
        _playerStarted = NO;
        NSLog(@"[vcam-msd] disabled -> player stopped");
    }

    _enabledCached = exists;
    _enabledCacheTime = nowNs;
    return exists;
}

- (CMSampleBufferRef)replaceSampleBuffer:(CMSampleBufferRef)original {
    if (!original) return NULL;

    CVImageBufferRef origPB = CMSampleBufferGetImageBuffer(original);
    if (!origPB) return NULL;

    OSType origFormat = CVPixelBufferGetPixelFormatType(origPB);
    size_t origW = CVPixelBufferGetWidth(origPB);
    size_t origH = CVPixelBufferGetHeight(origPB);

    CVPixelBufferRef srcFrame = [_videoPlayer latestFrameRetained];
    if (!srcFrame) return NULL;

    // Convert source frame (BGRA, video dimensions) into mediaserverd-expected
    // format/size. GPU-accelerated via VTPixelTransferSession.
    CVPixelBufferRef converted = [_gpuProcessor convertPixelBuffer:srcFrame
                                                          toFormat:origFormat
                                                             width:origW
                                                            height:origH];
    CFRelease(srcFrame);
    if (!converted) return NULL;

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(NULL, converted, &fmtDesc);
    if (s != noErr || !fmtDesc) {
        CFRelease(converted);
        return NULL;
    }

    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);

    CMSampleBufferRef newSB = NULL;
    s = CMSampleBufferCreateReadyWithImageBuffer(NULL, converted, fmtDesc, &timing, &newSB);
    CFRelease(fmtDesc);
    CFRelease(converted);
    if (s != noErr || !newSB) return NULL;

    // Propagate per-sample attachments so downstream consumers (encoder,
    // metadata extractors) see the same rotation, focus, exposure flags.
    CFArrayRef origAttach = CMSampleBufferGetSampleAttachmentsArray(original, false);
    if (origAttach && CFArrayGetCount(origAttach) > 0) {
        CFArrayRef newAttach = CMSampleBufferGetSampleAttachmentsArray(newSB, true);
        if (newAttach && CFArrayGetCount(newAttach) > 0) {
            CFDictionaryRef src = (CFDictionaryRef)CFArrayGetValueAtIndex(origAttach, 0);
            CFMutableDictionaryRef dst = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(newAttach, 0);
            if (src && dst) {
                CFIndex n = CFDictionaryGetCount(src);
                if (n > 0) {
                    const void **keys = malloc(sizeof(void *) * n);
                    const void **vals = malloc(sizeof(void *) * n);
                    CFDictionaryGetKeysAndValues(src, keys, vals);
                    for (CFIndex i = 0; i < n; i++) {
                        CFDictionarySetValue(dst, keys[i], vals[i]);
                    }
                    free(keys); free(vals);
                }
            }
        }
    }

    return newSB;
}

@end
