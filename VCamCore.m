#import "VCamCore.h"
#import "LocalVideoPlayer.h"
#import "GPUImageProcessor.h"

#import <mach/mach_time.h>
#import <sys/stat.h>

// vcam124 uses DCIM because mediaserverd has native R/W access to it,
// avoiding RootHide jbroot path patching headaches.
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

- (BOOL)replaceInPlace:(CMSampleBufferRef)sb {
    if (!sb) return NO;

    // Only replace video frames. Camera audio + metadata buffers (mediaType
    // 'soun', 'meta', 'subt', etc.) must pass through untouched, otherwise
    // recording / encoding pipelines wedge.
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!fmt || CMFormatDescriptionGetMediaType(fmt) != kCMMediaType_Video) return NO;

    CVImageBufferRef dstPB = CMSampleBufferGetImageBuffer(sb);
    if (!dstPB) return NO;

    CVPixelBufferRef srcFrame = [_videoPlayer latestFrameRetained];
    if (!srcFrame) return NO;

    BOOL ok = [_gpuProcessor transferFrom:srcFrame into:dstPB];
    CFRelease(srcFrame);
    return ok;
}

@end
