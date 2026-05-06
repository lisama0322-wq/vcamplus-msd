// vcamplus-msd: mediaserverd-side virtual camera frame replacement.
//
// Architecture mirrors vcam124. Key correctness invariants on the hot path
// (BWNodeOutput emitSampleBuffer: fires ~1000-3000 times/sec):
//
//   1. Wrap the entire hook in @autoreleasepool. mediaserverd's calling
//      thread does NOT drain the outer pool between emits, so any
//      autoreleased object accumulates until the system OOMs / watchdogs.
//      vcam124 does this via objc_autoreleasePoolPush at the top of its
//      hook IMP — same idea.
//   2. Hot path must NOT allocate ObjC objects. No NSString format, no
//      NSDictionary writes, no @synchronized(NSDictionary). Everything
//      is _Atomic counters or sub-microsecond os_unfair_lock.
//   3. Mutate the original CVPixelBuffer in place via VT. Do NOT create a
//      new sample buffer — system Camera UI tracks the original IOSurface
//      and bindings, replacing them produces a black screen + crash on
//      shutter press.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

#import "VCamCore.h"

typedef void (*EmitFn)(id, SEL, CMSampleBufferRef);
static EmitFn gOrigBWNodeOutputEmit = NULL;

static void hooked_emit(id _self, SEL sel, CMSampleBufferRef sb) {
    @autoreleasepool {
        @try {
            if (sb && [VCamCore.shared isEnabled]) {
                [VCamCore.shared replaceInPlace:sb];
            }
        } @catch (NSException *e) {
            NSLog(@"[vcam-msd] emit hook exception: %@", e);
        }
    }
    if (gOrigBWNodeOutputEmit) gOrigBWNodeOutputEmit(_self, sel, sb);
}

static void install_emit_hook(void) {
    Class cls = objc_getClass("BWNodeOutput");
    if (!cls) {
        NSLog(@"[vcam-msd] BWNodeOutput not found — skipping");
        return;
    }
    SEL sel = @selector(emitSampleBuffer:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

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
        NSLog(@"[vcam-msd] LOADED in mediaserverd (build 0.6.0, hard-gated)");
        NSLog(@"[vcam-msd] To activate: touch /var/mobile/Media/DCIM/vcam_msd_active");
        NSLog(@"[vcam-msd] To deactivate: rm /var/mobile/Media/DCIM/vcam_msd_active");
        (void)[VCamCore shared];
        install_emit_hook();
    }
}
