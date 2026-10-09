# Decisions and spike results

## Phase 0 spikes (2026-10-08, macOS 26.6.1, MacBook 1800×1169 pt)

| Spike | Question | Result | Evidence |
|---|---|---|---|
| **S1** | Does tab capture keep producing frames when the browser is hidden? | **Yes.** 28–30 fps for 10 s with the Chromium window **minimized**, which is a stronger form of occlusion than being on another Space. Chromium keeps a captured tab rendering. | `extension/tests/e2e.mjs youtube` |
| **S2** | Is a non-activating `NSPanel` visible over another app's native full-screen Space? | **Yes**, at all three levels: `.floating`, `.statusBar` and `.screenSaver`. Default is `.statusBar`. | `spikes/FullscreenProbe.swift` |
| S3 | Can the offscreen document open `ws://127.0.0.1` without Local Network Access blocking it? | **Yes** in Chromium (Chrome for Testing, build 1243). Brave is still to be confirmed by hand. | e2e tests |
| S4 | WebCodecs H.264 cost and latency | Hardware encoder `avc1.640033` is accepted. Bitrate is 0.1–1.5 Mbps for typical content. Latency is not measured yet. | e2e logs |
| S5 | YouTube embed in `WKWebView` | Not needed for v0.1, because S1 passed. Kept as an optional battery-saving source. | – |

## Decisions

1. **One loopback WebSocket for control and video.** Native messaging was deferred.
   - The app accepts only `Origin: chrome-extension://angpoecfkgeeclnkdmafakhldmadjdih`, the ID pinned by the manifest `key`. Web pages cannot forge `Origin`.
   - Native messaging comes back later, only to auto-launch the app.
   - The extension's private key is in `extension/.keys/`, which is git-ignored. It is only needed to pack a `.crx`.
2. **`AVSampleBufferDisplayLayer` decodes the H.264 directly.** There is no `VTDecompressionSession`. Samples are marked *display immediately*, with no jitter buffer, because the tab plays the audio.
3. **Video-only tab capture.** Capturing audio would mute the tab, so sound stays in the browser and needs no A/V sync.
4. **Capture at the tab's real pixel size.** `maxWidth`/`maxHeight` are set to viewport × devicePixelRatio. Larger maxima made Chrome upscale every frame: 1920×1080 from a 1280×800 tab.
5. **Crop and scale in the offscreen document.** The video rect from the content script is drawn onto an `OffscreenCanvas`, then encoded. The longest edge is capped at 1920 (2560 since round 2). The encoder is reconfigured when the crop size changes.
6. **SwiftPM + `scripts/bundle.sh`** instead of an Xcode project. It produces an ad-hoc-signed `.app`. Developer ID signing and notarization come with distribution (phase 7).
7. **Carbon `RegisterEventHotKey`** for global shortcuts, instead of the `KeyboardShortcuts` package. No dependencies, and no Accessibility permission needed.
8. **esbuild + TypeScript** for the extension, the same setup as BetterTube.
9. **Scriptable via distributed notifications** (`local.pipanywhere.command`). This made the window behaviors testable without simulating mouse input, and it lets Shortcuts or Raycast drive the app.

## Round 2 (2026-10-08): feedback after first use

| Request | Change | Evidence |
|---|---|---|
| Window slides away and back during a four-finger desktop swipe | `StickySpace`: the window moves into its own window-server space shown above the user's Spaces (private SkyLight calls on our own window, loaded at runtime, same technique as SketchyBar's `sticky`). Menu toggle; on by default. | `SpaceSwitchProbe`: 1 x-position during enter/exit full-screen transitions (setting off: 42/45). `FullscreenProbe`: still visible **and in front** at all three levels. |
| Should go anywhere, including half off the side | Free placement is the default: the window stays where it's dropped, as long as 48 pt stays on screen. Corner snapping is an option. Flick-to-stash now needs 70% of the window past the edge. | Unit tests |
| Resize without limits | Edge + corner handles (aspect kept, opposite corner fixed), pinch, ⌃⌥= / ⌃⌥-. 120 pt wide up to the full screen. Keyboard growth keeps a fully visible window fully visible. | Unit tests; on the 1800×1169 screen: 1800×1013 down to 120×68 |
| Frame rate lower than the video | Capture and encode at up to 60 fps (was 30). Longest edge up to 2560. A frame dropped before encoding no longer forces a key frame; forcing one made drops snowball. | e2e: 60 fps video → 60 fps in the window, also while minimized |
| 2.85× speed | Added to the speed menu | – |

The tests no longer touch a copy of the app you're running:
- A copy started with `--port` uses its own preferences and its own command notification name.
- The extension takes an `appPort` override from local storage.
- The probes take `PIP_PID`.

## Round 3 (2026-10-09)

| Request | Cause | Change | Evidence |
|---|---|---|---|
| No resize cursor on the edges | The panel never activates the app, and the window server ignores cursor changes from background apps | SkyLight connection property `SetsCursorInBackground`; the handles `set()` the cursor on every hover move (macOS 15+ frame-resize cursors); grab zones 8 pt (edges) / 18 pt (corners) | Property set without error. Not verifiable without moving the real mouse. |
| Coming back from the edge went to the side | The remembered frame was never cleared, so later stashes reused an old one; a flick remembered the half-off-screen release point | Remember the exact frame when stashing (for a flick: the frame before the drag); clear it on return | Placed → stashed → back = same frame; moved → stashed → back = the *new* frame |
| Too small to see | Minimum was 120 pt | Minimum width 200 pt | Shrinking stops at 200×113 |
| Strip visible while stashed shows the video | – | Core Image Gaussian blur (radius 60) on the layer containing the video, plus a dark tint | On-screen capture: test-card text unreadable when stashed |
| More options | – | Volume/mute (button, ⌃⌥M, scroll), scroll sideways to seek, double-click big/normal, size presets, move to corner, mute while stashed, progress line, shortcut list in the menu | e2e: volume 30%, mute, unmute reach the tab |
