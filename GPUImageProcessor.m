#import "GPUImageProcessor.h"
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>
#import <stdatomic.h>

@implementation GPUImageProcessor {
    VTPixelTransferSessionRef _session;
    NSRecursiveLock *_lock;     // matches vcam124's NSRecursiveLock at VCamCore.[0x18]
    mach_timebase_info_data_t _tb;

    _Atomic uint64_t _vtCount;
    _Atomic uint64_t _vtTotalNs;
    _Atomic uint64_t _vtMaxNs;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSRecursiveLock new];
        mach_timebase_info(&_tb);
        OSStatus s = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_session);
        if (s != noErr || !_session) {
            NSLog(@"[vcam-msd] VTPixelTransferSessionCreate failed: %d", (int)s);
            _session = NULL;
            return self;
        }

        // P0 fix #1 — RealTime hint. Tells VT this is a camera/realtime pipeline
        // so it picks the fastest hardware blit path over high-quality slow path.
        // vcam124 sets this at 0x1e764. Without it, single-call latency is 5-10×
        // higher.
        OSStatus s1 = VTSessionSetProperty(_session,
            kVTPixelTransferPropertyKey_RealTime,
            kCFBooleanTrue);

        // P0 fix #2 — CropSourceToCleanAperture scaling. Fastest scaling mode
        // available to VT — does aspect-preserving crop instead of bilinear
        // resample. vcam124 uses this at 0x1e74c. v0.4 used kVTScalingMode_Normal
        // which is bilinear stretch — slower and aspect-distorting.
        OSStatus s2 = VTSessionSetProperty(_session,
            kVTPixelTransferPropertyKey_ScalingMode,
            kVTScalingMode_CropSourceToCleanAperture);

        NSLog(@"[vcam-msd] VT session configured: RealTime=%d CropMode=%d",
              (int)s1, (int)s2);
    }
    return self;
}

- (void)dealloc {
    if (_session) {
        VTPixelTransferSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
}

- (BOOL)transferFrom:(CVPixelBufferRef)src into:(CVPixelBufferRef)dst {
    if (!src || !dst || !_session) return NO;

    uint64_t t0 = mach_absolute_time();

    [_lock lock];
    OSStatus s = VTPixelTransferSessionTransferImage(_session, src, dst);
    [_lock unlock];

    uint64_t t1 = mach_absolute_time();
    uint64_t dtNs = (t1 - t0) * _tb.numer / _tb.denom;
    atomic_fetch_add_explicit(&_vtCount,   1,    memory_order_relaxed);
    atomic_fetch_add_explicit(&_vtTotalNs, dtNs, memory_order_relaxed);
    uint64_t prevMax = atomic_load_explicit(&_vtMaxNs, memory_order_relaxed);
    while (dtNs > prevMax &&
           !atomic_compare_exchange_weak_explicit(&_vtMaxNs, &prevMax, dtNs,
               memory_order_relaxed, memory_order_relaxed)) {
    }

    return (s == noErr);
}

- (uint64_t)vtCallCount { return atomic_load_explicit(&_vtCount,   memory_order_relaxed); }
- (uint64_t)vtTotalNs   { return atomic_load_explicit(&_vtTotalNs, memory_order_relaxed); }
- (uint64_t)vtMaxNs     { return atomic_load_explicit(&_vtMaxNs,   memory_order_relaxed); }

@end
