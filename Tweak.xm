// vcamplus-msd: mediaserverd-side virtual camera frame replacement.
//
// CMCapture framework (which owns BWNodeOutput) is lazy-loaded by mediaserverd
// on first camera-client connect. Our __attribute__((constructor)) runs at
// dylib load — long before any camera session — so objc_getClass("BWNodeOutput")
// returns NULL and a one-shot install never runs.
//
// v0.7.3 tried _dyld_register_func_for_add_image but the callback fires from
// dyld BEFORE the loaded image's objc_init registers its classes, so the class
// lookup still misses.
//
// v0.7.4 polls every 500ms on a background queue until BWNodeOutput becomes
// resolvable, then installs the hook and cancels the timer. Adds at most ~0.5s
// latency between camera launch and hook activation, well within human
// perception.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

#import "VCamCore.h"

typedef void (*EmitFn)(id, SEL, CMSampleBufferRef);
static EmitFn gOrigBWNodeOutputEmit = NULL;
static dispatch_source_t gInstallTimer = NULL;

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

static BOOL try_install(void) {
    Class cls = objc_getClass("BWNodeOutput");
    if (!cls) return NO;
    SEL sel = @selector(emitSampleBuffer:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

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
    return YES;
}

__attribute__((constructor))
static void vcamplus_msd_init(void) {
    @autoreleasepool {
        NSString *proc = NSProcessInfo.processInfo.processName;
        if (![proc isEqualToString:@"mediaserverd"]) return;
        NSLog(@"[vcam-msd] LOADED in mediaserverd (build 0.7.4, polling install)");
        NSLog(@"[vcam-msd] To activate: touch /var/mobile/Media/DCIM/vcam_msd_active");
        NSLog(@"[vcam-msd] Stats: /var/mobile/Media/DCIM/vcam_msd_stats.txt (every 5s)");
        (void)[VCamCore shared];

        // Try once now in case CMCapture is already loaded.
        if (try_install()) return;

        // Otherwise poll until BWNodeOutput appears (CMCapture lazy-loaded on
        // first camera-client connect). Cancel timer once install succeeds.
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
        gInstallTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gInstallTimer,
            dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
            500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gInstallTimer, ^{
            if (try_install()) {
                dispatch_source_cancel(gInstallTimer);
                gInstallTimer = NULL;
            }
        });
        dispatch_resume(gInstallTimer);
        NSLog(@"[vcam-msd] BWNodeOutput not yet loaded — polling every 500ms");
    }
}
