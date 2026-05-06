// vcamplus-msd: mediaserverd-side virtual camera frame replacement.
//
// Architecture mirrors vcam124 (analyzed via static reverse engineering of
// vcameracrack.dylib):
//
// - Hook -[BWNodeOutput emitSampleBuffer:] (Apple's private CMCapture pipeline
//   producer-side selector through which every camera frame in the system
//   funnels before crossing XPC to consumers).
// - Filter to mediaType == kCMMediaType_Video so audio + metadata buffers pass
//   through untouched.
// - Mutate the original CVPixelBuffer's contents IN PLACE via
//   VTPixelTransferSessionTransferImage. Do NOT create a new sample buffer or
//   pixel buffer — preserves all original IOSurface bindings, attachments,
//   format descriptions, and timing that downstream consumers (system Camera
//   UI, photo encoders) rely on.
//
// Implemented in pure ObjC runtime calls (no Logos directives) for parity with
// the main vcamplus dylib.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

#import "VCamCore.h"

typedef void (*EmitFn)(id, SEL, CMSampleBufferRef);
static EmitFn gOrigBWNodeOutputEmit = NULL;

static void hooked_emit(id _self, SEL sel, CMSampleBufferRef sb) {
    @try {
        if (sb && [VCamCore.shared isEnabled]) {
            [VCamCore.shared replaceInPlace:sb];
        }
    } @catch (NSException *e) {
        NSLog(@"[vcam-msd] emit hook exception: %@", e);
    }
    if (gOrigBWNodeOutputEmit) gOrigBWNodeOutputEmit(_self, sel, sb);
}

static void install_emit_hook(void) {
    Class cls = objc_getClass("BWNodeOutput");
    if (!cls) {
        NSLog(@"[vcam-msd] BWNodeOutput not found — skipping emit hook");
        return;
    }
    SEL sel = @selector(emitSampleBuffer:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[vcam-msd] BWNodeOutput has no -emitSampleBuffer:");
        return;
    }
    IMP newImp = imp_implementationWithBlock(^(id _self, CMSampleBufferRef sb) {
        hooked_emit(_self, @selector(emitSampleBuffer:), sb);
    });
    IMP origImp = NULL;
    @try { MSHookMessageEx(cls, sel, newImp, &origImp); } @catch (NSException *e) {}
    if (origImp) {
        gOrigBWNodeOutputEmit = (EmitFn)origImp;
        NSLog(@"[vcam-msd] hooked -[BWNodeOutput emitSampleBuffer:] via MSHookMessageEx");
    } else {
        gOrigBWNodeOutputEmit = (EmitFn)method_getImplementation(m);
        method_setImplementation(m, newImp);
        NSLog(@"[vcam-msd] hooked -[BWNodeOutput emitSampleBuffer:] via method_setImplementation");
    }
}

__attribute__((constructor))
static void vcamplus_msd_init(void) {
    @autoreleasepool {
        NSString *proc = NSProcessInfo.processInfo.processName;
        if (![proc isEqualToString:@"mediaserverd"]) return;
        NSLog(@"[vcam-msd] LOADED in mediaserverd (build 0.3.0, in-place transfer)");
        (void)[VCamCore shared];
        install_emit_hook();
        // BWStillImageScalerNode / BWPhotoEncoderNode use selector
        // -renderSampleBuffer:forInput: per vcam124 reverse engineering.
        // Photo path replacement deferred to a later build; the emit hook
        // above already replaces preview + video, which is the bulk of camera
        // traffic.
    }
}
