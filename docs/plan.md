# PiP Anywhere — Plan

A macOS menu-bar app plus a Brave/Chrome extension. Any video playing in the browser can pop out into a small floating window that:

- stays visible on every desktop (Space), including over apps in full-screen mode;
- can be slid into a screen edge so only a thin tab shows, then pulled back out;
- has controls built for watching while you work.

Status: **v0.3.0 released** (2026-10-09). This is the original plan from the start of the project; see [the README](../README.md) for what exists today, [decisions.md](decisions.md) for the experiments and changes per round, and [the changelog](../CHANGELOG.md).

Research date: 2026-10-08. Dev machine: macOS 26.6.1 (Tahoe), Xcode 26.2, Swift 6.2, Node 22, Brave and Chrome installed.

---

## 1. The problem and why it happens

Brave and Chrome PiP follows you to other normal desktops, but it disappears when you switch to an app in full-screen mode. The cause is in Chromium's source (`video_overlay_window_views.cc`, read on 2026-10-08). The PiP window is:

- an ordinary `NSWindow` of a regular Dock app;
- at window level 3 (`kFloatingWindow`);
- marked `CanJoinAllSpaces`, but **not** `FullScreenAuxiliary`, and **not** a non-activating panel.

Apple DTS (forum thread 826308, May 2026) states the rule: *macOS doesn't layer regular foreground apps above other apps' full-screen Spaces.*

