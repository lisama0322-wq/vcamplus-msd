# vcamplus-msd

mediaserverd-side virtual camera frame replacement for iOS Dopamine rootless.
Companion tweak to the main `vcamplus` dylib.

## Why a separate tweak

The main `vcamplus.dylib` injects into UIKit / WebKit consumer apps to swizzle
`AVCaptureVideoDataOutput` and friends. That covers ~70% of camera flows but
leaves three classes of app uncovered:

1. **App Store hardened apps** that block dylib injection (X, Google Translate)
2. **WKWebView KYC pages** where iOS pixel paths (display vs JS readback vs
   `MediaStreamTrack`) diverge and only the display path gets replaced
3. **Custom GPU pipelines** (ARKit, Metal, CIImage) that bypass AVF

`vcamplus-msd` injects only into `mediaserverd` and swizzles
`-[BWNodeOutput emitSampleBuffer:]` on Apple's private CMCapture pipeline.
Every camera frame in the system passes through that selector before being
delivered to any consumer over XPC, so all three classes above are covered
automatically.

## Architecture

| Class | Responsibility |
|---|---|
| `VCamCore` (singleton) | State holder; orchestrates per-frame replacement |
| `LocalVideoPlayer` | AVAssetReader-driven background decoder; loops `vcam.mp4` |
| `GPUImageProcessor` | VTPixelTransferSession-backed format/scale conversion + CVPixelBufferPool cache |
| `Tweak.xm` | Constructor that installs the three swizzles via MSHookMessageEx |

## Source video path

`/var/mobile/Media/DCIM/vcam.mp4`

DCIM is mediaserverd-accessible without RootHide jbroot path patching, which
the main vcamplus has to deal with. Drop a video at that path to enable.
Remove the file to disable. (Cached 200 ms so the file stat overhead is
negligible on the 1000+/sec emit hot path.)

## Filter

Injects into `mediaserverd` only. Does not touch SpringBoard, UI processes, or
WebContent.

## Co-existence with main vcamplus

Both can run at the same time. Main vcamplus handles the fine-grained controls
(rotation, flip, offset, multi-source switching, web JS canvas) for apps it
can inject into. vcamplus-msd handles the global frame-source replacement for
everything else.
