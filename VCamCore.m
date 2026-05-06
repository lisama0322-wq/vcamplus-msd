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

// VTPixelTransferSession silently writes garbage when the destination uses one
// of Apple's private formats (e.g. '-8f0' that the system Camera app's high-
// res preview pipeline emits at 2304x1650). Skipping replacement for unknown
// formats lets the original frame pass through — system Camera shows the real
// preview instead of a black screen, while standard 420v/420f/BGRA consumers
// (GT, X, Bitget WV, every third-party app) still see our virtual frame.
static BOOL vcam_isReplaceableFormat(OSType fmt) {
    switch (fmt) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  // '420v'
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:   // '420f'
        case kCVPixelFormatType_32BGRA:                         // 'BGRA'
        case kCVPixelFormatType_32ARGB:
        case kCVPixelFormatType_422YpCbCr8:                     // '2vuy'
            return YES;
        default:
            return NO;
    }
}

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
    if (!vcam_isReplaceableFormat(origFormat)) {
        // Log once per unique format to avoid log spam on the hot path.
        static NSMutableSet *seen = nil; static dispatch_once_t once;
        dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
        NSNumber *k = @(origFormat);
        @synchronized(seen) {
            if (![seen containsObject:k]) {
                [seen addObject:k];
                char fcc[5] = {0};
                fcc[0] = (origFormat >> 24) & 0xff; fcc[1] = (origFormat >> 16) & 0xff;
                fcc[2] = (origFormat >> 8) & 0xff;  fcc[3] = origFormat & 0xff;
                NSLog(@"[vcam-msd] skip non-replaceable format: '%s' (0x%08x)", fcc, (unsigned)origFormat);
            }
        }
        return NULL;
    }
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