The issue has been open since 2020 on the Google PiP extension (issue #57) and on Brave Community. Firefox has the same bug. There is no Chromium flag that fixes it. Safari works only because it uses Apple's private system PiP service.

**What follows:** we cannot fix Brave's own PiP window. Changing another app's window needs SIP disabled (yabai-style), which isn't viable. So **our own app must own the floating window, and we must get the video into it.**

### The window recipe (confirmed on macOS 26)

```swift
NSApp.setActivationPolicy(.accessory)                 // menu-bar app, LSUIElement = YES
let panel = PiPPanel(                                 // NSPanel subclass, canBecomeKey = true
  contentRect: rect,
  styleMask: [.nonactivatingPanel, .borderless, .resizable],  // set the final mask at creation (Tahoe bug)
  backing: .buffered, defer: false)
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false
panel.level = .statusBar        // try .floating first; .screenSaver also covers Keynote-style full screen
panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
panel.orderFrontRegardless()
```

`.nonactivatingPanel` is the setting that matters. With it, the window shows over full-screen Spaces without listening for Space changes.

---

## 2. The hard part: getting the video into our window

The obvious approach is screen-capturing the browser window with ScreenCaptureKit. It has a hidden flaw for your exact use case:

> When Brave is on Desktop 1 and you are in a full-screen app on another Space, Brave's window counts as *occluded*. Chromium then **stops painting** the page (`MacWebContentsOcclusion`), so the capture shows a frozen frame. An open-source SCK PiP app (`hanbong5938/pip`) reports exactly this.

So we use several video sources, picked automatically per site:

| # | Source | How it works | Pros | Cons | Use for |
|---|---|---|---|---|---|
| **A** | **Tab-capture stream** (primary) | Extension calls `chrome.tabCapture`, gets the stream in an offscreen document, encodes H.264 with WebCodecs, and sends it over a localhost WebSocket. The app decodes with VideoToolbox into an `AVSampleBufferDisplayLayer`. | Works on any non-DRM site. Keeps your logins. No Screen Recording permission. Chromium keeps a captured tab rendering, which should beat occlusion (**spike S1**). | Encode/decode adds about 1–3 frames of latency and some CPU. Needs a user gesture (hotkey or click). Tab audio must be re-routed. | YouTube, Udemy, Coursera, docs sites, Twitch, most video |
| **B** | **Native embed player** | For known sites (YouTube, Vimeo, Twitch…), the app opens the embed URL in its own `WKWebView` at the current timestamp and pauses the tab. Same approach as the open-source FullFloatPiP. | Best quality, lowest CPU. Unaffected by occlusion. | Separate cookie jar (Premium and login state may differ). Some videos block embedding. Only for supported sites. | YouTube fallback, or a "low battery" mode |
| **C** | **ScreenCaptureKit region capture** | Captures the video's rectangle from the browser window, or any window or region. | Works for anything visible, including any app (not just browsers). | Needs Screen Recording permission (re-confirmed monthly). Freezes when the source is occluded. DRM shows black. | "Pin any window or region", plus a debug comparison |

Rejected options:

- `AVSampleBufferDisplayLayer` into system PiP: iOS-only according to Apple DTS (June 2026).
- Private `PIP.framework`: fragile.
- SkyLight window-level hacks: need SIP disabled.
- yt-dlp to AVPlayer: YouTube breaks it every few weeks (PO tokens, SABR).

**DRM sites (Netflix, Prime, Disney+) are out of scope.** They show black in every capture path. Use Safari's native PiP for those.

---

## 3. Architecture

```
┌──────────────── Brave / Chrome ────────────────┐
│ content script (every frame)                    │
│   finds the active <video>, reports state +     │
│   rect, applies play/pause/seek/rate commands   │
│ service worker                                  │
│   hotkeys, context menu, routing,               │
│   chrome.runtime.connectNative ───────┐         │
│ offscreen document                    │         │
│   tabCapture → crop → WebCodecs H.264 │         │
│   → WebSocket (binary) ──────┐        │         │
└──────────────────────────────┼────────┼─────────┘
                               │        │ native messaging (JSON control)
                   127.0.0.1:port + token
                               │        ▼
┌──────────────────────────────┼─ macOS app (Swift) ──────────────┐
│ pip-host (helper binary, stdio) ⇄ XPC/Unix socket ⇄ main app    │
│ MediaServer (WebSocket) → VTDecompressionSession →              │
│   AVSampleBufferDisplayLayer                                    │
│ PiPPanel (NSPanel) + SwiftUI controls overlay                   │
│ WindowBehaviors: stash, snap, ghost, dodge, hotkeys,            │
│   Now Playing                                                   │
│ Sources: TabStream | EmbedWebView | SCKCapture                  │
│ Menu bar UI + Settings                                          │
└─────────────────────────────────────────────────────────────────┘
```

**Control channel: native messaging (JSON).**
- Authenticated by extension ID, and no open port.
- Host manifests are installed by the app to both locations:
  - `~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/`
  - `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`
- The extension ID is pinned with a manifest `key` so `allowed_origins` stays stable.

**Media channel: localhost WebSocket.** Native messaging is capped at 1 MB per message. The port and a one-time token are exchanged over native messaging.

**Source of truth:** the browser tab owns play state, and the app mirrors it. The tab also keeps playing the audio, so there's no audio-sync work.

### Folder layout (planned)

```
mac-pip-anywhere/
  PLAN.md
  app/                    Xcode project: PiPAnywhere.app (SwiftUI + AppKit)
    PiPAnywhere/
      App/                AppDelegate, MenuBar, Settings
      Window/             PiPPanel, StashController, SnapController, GhostMode
      Video/              MediaServer, H264Decoder, SampleBufferView, EmbedWebView, SCKSource
      Bridge/             NativeMessaging protocol, XPC
      Input/              Global hotkeys, NowPlaying (MPRemoteCommandCenter)
    PiPHost/              stdio native-messaging helper (CLI target, embedded in .app)
  extension/              MV3 extension (TypeScript + Vite)
    src/background.ts  src/content.ts  src/offscreen.ts  src/popup/
  spikes/                 throwaway experiments from Phase 0
  docs/                   protocol.md, decisions.md
```

**Stack:**
- App: Swift 6, SwiftUI for the UI, AppKit for the panel and window behaviors. Frameworks: VideoToolbox, AVFoundation, WebKit, ScreenCaptureKit. Uses `Network.framework` for the WebSocket server, so there are no third-party dependencies. Global hotkeys use the `KeyboardShortcuts` SwiftPM package, the only planned dependency.
- Extension: TypeScript and Vite.
- Minimum macOS 14 (Sonoma). Test on 15 and 26.

---

## 4. Features

### MVP (v0.1): the problem you have today
1. Pop out the current video with a hotkey (`⌥⌘P`), toolbar button or right-click.
2. The floating window shows over **full-screen apps** and on **all desktops**.
3. Hover controls: play/pause, ±10s, a seek bar, and a "back to tab" button that focuses the tab and closes the PiP.
4. Drag anywhere, resize with aspect ratio locked, and snap to the four corners.
5. **Stash to edge:** a button (or flicking the window into an edge) slides it off-screen, leaving a thin glowing tab with a playing indicator. Click the tab or press the hotkey to bring it back. Optionally pause while stashed.
6. Remembers position and size per display.
7. Menu-bar icon: active video, sources, quit.

### v0.2: watch while working
8. **Ghost mode:** set opacity (for example 40%) and make the window click-through, so you can click what's underneath. Hold `⌥` to interact.
9. **Dodge cursor:** fades or jumps to the opposite corner when the mouse comes close.
10. Speed control (0.5–3×, with `[` / `]` keys) synced to the tab.
11. Media keys and Control Center Now Playing control the PiP video (`MPRemoteCommandCenter`).
12. Global hotkeys: toggle stash, play/pause, ±10s, ghost mode, close.
13. **Hide from screen sharing** (`sharingType = .none`) so the PiP doesn't show up in Zoom or Meet. Best-effort: some ScreenCaptureKit-based sharers ignore it.
14. Auto-pop-out when you switch away from a tab playing a video (optional, per site).

### v0.3: power features
15. Captions rendered natively. They are read from the page's text tracks or YouTube captions and stay sharp at small sizes.
16. Crop or zoom inside the video, useful for reading code in small text on a tutorial.
17. Multiple PiP windows (for example, a stream plus a tutorial).
18. Source B (native embed) as a toggle per site, for battery saving.
19. Source C: "Pin any window or region", for pinning a terminal, a Zoom gallery, a build log, and so on.
20. Chapter list and "next chapter" for YouTube, using data from the content script.
21. Stats overlay for debugging: source, resolution, fps, dropped frames, latency.

---

## 5. Phases and timeline

Estimates are in focused working days for one developer pairing with Claude.

| Phase | What | Days | Exit criteria |
|---|---|---|---|
| **0. Spikes** | S1–S5 below. Decide the sources based on the results. | 2–3 | A written `docs/decisions.md` |
| **1. Floating window shell** | Menu-bar app, `PiPPanel`, a test video playing over full-screen Safari or Xcode on all Spaces, drag/resize/snap, stash-to-edge | 3–4 | Shows over a full-screen app on macOS 26 |
| **2. Bridge** | Extension skeleton, native-messaging host, installer for host manifests (Brave and Chrome), video detection, state and commands both ways | 3 | A popup button in the browser toggles play in the app, and the reverse |
| **3. Video pipeline (Source A)** | tabCapture, offscreen doc, crop, WebCodecs, WebSocket, VideoToolbox, display layer. Reconnect, resize, tab navigation. | 4–6 | YouTube 1080p in PiP over a full-screen app, ≤150 ms latency, no freeze while Brave is hidden |
| **4. MVP polish** | Hover controls UI, hotkeys, position memory, error states | 2–3 | **v0.1, used daily** |
| **5. v0.2 features** | Ghost mode, dodge, speed, Now Playing, hide-from-sharing, auto-pop-out | 4–5 | v0.2 |
| **6. v0.3 features** | Captions, crop/zoom, multiple windows, Source B, Source C | 6–8 | v0.3 |
| **7. Ship** | Developer ID signing, notarization, DMG, first-run onboarding, extension packaging | 2 | Installable on another Mac |

**Total:** about **3 weeks to a daily-usable MVP (phases 0–4)** and about **6–7 weeks for everything**.

### Phase 0 spikes (do these first, all in `spikes/`)
- **S1 (critical):** with Brave on Desktop 1 and a full-screen app on Desktop 2, does a `tabCapture` stream (and separately `video.captureStream()`) keep producing frames? If both freeze, Source B becomes the primary source for YouTube. A fallback would be a tiny Brave window kept visible but behind ours.
- **S2:** an `NSPanel` level of `.floating`, `.statusBar` or `.screenSaver` over a native full-screen app and over Keynote play mode on macOS 26.
- **S3:** whether an offscreen document can open a WebSocket to `ws://127.0.0.1` in current Brave without Local Network Access blocking it.
- **S4:** WebCodecs H.264 encode at 1080p30 in the offscreen document: CPU and latency on your Mac.
- **S5:** whether a YouTube embed in `WKWebView` plays reliably with a timestamp, and how to handle "embedding disabled" videos.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| Chromium stops rendering occluded tabs even with capture | S1 settles this. Source B covers YouTube. |
| tabCapture mutes the tab's audio | Route the captured audio back to the speakers in the offscreen doc (a known pattern), or take the video track only (S1). |
| Brave's NativeMessagingHosts path isn't officially documented | Install to both the Brave and Chrome paths, and add a self-test in the menu bar. |
| macOS 26 style-mask bugs | Create the panel with its final mask and never mutate it. |
| A/V offset (video ~100 ms behind tab audio) | Measure in S4. Optionally delay audio in the offscreen doc. |
| Screen Recording permission friction (Source C only) | Request it only when Source C is first used. Offer `SCContentSharingPicker` as an alternative. |

## 7. Prior art to learn from
- **FullFloatPiP** (MIT, 2026): extension + native messaging + NSPanel/WKWebView. The closest existing project; read its code before Phase 2. github.com/Sigmame/full-float-pip
- **Pipiri** (paid): ScreenCaptureKit PiP with click-through and fade-on-hover.
- **hanbong5938/pip** and **topsy**: open-source ScreenCaptureKit + Metal PiP.
- **Helium**: floating web view with translucency.
- The **iOS PiP stash-to-edge** interaction. No Mac app does this well, so it's our differentiator.
