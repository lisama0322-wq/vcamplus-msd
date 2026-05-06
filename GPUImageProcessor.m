#import "GPUImageProcessor.h"
#import <VideoToolbox/VideoToolbox.h>

@implementation GPUImageProcessor {
    VTPixelTransferSessionRef _session;
    NSMutableDictionary<NSString *, id> *_pools;  // values bridged from CVPixelBufferPoolRef
    NSLock *_lock;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pools = [NSMutableDictionary new];
        _lock = [NSLock new];
        OSStatus s = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_session);
        if (s != noErr) {
            NSLog(@"[vcam-msd] VTPixelTransferSessionCreate failed: %d", (int)s);
            _session = NULL;
        }
    }
    return self;
}

- (void)dealloc {
    if (_session) {
        VTPixelTransferSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    // _pools (NSDictionary) releases its bridged CF values automatically.
}

- (CVPixelBufferPoolRef)poolForFormat:(OSType)format width:(size_t)width height:(size_t)height {
    NSString *key = [NSString stringWithFormat:@"%u-%zu-%zu", (unsigned)format, width, height];
    [_lock lock];
    CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)_pools[key];
    if (pool) {
        [_lock unlock];
        return pool;
    }
    NSDictionary *poolAttrs = @{
        (NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *pixelAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(format),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferPoolRef newPool = NULL;
    CVReturn r = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                         (__bridge CFDictionaryRef)poolAttrs,
                                         (__bridge CFDictionaryRef)pixelAttrs,
                                         &newPool);
    if (r != kCVReturnSuccess || !newPool) {
        [_lock unlock];
        NSLog(@"[vcam-msd] pool create failed (fmt=%u %zux%zu): %d",
              (unsigned)format, width, height, r);
        return NULL;
    }
    _pools[key] = (__bridge id)newPool;
    CFRelease(newPool);  // dict holds the +1 reference
    [_lock unlock];
    return newPool;
}

- (CVPixelBufferRef)convertPixelBuffer:(CVPixelBufferRef)src
                              toFormat:(OSType)format
                                 width:(size_t)width
                                height:(size_t)height {
    if (!src || !_session) return NULL;

    CVPixelBufferPoolRef pool = [self poolForFormat:format width:width height:height];
    if (!pool) return NULL;

    CVPixelBufferRef dst = NULL;
    CVReturn r = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst);
    if (r != kCVReturnSuccess || !dst) return NULL;

    OSStatus s = VTPixelTransferSessionTransferImage(_session, src, dst);
    if (s != noErr) {
        NSLog(@"[vcam-msd] VTPixelTransferSessionTransferImage failed: %d", (int)s);
        CFRelease(dst);
        return NULL;
    }
    return dst;
}

@end
