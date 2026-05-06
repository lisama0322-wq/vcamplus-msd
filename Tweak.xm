// vcamplus-msd: mediaserverd-side virtual camera frame replacement.
//
// Hooks `-[BWNodeOutput emitSampleBuffer:]` (and the photo-path subclasses) on
// Apple's private CMCapture pipeline. Every camera frame in the system funnels
// through emitSampleBuffer: before crossing XPC to consumers, so a single
// swizzle covers all apps — including ones that block dylib injection (X,
// Google Translate, Bitget WKWebView KYC, etc).
//
// Architecture mirrors vcam124. Implemented in pure ObjC runtime calls (no
// Logos directives) for parity with the main vcamplus dylib.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

#import "VCamCore.h"

typedef void (*EmitFn)(id, SEL, CMSampleBufferRef);

static EmitFn gOrigBWNodeOutput        = NULL;
static EmitFn gOrigBWStillImageScaler  = NULL;
static EmitFn gOrigBWPhotoEncoder      = NULL;

static void hooked_emit(id _self, SEL sel, CMSampleBufferRef sb, EmitFn orig) {
    @try {
        if (sb && [VCamCore.shared isEnabled]) {
            CMSampleBufferRef rep = [VCamCore.shared replaceSampleBuffer:sb];
            if (rep) {
                if (orig) orig(_self, sel, rep);
                CFRelease(rep);
                return;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[vcam-msd] hook exception: %@", e);
    }
    if (orig) orig(_self, sel, sb);
}

static void install_hook(const char *className, EmitFn *origSlot) {
    Class cls = objc_getClass(className);
    if (!cls) {
        NSLog(@"[vcam-msd] class %s not found — skipping", className);
        return;
    }
    SEL sel = @selector(emitSampleBuffer:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[vcam-msd] %s has no -emitSampleBuffer: — skipping", className);
        return;
    }

    IMP newImp = imp_implementationWithBlock(^(id _self, CMSampleBufferRef sb) {
        hooked_emit(_self, sel, sb, *origSlot);
    });

    IMP origImp = NULL;
    @try { MSHookMessageEx(cls, sel, newImp, &origImp); } @catch (NSException *e) {}

    if (origImp) {
        *origSlot = (EmitFn)origImp;
        NSLog(@"[vcam-msd] hooked -[%s emitSampleBuffer:] via MSHookMessageEx", className);
    } else {
        // Fallback: classic method_setImplementation. Less safe under tamper
        // detection but always succeeds when MSHookMessageEx isn't available.
        *origSlot = (EmitFn)method_getImplementation(m);
        method_setImplementation(m, newImp);
        NSLog(@"[vcam-msd] hooked -[%s emitSampleBuffer:] via method_setImplementation", className);
    }
}

__attribute__((constructor))
static void vcamplus_msd_init(void) {
    @autoreleasepool {
        NSString *proc = NSProcessInfo.processInfo.processName;
        if (![proc isEqualToString:@"mediaserverd"]) {
            // Filter plist should keep us out of other procs, but belt + braces.
            return;
        }
        NSLog(@"[vcam-msd] LOADED in mediaserverd (build 0.1.0)");

        // Kick the singleton early so the player is ready to start the moment
        // vcam.mp4 appears at /var/mobile/Media/DCIM/.
        (void)[VCamCore shared];

        install_hook("BWNodeOutput",          &gOrigBWNodeOutput);
        install_hook("BWStillImageScalerNode", &gOrigBWStillImageScaler);
        install_hook("BWPhotoEncoderNode",     &gOrigBWPhotoEncoder);
    }
}
