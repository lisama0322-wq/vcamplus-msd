#import "LocalVideoPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

static const NSTimeInterval kFrameInterval = 1.0 / 30.0;

@implementation LocalVideoPlayer {
    NSString *_path;
    dispatch_queue_t _queue;
    os_unfair_lock _frameLock;
    CVPixelBufferRef _latestFrame;
    BOOL _running;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _queue = dispatch_queue_create("com.vcamplus.msd.decoder", DISPATCH_QUEUE_SERIAL);
        _frameLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    @synchronized(self) {
        if (_running) return;
        _running = YES;
    }
    dispatch_async(_queue, ^{ [self decodeLoop]; });
}

- (void)stop {
    @synchronized(self) {
        if (!_running) return;
        _running = NO;
    }
    [_reader cancelReading];
    _reader = nil;
    _output = nil;
    os_unfair_lock_lock(&_frameLock);
    if (_latestFrame) { CFRelease(_latestFrame); _latestFrame = NULL; }
    os_unfair_lock_unlock(&_frameLock);
}

// Hot path — called from mediaserverd's emit hook ~1000+ times per second.
// os_unfair_lock with no contention is sub-microsecond. The CFRetain is
// trivial. No allocation.
- (CVPixelBufferRef)latestFrameRetained {
    os_unfair_lock_lock(&_frameLock);
    CVPixelBufferRef pb = _latestFrame;
    if (pb) CFRetain(pb);
    os_unfair_lock_unlock(&_frameLock);
    return pb;
}

- (BOOL)openReader {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:_path]
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return NO;

    NSError *err = nil;
    _reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!_reader || err) {
        NSLog(@"[vcam-msd] AVAssetReader create failed: %@", err);
        return NO;
    }
    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    _output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:settings];
    _output.alwaysCopiesSampleData = NO;
    if (![_reader canAddOutput:_output]) return NO;
    [_reader addOutput:_output];
    if (![_reader startReading]) {
        NSLog(@"[vcam-msd] AVAssetReader startReading failed: %@", _reader.error);
        return NO;
    }
    return YES;
}

- (void)decodeLoop {
    NSLog(@"[vcam-msd] decoder loop starting (path=%@)", _path);
    while (1) {
        BOOL running;
        @synchronized(self) { running = _running; }
        if (!running) break;

        @autoreleasepool {
            if (!_reader || _reader.status != AVAssetReaderStatusReading) {
                _reader = nil; _output = nil;
                if (![self openReader]) {
                    [NSThread sleepForTimeInterval:0.5];
                    continue;
                }
            }

            CMSampleBufferRef sb = [_output copyNextSampleBuffer];
            if (!sb) {
                [_reader cancelReading];
                _reader = nil; _output = nil;
                continue;
            }
            CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
            if (pb) {
                CFRetain(pb);
                os_unfair_lock_lock(&_frameLock);
                CVPixelBufferRef old = _latestFrame;
                _latestFrame = pb;
                os_unfair_lock_unlock(&_frameLock);
                if (old) CFRelease(old);
            }
            CFRelease(sb);
        }

        [NSThread sleepForTimeInterval:kFrameInterval];
    }
    NSLog(@"[vcam-msd] decoder loop exiting");
}

@end
