#import "VCamCore.h"
#import "LocalVideoPlayer.h"
#import "GPUImageProcessor.h"

#import <mach/mach_time.h>
#import <sys/stat.h>

static NSString *const kVCamSourceVideo = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kVCamStatsFile   = @"/var/mobile/Media/DCIM/vcam_msd_stats.txt";

static const uint64_t kEnabledCacheTTLNs = 200ULL * NSEC_PER_MSEC;

// Lossy-compressed pixel formats. VTPixelTransferSession cannot write to these
// destinations — the underlying IOSurface stores compressed tiles, not raw
// pixels. Attempting to transfer either fails silently or corrupts the buffer.
// Detected on iPhone 14/15 Pro system Camera high-res preview path.
static BOOL vcam_isLossyDestination(OSType fmt) {
    switch (fmt) {
        case 0x2D387630:  // '-8v0' Lossy 420 video range
        case 0x2D386630:  // '-8f0' Lossy 420 full range
        case 0x2D787630:  // '-xv0' Lossy 10-bit 420 video range
        case 0x2D786630:  // '-xf0' Lossy 10-bit 420 full range
        case 0x2D343230:  // '-420' generic lossy
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

    // Diagnostic counters (atomic via dispatch_queue or just int32 increments).
    // Camera frames hit at ~1000/s so plain int32 reads can race but are good
    // enough for diagnostic dumps.
    uint64_t _hitTotal;
    uint64_t _hitNonVideo;
    uint64_t _hitNoPB;
    uint64_t _hitLossyDst;
    uint64_t _hitNoSrc;
    uint64_t _hitVTAttempt;
    uint64_t _hitVTSuccess;
    uint64_t _hitVTFail;
    OSStatus _lastVTStatus;

    NSMutableDictionary<NSString *, NSNumber *> *_uniqueShapes;  // dim+fmt -> count
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
        _videoPlayer = [[LocalVideoPlayer alloc] initWithPath:kVCamSourceVideo];
        _uniqueShapes = [NSMutableDictionary new];

        // Periodic stats dump for offline diagnosis.
        dispatch_queue_t q = dispatch_queue_create("com.vcamplus.msd.stats", DISPATCH_QUEUE_SERIAL);
        _statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(_statsTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_statsTimer, ^{ [weakSelf dumpStats]; });
        dispatch_resume(_statsTimer);
    }
    return self;
}

- (void)dumpStats {
    NSMutableString *s = [NSMutableString new];
    [s appendFormat:@"=== vcam-msd stats @ %@ ===\n",
        [NSDateFormatter localizedStringFromDate:NSDate.date
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle]];
    [s appendFormat:@"playerStarted: %d  enabled: %d  lastVTStatus: %d\n",
        _playerStarted, _enabledCached, (int)_lastVTStatus];
    [s appendFormat:@"hitTotal: %llu\n", _hitTotal];
    [s appendFormat:@"  nonVideo:    %llu\n", _hitNonVideo];
    [s appendFormat:@"  noPB:        %llu\n", _hitNoPB];
    [s appendFormat:@"  lossyDst:    %llu (skipped — VT would corrupt)\n", _hitLossyDst];
    [s appendFormat:@"  noSrc:       %llu (video player not ready)\n", _hitNoSrc];
    [s appendFormat:@"  vtAttempt:   %llu\n", _hitVTAttempt];
    [s appendFormat:@"  vtSuccess:   %llu\n", _hitVTSuccess];
    [s appendFormat:@"  vtFail:      %llu\n", _hitVTFail];
    [s appendFormat:@"unique shapes:\n"];
    NSArray *keys = [_uniqueShapes.allKeys sortedArrayUsingComparator:^(id a, id b) {
        return [_uniqueShapes[b] compare:_uniqueShapes[a]];
    }];
    for (NSString *k in keys) {
        [s appendFormat:@"  %8@  %@\n", _uniqueShapes[k], k];
    }
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

- (BOOL)replaceInPlace:(CMSampleBufferRef)sb {
    if (!sb) return NO;
    _hitTotal++;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!fmt || CMFormatDescriptionGetMediaType(fmt) != kCMMediaType_Video) {
        _hitNonVideo++;
        return NO;
    }

    CVImageBufferRef dstPB = CMSampleBufferGetImageBuffer(sb);
    if (!dstPB) {
        _hitNoPB++;
        return NO;
    }

    OSType dstFmt = CVPixelBufferGetPixelFormatType(dstPB);
    size_t dstW = CVPixelBufferGetWidth(dstPB);
    size_t dstH = CVPixelBufferGetHeight(dstPB);

    // Track unique shapes so the stats file shows what flowed through.
    char fcc[5] = {0};
    fcc[0] = (dstFmt >> 24) & 0xff; fcc[1] = (dstFmt >> 16) & 0xff;
    fcc[2] = (dstFmt >> 8) & 0xff;  fcc[3] = dstFmt & 0xff;
    NSString *shape = [NSString stringWithFormat:@"%zux%zu '%s' (0x%08x)",
                       dstW, dstH, fcc, (unsigned)dstFmt];
    @synchronized(_uniqueShapes) {
        _uniqueShapes[shape] = @(_uniqueShapes[shape].unsignedLongLongValue + 1);
    }

    if (vcam_isLossyDestination(dstFmt)) {
        _hitLossyDst++;
        return NO;
    }

    CVPixelBufferRef srcFrame = [_videoPlayer latestFrameRetained];
    if (!srcFrame) {
        _hitNoSrc++;
        return NO;
    }

    _hitVTAttempt++;
    OSStatus st = [_gpuProcessor transferFromStatus:srcFrame into:dstPB];
    CFRelease(srcFrame);
    _lastVTStatus = st;
    if (st == noErr) {
        _hitVTSuccess++;
        return YES;
    } else {
        _hitVTFail++;
        return NO;
    }
}

@end
