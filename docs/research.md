# Research notes: PiP over full-screen apps (2026-10-08)

Claims are tagged **[CONFIRMED]** (primary source or source code), **[REPORTED]** (credible third party) or **[SPIKE]** (unverified; needs testing).

## 1. Why Chromium PiP disappears over full-screen apps
- **[CONFIRMED]** `chrome/browser/ui/views/overlay/video_overlay_window_views.cc` creates the PiP window with:
  - `z_order = kFloatingWindow`, which maps to CG level 3;
  - `visible_on_all_workspaces = true`, which only adds `CanJoinAllSpaces`. `NativeWidgetNSWindowBridge::SetWindowLevel` also forces `Managed`.

  `FullScreenAuxiliary` is set only via `SetCanAppearInExistingFullscreenSpaces`, which PiP never calls. Chrome itself is a `.regular` app.
- **[CONFIRMED]** Apple DTS: "macOS doesn't layer regular foreground apps above other apps' full-screen Spaces." https://developer.apple.com/forums/thread/826308
- Known issue, no fix:
  - GoogleChromeLabs PiP extension #57 (open since 2020): https://github.com/GoogleChromeLabs/picture-in-picture-chrome-extension/issues/57
  - Brave Community thread (Jul 2024, no replies)
  - Firefox bugs 1688932 and 1868435 (Firefox has the same bug)
- Safari floats over full-screen apps because it uses the private `PIP.framework` (`PIPViewController`, hosted by `com.apple.PIPAgent`).

## 2. Floating-window recipe
- **[CONFIRMED]** Recipe tested by Apple DTS on macOS 26 (thread 826308):
  - activation policy `.accessory` (or `LSUIElement`);
  - an `NSPanel` with `.nonactivatingPanel`;
  - `isFloatingPanel = true`, `hidesOnDeactivate = false`;
  - level `.screenSaver`;
  - `collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]`;
  - `orderFrontRegardless()`.
- **[REPORTED]** classroom-widgets PR #162 (macOS 26, 2026-09-21): `.nonactivatingPanel` is the decisive setting. With it, even a `.regular` app works, and `.floating` may be enough. Use `.statusBar` or `.screenSaver` to beat Keynote-style in-place full screen.
- **[REPORTED]** macOS 26.3: changing style masks at runtime breaks windows (thread 814798). Create the panel with its final mask.
- Override `canBecomeKey` if the panel needs keyboard input.

## 3. Video sources

**ScreenCaptureKit window/region capture.**
- **[REPORTED]** Chromium stops painting occluded windows or windows on another Space (`MacWebContentsOcclusion`, on by default), so capture shows a repeated frame.
  - Reported by https://github.com/hanbong5938/pip
  - Design doc: https://www.chromium.org/developers/design-documents/mac-occlusion/
- `--disable-backgrounding-occluded-windows` is a launch flag and is unreliable.
- Needs Screen Recording TCC permission, re-prompted monthly on Sequoia.
- DRM content shows black.
- CPU is low: about 17 ms/frame at 60 fps measured on 26.3.

**`video.captureStream()` / `chrome.tabCapture` → WebCodecs → localhost WebSocket → VideoToolbox.**
- No TCC permission needed.
- **[SPIKE]** Per the occlusion design doc, a captured tab keeps rendering.
- tabCapture needs a user gesture and mutes the tab's audio unless it is re-routed.
- `captureStream` fails on EME/DRM content, and MSE video tracks may be disabled in hidden tabs.
- Native messaging can't carry the frames: host-to-browser messages are capped at 1 MB.

**yt-dlp + AVPlayer.** Fragile for YouTube: needs PO tokens, SABR handling and a Deno runtime, and it broke repeatedly in 2025–26.

**Floating WKWebView with the site embed** (FullFloatPiP's approach, https://github.com/Sigmame/full-float-pip, MIT, 2026-06).
- Fallback chain: direct `src`, then YouTube embed via a local HTTP server with Referer, then site embeds, then the full page with JS that isolates the video.
- No Widevine.

**`AVSampleBufferDisplayLayer` into AVKit PiP.**
- **[CONFIRMED]** iOS-only per Apple DTS (thread 830764, June 2026).

**SkyLight / yabai scripting addition.** Requires SIP to be disabled, so not shippable.

## 4. Prior art
| Product | Approach | Notable features |
|---|---|---|
| FullFloatPiP | Open source | Hover bar, ±10s, volume, aspect lock, position memory, opacity, Esc to close |
| Pipiri (lowtechguys, paid, macOS 14+) | ScreenCaptureKit | fn+P hotkey, region capture, zoom/pan, per-app fps, fade + click-through on hover, multiple windows, CLI |
| hanbong5938/pip, andhikapraa/topsy | Open source, ScreenCaptureKit + Metal | Reference code |
| Helium | Floating web view (discontinued) | Translucent + click-through |
| Picture in Picture (Felix Brix, App Store) | Floating web windows | YouTube embed optimisation, history, iCloud sync |
| Vidimote | Augments Safari PiP | ±10s, speed |
| Echo | — | Resume position, recall hotkey |

The **stash-to-edge with a peek tab** interaction is not done well by any Mac app, so it is a differentiator for us.

`sharingType = .none` is not reliably honoured by ScreenCaptureKit-based screen sharers on Sequoia (thread 808016).

## 5. Native messaging
- Docs: https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
- Framing: a 32-bit native-endian length, then UTF-8 JSON.
- `allowed_origins` takes exact `chrome-extension://<id>/` values; no wildcards.
- `connectNative` keeps the host process alive, which also keeps the MV3 service worker alive.

Host manifest locations:
- Chrome: `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`
- Brave (unofficial path): `~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/`

Pin the extension ID with a manifest `key` so `allowed_origins` stays stable.

## 6. Distribution
- Ship with Developer ID signing, hardened runtime and notarization, outside the App Store and unsandboxed. The sandbox blocks writing native-messaging host manifests.
- Minimum macOS 14. Test on 15 and 26.
