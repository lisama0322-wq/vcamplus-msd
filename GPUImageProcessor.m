#import "GPUImageProcessor.h"
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <dlfcn.h>
#import <string.h>

// CPU memcpy copy of one CVPixelBuffer's pixel content into another. Both
// must have the same dimensions and format. Handles planar (YUV) and chunky
// (BGRA) layouts.
//
// vcam124's transferPixelBuffer:toPixelBuffer: helper at 0x1ed98 does this
// when its VT session pointer is NULL — and for our use case (cached → dst,
// same geometry/format), CPU memcpy beats VTPixelTransferSessionTransferImage
// in mediaserverd's sandboxed context, where VT apparently can't reach
// Metal/GPU and falls to a slow software path even for trivial copies.
static BOOL vcam_cpuCopyPixelBuffer(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return NO;
    }
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    BOOL planar = CVPixelBufferIsPlanar(src);
    if (!planar) {
        const uint8_t *sp = CVPixelBufferGetBaseAddress(src);
        uint8_t *dp = CVPixelBufferGetBaseAddress(dst);
        size_t ss = CVPixelBufferGetBytesPerRow(src);
        size_t ds = CVPixelBufferGetBytesPerRow(dst);
        size_t h  = CVPixelBufferGetHeight(src);
        size_t copy = ss < ds ? ss : ds;
        if (sp && dp) {
            for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, copy);
        }
    } else {
        size_t np = CVPixelBufferGetPlaneCount(src);
        for (size_t p = 0; p < np; p++) {
            const uint8_t *sp = CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *dp = CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t ss = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t h  = CVPixelBufferGetHeightOfPlane(src, p);
            size_t copy = ss < ds ? ss : ds;
            if (sp && dp) {
                for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, copy);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return YES;
}

@implementation GPUImageProcessor {
    VTPixelTransferSessionRef _session;
    NSRecursiveLock *_lock;
    mach_timebase_info_data_t _tb;

    // Cache of preconverted source: matches current dst geometry.
    CVPixelBufferRef _cached;
    size_t   _cachedW;
    size_t   _cachedH;
    OSType   _cachedFmt;
    uint64_t _cachedSrcID;

    _Atomic uint64_t _vtCount;
    _Atomic uint64_t _vtTotalNs;
    _Atomic uint64_t _vtMaxNs;
    _Atomic uint64_t _cacheHits;
    _Atomic uint64_t _cacheRebuilds;
    _Atomic uint64_t _cacheRebuildTotalNs;
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

        // Resolve VT property keys via RTLD_DEFAULT (iOS 16+ frameworks live
        // in dyld_shared_cache; dlopen by path returns NULL).
        CFStringRef *pRT  = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_RealTime");
        CFStringRef *pSM  = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_ScalingMode");
        CFStringRef *pCrop= (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTScalingMode_CropSourceToCleanAperture");
        if (pRT && *pRT) VTSessionSetProperty(_session, *pRT, kCFBooleanTrue);
        if (pSM && *pSM && pCrop && *pCrop) VTSessionSetProperty(_session, *pSM, *pCrop);
        NSLog(@"[vcam-msd] VT session configured (RT=%p Crop=%p)", pRT, pCrop);
    }
    return self;
}

- (void)dealloc {
    if (_cached) { CFRelease(_cached); _cached = NULL; }
    if (_session) {
        VTPixelTransferSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
}

// Allocate (or reuse) a cached pixel buffer matching the requested geometry.
// Caller holds _lock.
- (BOOL)ensureCacheBufferW:(size_t)w H:(size_t)h fmt:(OSType)fmt {
    if (_cached && _cachedW == w && _cachedH == h && _cachedFmt == fmt) return YES;
    if (_cached) { CFRelease(_cached); _cached = NULL; }
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (NSString *)kCVPixelBufferWidthKey: @(w),
        (NSString *)kCVPixelBufferHeightKey: @(h),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                                     (__bridge CFDictionaryRef)attrs, &pb);
    if (r != kCVReturnSuccess || !pb) {
        NSLog(@"[vcam-msd] cache CVPixelBufferCreate failed: %d (%zux%zu fmt=0x%x)",
              r, w, h, (unsigned)fmt);
        return NO;
    }
    _cached = pb;
    _cachedW = w; _cachedH = h; _cachedFmt = fmt;
    return YES;
}

- (BOOL)transferFrom:(CVPixelBufferRef)src
               srcID:(uint64_t)srcID
                into:(CVPixelBufferRef)dst {
    if (!src || !dst || !_session) return NO;

    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(dst);

    uint64_t t0 = mach_absolute_time();

    [_lock lock];

    BOOL needRebuild = (
        !_cached ||
        _cachedW != dstW || _cachedH != dstH || _cachedFmt != dstFmt ||
        _cachedSrcID != srcID
    );

    OSStatus rebuildStatus = noErr;
    if (needRebuild) {
        if (![self ensureCacheBufferW:dstW H:dstH fmt:dstFmt]) {
            [_lock unlock];
            return NO;
        }
        // SLOW path: scale+rotate+convert src into cached buffer.
        // VT does the geometric transform here. Falls to software path if
        // src/dst orientation/aspect mismatch — but only happens once per
        // source frame per dst geometry, not every emit.
        uint64_t r0 = mach_absolute_time();
        rebuildStatus = VTPixelTransferSessionTransferImage(_session, src, _cached);
        uint64_t r1 = mach_absolute_time();
        if (rebuildStatus == noErr) {
            _cachedSrcID = srcID;
            uint64_t dtNs = (r1 - r0) * _tb.numer / _tb.denom;
            atomic_fetch_add_explicit(&_cacheRebuilds, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&_cacheRebuildTotalNs, dtNs, memory_order_relaxed);
        }
    } else {
        atomic_fetch_add_explicit(&_cacheHits, 1, memory_order_relaxed);
    }

    OSStatus s = noErr;
    if (rebuildStatus == noErr) {
        // FAST path: cached → dst, same dim/fmt/orientation. Use CPU memcpy
        // (CVPixelBufferLockBaseAddress + memcpy + Unlock). VT in
        // mediaserverd's context goes through a software path even for
        // trivial copies (~2.5ms), while this memcpy completes in <1ms for
        // 8MB BGRA / <0.5ms for 3MB YUV.
        s = vcam_cpuCopyPixelBuffer(_cached, dst) ? noErr : -1;
    } else {
        s = rebuildStatus;
    }

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

- (uint64_t)vtCallCount          { return atomic_load_explicit(&_vtCount,            memory_order_relaxed); }
- (uint64_t)vtTotalNs            { return atomic_load_explicit(&_vtTotalNs,          memory_order_relaxed); }
- (uint64_t)vtMaxNs              { return atomic_load_explicit(&_vtMaxNs,            memory_order_relaxed); }
- (uint64_t)cacheHitCount        { return atomic_load_explicit(&_cacheHits,          memory_order_relaxed); }
- (uint64_t)cacheRebuildCount    { return atomic_load_explicit(&_cacheRebuilds,      memory_order_relaxed); }
- (uint64_t)cacheRebuildTotalNs  { return atomic_load_explicit(&_cacheRebuildTotalNs,memory_order_relaxed); }

@end
