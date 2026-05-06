#import "VCamCore.h"
#import "LocalVideoPlayer.h"
#import "GPUImageProcessor.h"

#import <mach/mach_time.h>
#import <sys/stat.h>
#import <stdatomic.h>

static NSString *const kVCamSourceVideo = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kVCamStatsFile   = @"/var/mobile/Media/DCIM/vcam_msd_stats.txt";

static const uint64_t kEnabledCacheTTLNs = 200ULL * NSEC_PER_MSEC;

// Lossy-compressed pixel formats. VTPixelTransferSession cannot write into
// these (compressed-tile IOSurface backing). Skip outright.
static inline BOOL vcam_isLossyDestination(OSType fmt) {
    switch (fmt) {
        case 0x2D387630:  // '-8v0'
        case 0x2D386630:  // '-8f0'
        case 0x2D787630:  // '-xv0'
        case 0x2D786630:  // '-xf0'
        case 0x2D343230:  // '-420'
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

    // Atomic counters — incremented on hot path, sampled by stats timer.
    // No ObjC allocation, no lock, just _Atomic adds.
    _Atomic uint64_t _hitTotal;
    _Atomic uint64_t _hitNonVideo;
    _Atomic uint64_t _hitNoPB;
    _Atomic uint64_t _hitLossyDst;
    _Atomic uint64_t _hitNoSrc;
    _Atomic uint64_t _hitVTAttempt;
    _Atomic uint64_t _hitVTSuccess;
    _Atomic uint64_t _hitVTFail;
    _Atomic int      _lastVTStatus;
    _Atomic uint32_t _lastDstFmt;
    _Atomic uint32_t _lastDstW;
    _Atomic uint32_t _lastDstH;

    dispatch_source_t _statsTimer;
}

+ (instancetype)shared {
    static VCamCore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamCore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _gpuProcessor = [GPUImageProcessor new];
        _videoPlayer  = [[LocalVideoPlayer alloc] initWithPath:kVCamSourceVideo];

        // Stats dump runs on a background queue. Hot path never allocates;
        // this thread does the formatting work.
        dispatch_queue_t q = dispatch_queue_create("com.vcamplus.msd.stats", DISPATCH_QUEUE_SERIAL);
        _statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(_statsTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_statsTimer, ^{
            @autoreleasepool { [weakSelf dumpStats]; }
        });
        dispatch_resume(_statsTimer);
    }
    return self;
}

- (void)dumpStats {
    uint32_t fmt = atomic_load(&_lastDstFmt);
    uint32_t w   = atomic_load(&_lastDstW);
    uint32_t h   = atomic_load(&_lastDstH);
    char fcc[5] = {0};
    fcc[0] = (fmt >> 24) & 0xff; fcc[1] = (fmt >> 16) & 0xff;
    fcc[2] = (fmt >> 8) & 0xff;  fcc[3] = fmt & 0xff;

    NSMutableString *s = [NSMutableString stringWithCapacity:512];
    [s appendFormat:@"=== vcam-msd stats @ %@ ===\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle]];
    [s appendFormat:@"playerStarted=%d enabled=%d\n", _playerStarted, _enabledCached];
    [s appendFormat:@"lastVTStatus=%d  lastDst=%ux%u '%s' (0x%08x)\n",
        atomic_load(&_lastVTStatus), w, h, fcc, fmt];
    [s appendFormat:@"hitTotal:    %llu\n", atomic_load(&_hitTotal)];
    [s appendFormat:@"  nonVideo:  %llu\n", atomic_load(&_hitNonVideo)];
    [s appendFormat:@"  noPB:      %llu\n", atomic_load(&_hitNoPB)];
    [s appendFormat:@"  lossyDst:  %llu\n", atomic_load(&_hitLossyDst)];
    [s appendFormat:@"  noSrc:     %llu\n", atomic_load(&_hitNoSrc)];
    [s appendFormat:@"  vtAttempt: %llu\n", atomic_load(&_hitVTAttempt)];
    [s appendFormat:@"  vtSuccess: %llu\n", atomic_load(&_hitVTSuccess)];
    [s appendFormat:@"  vtFail:    %llu\n", atomic_load(&_hitVTFail)];
    [s writeToFile:kVCamStatsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
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

// Hot path — called ~1000-3000 times/sec. NO ObjC allocation, NO @synchronized,
// NO NSString work. Counters are _Atomic increments.
- (BOOL)replaceInPlace:(CMSampleBufferRef)sb {
    if (!sb) return NO;
    atomic_fetch_add_explicit(&_hitTotal, 1, memory_order_relaxed);

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!fmt || CMFormatDescriptionGetMediaType(fmt) != kCMMediaType_Video) {
        atomic_fetch_add_explicit(&_hitNonVideo, 1, memory_order_relaxed);
        return NO;
    }

    CVImageBufferRef dstPB = CMSampleBufferGetImageBuffer(sb);
    if (!dstPB) {
        atomic_fetch_add_explicit(&_hitNoPB, 1, memory_order_relaxed);
        return NO;
    }

    OSType dstFmt = CVPixelBufferGetPixelFormatType(dstPB);
    atomic_store_explicit(&_lastDstFmt, dstFmt, memory_order_relaxed);
    atomic_store_explicit(&_lastDstW, (uint32_t)CVPixelBufferGetWidth(dstPB), memory_order_relaxed);
    atomic_store_explicit(&_lastDstH, (uint32_t)CVPixelBufferGetHeight(dstPB), memory_order_relaxed);

    if (vcam_isLossyDestination(dstFmt)) {
        atomic_fetch_add_explicit(&_hitLossyDst, 1, memory_order_relaxed);
        return NO;
    }

    CVPixelBufferRef srcFrame = [_videoPlayer latestFrameRetained];
    if (!srcFrame) {
        atomic_fetch_add_explicit(&_hitNoSrc, 1, memory_order_relaxed);
        return NO;
    }

    atomic_fetch_add_explicit(&_hitVTAttempt, 1, memory_order_relaxed);
    OSStatus st = [_gpuProcessor transferFromStatus:srcFrame into:dstPB];
    CFRelease(srcFrame);
    atomic_store_explicit(&_lastVTStatus, st, memory_order_relaxed);
    if (st == noErr) {
        atomic_fetch_add_explicit(&_hitVTSuccess, 1, memory_order_relaxed);
        return YES;
    } else {
        atomic_fetch_add_explicit(&_hitVTFail, 1, memory_order_relaxed);
        return NO;
    }
}

@end
