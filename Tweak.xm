// vcamplus-msd: mediaserverd-side virtual camera frame replacement.
//
// CMCapture (which owns BWNodeOutput) is lazy-loaded by mediaserverd on first
// camera-client connect. We must defer hook install until the class becomes
// resolvable.
//
// History of install strategies:
//   v0.7.0  one-shot at constructor → never installs (CMCapture not loaded)
//   v0.7.3  _dyld_register_func_for_add_image → never installs (callback fires
//           before objc_init for new image, so class still NULL)
//   v0.7.4  dispatch_source_t timer @ QOS_BACKGROUND → never installs (timer
//           apparently never fires inside mediaserverd's restricted dispatch
//           environment)
//   v0.7.5  dedicated pthread polling 500ms with explicit diagnostic counters
//           (pollCount, lastClassNullState) exposed via VCamCore stats so we
//           can see exactly which step is failing.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <pthread.h>
#import <unistd.h>
#import <stdatomic.h>

#import "VCamCore.h"

typedef void (*EmitFn)(id, SEL, CMSampleBufferRef);
static EmitFn gOrigBWNodeOutputEmit = NULL;

// Install diagnostics — readable by VCamCore.dumpStats.
_Atomic int gInstallPollCount = 0;
_Atomic int gInstallState     = 0;  // 0=polling no class, 1=class found, 2=method missing, 3=hooked OK
_Atomic int gInstallHookKind  = 0;  // 1=MSHookMessageEx, 2=method_setImplementation

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
    atomic_store_explicit(&gInstallState, 1, memory_order_relaxed);

    SEL sel = @selector(emitSampleBuffer:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        atomic_store_explicit(&gInstallState, 2, memory_order_relaxed);
        return NO;
    }

    IMP newImp = imp_implementationWithBlock(^(id _self, CMSampleBufferRef sb) {
        hooked_emit(_self, @selector(emitSampleBuffer:), sb);
    });
    IMP origImp = NULL;
    @try { MSHookMessageEx(cls, sel, newImp, &origImp); } @catch (NSException *e) {}
    if (origImp) {
        gOrigBWNodeOutputEmit = (EmitFn)origImp;
        atomic_store_explicit(&gInstallHookKind, 1, memory_order_relaxed);
    } else {
        gOrigBWNodeOutputEmit = (EmitFn)method_getImplementation(m);
        method_setImplementation(m, newImp);
        atomic_store_explicit(&gInstallHookKind, 2, memory_order_relaxed);
    }
    atomic_store_explicit(&gInstallState, 3, memory_order_relaxed);
    NSLog(@"[vcam-msd] hooked -[BWNodeOutput emitSampleBuffer:] (kind=%d)",
          atomic_load(&gInstallHookKind));
    return YES;
}

static void *install_thread_main(void *_unused) {
    while (1) {
        atomic_fetch_add_explicit(&gInstallPollCount, 1, memory_order_relaxed);
        if (try_install()) return NULL;
        usleep(500 * 1000);  // 500ms
    }
    return NULL;
}

__attribute__((constructor))
static void vcamplus_msd_init(void) {
    @autoreleasepool {
        NSString *proc = NSProcessInfo.processInfo.processName;
        if (![proc isEqualToString:@"mediaserverd"]) return;
        NSLog(@"[vcam-msd] LOADED in mediaserverd (build 0.7.5, pthread polling install)");
        NSLog(@"[vcam-msd] To activate: touch /var/mobile/Media/DCIM/vcam_msd_active");
        NSLog(@"[vcam-msd] Stats: /var/mobile/Media/DCIM/vcam_msd_stats.txt (every 5s)");
        (void)[VCamCore shared];

        if (try_install()) return;

        // Detached pthread polls indefinitely; exits when install succeeds.
        pthread_t th;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&th, &attr, install_thread_main, NULL);
        pthread_attr_destroy(&attr);
        NSLog(@"[vcam-msd] BWNodeOutput not yet loaded — pthread poller running");
    }
}
