#import "GPUImageProcessor.h"
#import <VideoToolbox/VideoToolbox.h>

@implementation GPUImageProcessor {
    VTPixelTransferSessionRef _session;
    NSLock *_lock;
}

- (instancetype)init {
    if ((self = [super init])) {
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
}

- (BOOL)transferFrom:(CVPixelBufferRef)src into:(CVPixelBufferRef)dst {
    if (!src || !dst || !_session) return NO;
    [_lock lock];
    OSStatus s = VTPixelTransferSessionTransferImage(_session, src, dst);
    [_lock unlock];
    return (s == noErr);
}

@end
