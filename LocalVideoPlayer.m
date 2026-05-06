#import "LocalVideoPlayer.h"
#import <AVFoundation/AVFoundation.h>

// Target ~30fps decode pacing. The actual mediaserverd consumer rate may differ;
// we just keep latestFrame fresh enough for the consumer to pick up.
static const NSTimeInterval kFrameInterval = 1.0 / 30.0;

@implementation LocalVideoPlayer {
    NSString *_path;
    dispatch_queue_t _queue;
    NSLock *_frameLock;
    CVPixelBufferRef _latestFrame;
    BOOL _running;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _queue = dispatch_queue_create("com.vcamplus.msd.decoder", DISPATCH_QUEUE_SERIAL);
        _frameLock = [NSLock new];
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
    [_frameLock lock];
    if (_latestFrame) { CFRelease(_latestFrame); _latestFrame = NULL; }
    [_frameLock unlock];
}

- (CVPixelBufferRef)latestFrameRetained {
    [_frameLock lock];
    CVPixelBufferRef pb = _latestFrame;
    if (pb) CFRetain(pb);
    [_frameLock unlock];
    return pb;
}

#pragma mark - Decoder loop

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

        if (!_reader || _reader.status != AVAssetReaderStatusReading) {
            _reader = nil; _output = nil;
            if (![self openReader]) {
                // File missing or unreadable — back off and retry. The supervisor
                // (VCamCore.isEnabled) will call stop() when the file goes away.
                [NSThread sleepForTimeInterval:0.5];
                continue;
            }
        }

        CMSampleBufferRef sb = [_output copyNextSampleBuffer];
        if (!sb) {
            // End of stream — recreate reader to loop the video.
            [_reader cancelReading];
            _reader = nil; _output = nil;
            continue;
        }
        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (pb) {
            CFRetain(pb);
            [_frameLock lock];
            CVPixelBufferRef old = _latestFrame;
            _latestFrame = pb;
            [_frameLock unlock];
            if (old) CFRelease(old);
        }
        CFRelease(sb);

        [NSThread sleepForTimeInterval:kFrameInterval];
    }
    NSLog(@"[vcam-msd] decoder loop exiting");
}

@end
