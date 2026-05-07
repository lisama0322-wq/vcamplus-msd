#import "GPUImageProcessor.h"
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <dlfcn.h>

// vcam124 reads kVTPixelTransferPropertyKey_RealTime / kVTScalingMode_*
// indirectly from __DATA_CONST (ldr through GOT). If they aren't exported on
// the running iOS version, that ldr returns NULL and the function skips.
//
// We were calling VTSessionSetProperty with these constants directly. If the
// symbol isn't published as a weak export on iOS 16.5, dyld fails to bind
// and the entire vcamplus-msd.dylib silently fails to load — explaining why
// v0.7 / v0.7.1 produced real-camera output (no dylib in mediaserverd) while
// v0.5 (which never referenced these symbols) did load and replace frames.
//
// Resolve via dlsym at init time. Missing symbol = skip property; dylib still
// loads cleanly.

@implementation GPUImageProcessor {
    VTPixelTransferSessionRef _session;
    NSRecursiveLock *_lock;
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

        // Resolve VT property keys via RTLD_DEFAULT — searches all already-
        // loaded images. Calling VTPixelTransferSessionCreate above implicitly
        // loaded VideoToolbox into our process, so the symbols are reachable.
        // (dlopen("/System/.../VideoToolbox", ...) FAILS on iOS 16+ because
        // frameworks live in dyld shared cache without on-disk binary paths.
        // That was the v0.7.6 bug: handle was NULL → all dlsyms NULL → no
        // properties set → VT defaulted to slow path (2.5ms per call vs
        // ~50µs target).)
        CFStringRef *pRT  = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_RealTime");
        CFStringRef *pSM  = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_ScalingMode");
        CFStringRef *pCrop= (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTScalingMode_CropSourceToCleanAperture");

        if (pRT && *pRT) {
            VTSessionSetProperty(_session, *pRT, kCFBooleanTrue);
        }
        if (pSM && *pSM && pCrop && *pCrop) {
            VTSessionSetProperty(_session, *pSM, *pCrop);
        }
        NSLog(@"[vcam-msd] VT session: RT=%p SM=%p Crop=%p", pRT, pSM, pCrop);
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
    uint64_t prev = atomic_load_explicit(&_vtMaxNs, memory_order_relaxed);
    while (dtNs > prev &&
           !atomic_compare_exchange_weak_explicit(&_vtMaxNs, &prev, dtNs,
               memory_order_relaxed, memory_order_relaxed)) {}
    return (s == noErr);
}

- (uint64_t)vtCallCount { return atomic_load_explicit(&_vtCount,   memory_order_relaxed); }
- (uint64_t)vtTotalNs   { return atomic_load_explicit(&_vtTotalNs, memory_order_relaxed); }
- (uint64_t)vtMaxNs     { return atomic_load_explicit(&_vtMaxNs,   memory_order_relaxed); }

@end
