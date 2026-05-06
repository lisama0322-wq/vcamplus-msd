// vcamplus-msd: mediaserverd-side virtual camera frame replacement.
//
// CMCapture framework (which owns BWNodeOutput) is lazy-loaded by
// mediaserverd — it doesn't appear until a camera client first opens a
// session. Our __attribute__((constructor)) runs at dylib load time, well
// before CMCapture is loaded, so a one-shot objc_getClass("BWNodeOutput")
// returns NULL and the hook never gets installed.
//
// Use _dyld_register_func_for_add_image to retry hook installation every
// time a new image (framework) loads. Once BWNodeOutput becomes available,
// dispatch_once gates the actual install so it runs exactly once.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/dyld.h>

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

static void do_install(void) {
    Class cls = objc_getClass("BWNodeOutput");
    if (!cls) return;
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

static void try_install(void) {
    static dispatch_once_t once;
    if (objc_getClass("BWNodeOutput")) {
        dispatch_once(&once, ^{ do_install(); });
    }
}

static void on_image_loaded(const struct mach_header *mh, intptr_t slide) {
    try_install();
}

__attribute__((constructor))
static void vcamplus_msd_init(void) {
    @autoreleasepool {
        NSString *proc = NSProcessInfo.processInfo.processName;
        if (![proc isEqualToString:@"mediaserverd"]) return;
        NSLog(@"[vcam-msd] LOADED in mediaserverd (build 0.7.3, deferred hook install)");
        NSLog(@"[vcam-msd] To activate: touch /var/mobile/Media/DCIM/vcam_msd_active");
        NSLog(@"[vcam-msd] Stats: /var/mobile/Media/DCIM/vcam_msd_stats.txt (every 5s)");
        (void)[VCamCore shared];
        // Try once now in case CMCapture is already loaded.
        try_install();
        // And register a callback so we retry as new frameworks load.
        _dyld_register_func_for_add_image(on_image_loaded);
    }
}
