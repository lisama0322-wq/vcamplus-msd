#import "VCamCore.h"
#import "LocalVideoPlayer.h"
#import "GPUImageProcessor.h"

#import <mach/mach_time.h>
#import <sys/stat.h>
#import <stdatomic.h>

static NSString *const kVCamSourceVideo = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kVCamActiveFlag  = @"/var/mobile/Media/DCIM/vcam_msd_active";
static NSString *const kVCamStatsFile   = @"/var/mobile/Media/DCIM/vcam_msd_stats.txt";

// Hard isolation gate: hook is installed unconditionally but does nothing
// unless BOTH source video AND active flag exist. Touch the flag file to
// enable, delete to disable.
static const uint64_t kEnabledCacheTTLNs = 500ULL * NSEC_PER_MSEC;

static inline BOOL vcam_isLossyDestination(OSType fmt) {
    switch (fmt) {
        case 0x2D387630:  // '-8v0' Lossy 420 video range
        case 0x2D386630:  // '-8f0' Lossy 420 full range
        case 0x2D787630:  // '-xv0' Lossy 10-bit 420 video range
        case 0x2D786630:  // '-xf0' Lossy 10-bit 420 full range
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
    mach_timebase_info_data_t _tb;

    _Atomic uint64_t _hitTotal;
    _Atomic uint64_t _hitNonVideo;
    _Atomic uint64_t _hitNoPB;
    _Atomic uint64_t _hitLossyDst;
    _Atomic uint64_t _hitNoSrc;
    _Atomic uint64_t _hitAlreadyConsumed;  // skipped because srcID already used
    _Atomic uint64_t _hitVTAttempt;
    _Atomic uint64_t _hitVTSuccess;
    _Atomic uint64_t _hitVTFail;
    _Atomic uint32_t _lastDstFmt;
    _Atomic uint32_t _lastDstW;
    _Atomic uint32_t _lastDstH;

    // Throttle replacement to source frame rate (matches vcam124's
    // hasReplacementFrame gate that consumes liveBGRASampleBuffer once per
    // decoded frame). frida measurement of vcam124 during Camera recording:
    // 749 emit/sec, 145 VT/sec — vcam124 skips ~80% of emits via this gate.
    _Atomic uint64_t _lastConsumedSrcID;

    dispatch_source_t _statsTimer;
}

+ (instancetype)shared {
    static VCamCore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamCore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        mach_timebase_info(&_tb);
        _gpuProcessor = [GPUImageProcessor new];
        _videoPlayer  = [[LocalVideoPlayer alloc] initWithPath:kVCamSourceVideo];

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

    uint64_t vtCount = [_gpuProcessor vtCallCount];
    uint64_t vtTotalNs = [_gpuProcessor vtTotalNs];
    uint64_t vtMaxNs = [_gpuProcessor vtMaxNs];
    double vtMeanUs = vtCount > 0 ? (double)vtTotalNs / vtCount / 1000.0 : 0.0;
    double vtMaxUs = vtMaxNs / 1000.0;
    uint64_t cacheHits = [_gpuProcessor cacheHitCount];
    uint64_t cacheRebuilds = [_gpuProcessor cacheRebuildCount];
    uint64_t cacheRebuildNs = [_gpuProcessor cacheRebuildTotalNs];
    double rebuildMeanUs = cacheRebuilds > 0 ? (double)cacheRebuildNs / cacheRebuilds / 1000.0 : 0.0;
    double cacheHitRate = (cacheHits + cacheRebuilds) > 0
        ? 100.0 * cacheHits / (cacheHits + cacheRebuilds) : 0.0;

    NSMutableString *s = [NSMutableString stringWithCapacity:1024];
    [s appendFormat:@"=== vcam-msd v0.7 stats @ %@ ===\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle]];
    [s appendFormat:@"playerStarted=%d enabled=%d\n", _playerStarted, _enabledCached];
    [s appendFormat:@"lastDst=%ux%u '%s' (0x%08x)\n", w, h, fcc, fmt];
    [s appendFormat:@"\n--- emit hit breakdown ---\n"];
    [s appendFormat:@"hitTotal:        %llu\n", atomic_load(&_hitTotal)];
    [s appendFormat:@"  nonVideo:      %llu\n", atomic_load(&_hitNonVideo)];
    [s appendFormat:@"  noPB:          %llu\n", atomic_load(&_hitNoPB)];
    [s appendFormat:@"  lossyDst:      %llu\n", atomic_load(&_hitLossyDst)];
    [s appendFormat:@"  alreadyDone:   %llu  (srcID throttle: src frame already consumed)\n",
        atomic_load(&_hitAlreadyConsumed)];
    [s appendFormat:@"  noSrc:         %llu\n", atomic_load(&_hitNoSrc)];
    [s appendFormat:@"  vtAttempt:     %llu\n", atomic_load(&_hitVTAttempt)];
    [s appendFormat:@"  vtSuccess:     %llu\n", atomic_load(&_hitVTSuccess)];
    [s appendFormat:@"  vtFail:        %llu\n", atomic_load(&_hitVTFail)];
    [s appendFormat:@"\n--- VT latency (P0+cache: RealTime + CropMode + cached transfer) ---\n"];
    [s appendFormat:@"vtCount:        %llu  (every emit that called transferFrom)\n", vtCount];
    [s appendFormat:@"vtMeanUs:       %.1f µs  (overall, mixing fast and slow path)\n", vtMeanUs];
    [s appendFormat:@"vtMaxUs:        %.1f µs\n", vtMaxUs];
    [s appendFormat:@"cacheHits:      %llu  (fast path = cached → dst, hardware blit)\n", cacheHits];
    [s appendFormat:@"cacheRebuilds:  %llu  (slow path = src → cached, scale+rotate+convert)\n", cacheRebuilds];
    [s appendFormat:@"cacheHitRate:   %.1f%%\n", cacheHitRate];
    [s appendFormat:@"rebuildMeanUs:  %.1f µs  (per slow-path call; expect ~2000µs first-time)\n", rebuildMeanUs];

    // Install diagnostics — declared as extern in Tweak.xm
    extern _Atomic int gInstallPollCount;
    extern _Atomic int gInstallState;
    extern _Atomic int gInstallHookKind;
    extern _Atomic int gInstallSubclassHits;
    extern _Atomic int gFirstClassReachedHook;
    [s appendFormat:@"\n--- hook install diagnostics ---\n"];
    [s appendFormat:@"installPollCount:    %d\n", atomic_load(&gInstallPollCount)];
    [s appendFormat:@"installState:        %d  (0=class missing, 1=class found, 2=no class owns method, 3=hooked OK)\n",
        atomic_load(&gInstallState)];
    [s appendFormat:@"installHookKind:     %d  (0=not yet, 1=MSHookMessageEx, 2=method_setImplementation)\n",
        atomic_load(&gInstallHookKind)];
    [s appendFormat:@"installSubclassHits: %d  (total emit-implementing classes hooked)\n",
        atomic_load(&gInstallSubclassHits)];
    [s appendFormat:@"emitHookEverFired:   %d  (1 if any hooked class's emit was actually called)\n",
        atomic_load(&gFirstClassReachedHook)];
    [s writeToFile:kVCamStatsFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)isEnabled {
    uint64_t now = mach_absolute_time();
    uint64_t nowNs = now * _tb.numer / _tb.denom;
    if (nowNs - _enabledCacheTime < kEnabledCacheTTLNs) return _enabledCached;

    struct stat st;
    BOOL videoOK  = (stat([kVCamSourceVideo fileSystemRepresentation], &st) == 0 && st.st_size > 0);
    BOOL activeOK = (stat([kVCamActiveFlag  fileSystemRepresentation], &st) == 0);
    BOOL enabled  = videoOK && activeOK;

    if (videoOK && !_playerStarted) {
        [_videoPlayer start];
        _playerStarted = YES;
        NSLog(@"[vcam-msd] video source present -> player started");
    } else if (!videoOK && _playerStarted) {
        [_videoPlayer stop];
        _playerStarted = NO;
        NSLog(@"[vcam-msd] video source gone -> player stopped");
    }

    _enabledCached = enabled;
    _enabledCacheTime = nowNs;
    return enabled;
}

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

    // CRITICAL throttle (vcam124-style): skip replacement when this src frame
    // was already consumed by a previous emit. Caps replacement rate at source
    // frame rate (~30/s) regardless of mediaserverd emit rate (which can hit
    // 800+/s for the system Camera app and would otherwise saturate CPU).
    uint64_t srcID = [_videoPlayer latestFrameID];
    uint64_t lastID = atomic_load_explicit(&_lastConsumedSrcID, memory_order_acquire);
    if (srcID == 0 || srcID == lastID) {
        atomic_fetch_add_explicit(&_hitAlreadyConsumed, 1, memory_order_relaxed);
        return NO;
    }

    CVPixelBufferRef srcFrame = [_videoPlayer latestFrameRetained];
    if (!srcFrame) {
        atomic_fetch_add_explicit(&_hitNoSrc, 1, memory_order_relaxed);
        return NO;
    }

    atomic_fetch_add_explicit(&_hitVTAttempt, 1, memory_order_relaxed);
    BOOL ok = [_gpuProcessor transferFrom:srcFrame srcID:srcID into:dstPB];
    CFRelease(srcFrame);
    if (ok) {
        // Mark this src frame as consumed; subsequent emits with same srcID
        // will skip until LocalVideoPlayer produces a new frame.
        atomic_store_explicit(&_lastConsumedSrcID, srcID, memory_order_release);
    }
    if (ok) {
        atomic_fetch_add_explicit(&_hitVTSuccess, 1, memory_order_relaxed);
        return YES;
    } else {
        atomic_fetch_add_explicit(&_hitVTFail, 1, memory_order_relaxed);
        return NO;
    }
}

@end
