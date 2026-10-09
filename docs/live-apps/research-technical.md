# Live Apps: technical research (2026-10-09, macOS 26.6, Apple Silicon)

How to show any app window live inside the floating panel and make it fully interactive.

Labels:
- **[C]** confirmed: source code, SDK headers or official docs.
- **[R]** reported by a credible third party.
- **[U]** uncertain or inferred.

## Verdict

Use a **virtual display as a "stage"**:
1. Move the real app window onto an invisible extra display.
2. Capture that display with ScreenCaptureKit and show it in our panel.
3. For input, warp the real cursor onto the stage while the pointer is over the panel.

It is the only approach that meets all three requirements at once without disabling SIP:
- **No occlusion throttling.** Nothing ever covers the window on the stage, so the app keeps rendering at full rate.
- **Works over full-screen Spaces.** Our panel already does this.
- **Input is genuine hardware input.** Chromium accepts it, including right-click, drag, IME and shortcuts.

Fallbacks: plain window mirroring (normal Spaces only) and a WKWebView "web panel".

## 1. The virtual display: CGVirtualDisplay (private)

**DeskPad's interface** ([DeskPad](https://github.com/Stengo/DeskPad), HEAD 2026-02-28) [C]:

| Class | Members used |
|---|---|
| `CGVirtualDisplayDescriptor` | `queue`, `name`, `maxPixelsWide/High`, `sizeInMillimeters`, `serialNum`, `productID`, `vendorID`, `terminationHandler` |
| `CGVirtualDisplayMode` | `initWithWidth:height:refreshRate:` |
| `CGVirtualDisplaySettings` | `modes`, `hiDPI` |
| `CGVirtualDisplay` | `initWithDescriptor:`, `applySettings:`, `displayID` |

**macOS 26.4 header dump** ([headers](https://github.com/thatmarcel/macOS-26.4-headers)) adds [C]:
- `rotation`, `isReference` and `refreshDeadline`;
- a transfer-function mode init;
- colour primaries.

**It still works on current macOS.**
- Verified on 26.6.2 by [go-macos/virtualdisplay](https://pkg.go.dev/github.com/go-macos/virtualdisplay) and on a macOS 27 beta by [SpaceO](https://github.com/ParthJadhav/SpaceO). [R]
- [Crisp](https://github.com/didriksg/Crisp) ships it in notarized builds. [R]

**Rules from working implementations:**
- `vendorID` must be non-zero, or `init` returns nil. [C]
- `applySettings:` blocks on WindowServer IPC; Crisp wraps it in a 10 s timeout. [C]
- macOS picks a scaled default mode on its own; Crisp retries until native 1× sticks. [C]
- After any mode change, the display can't be removed until the process exits. [R]
- Extra modes larger than the primary are rejected. [R]
- Re-moding in place takes about 200 ms; recreating takes about 850 ms and flashes the displays. [R]
- **Decision:** keep one fixed, generous HiDPI stage. When the panel resizes, resize the window with AX, not the display.

**Side effects to manage:**
- **It can't be hidden.** It appears in System Settings → Displays. [U] whether `isReference` changes that.
- **WindowServer may promote it to main display** from a remembered arrangement (SideScreen's issue). Check on every reconfiguration. [R]
- **Parking it diagonally** so the cursor can't wander onto it broke later virtual displays (SpaceO). Use an event tap that pushes the cursor back instead. [R]/[U]
- **It gets its own always-current Space.** That is why apps on it never stop rendering. [R]
- **Apps on it still show in the Dock and Cmd-Tab.** [R]
- **Leftover displays.** Process death removes the display and windows return to real screens. Rapid create/destroy cycles have left "ownerless" displays on a beta. [R]

**Chromium visibility.** `WebContentsOcclusionCheckerMac` trusts `NSWindowOcclusionStateVisible` and then only checks for Chromium's own windows covering it [C]. A window alone on the stage rendered live in SpaceO's test [R]. `--disable-backgrounding-occluded-windows` does not help hidden (minimized) windows [C].

## 2. Capture: ScreenCaptureKit

- **Filter.** Use the stage display, including the target app, with `includeChildWindows`. This keeps omnibox dropdowns, menus and extension popups, which window-only capture would drop. Crop with `sourceRect` = the window frame. [C] API / [U] popup behaviour.
- **Format.** BGRA, not 420v: chroma subsampling blurs coloured text. `captureResolution = .best`, size = rect × `pointPixelScale`, `queueDepth` 3–4. [C]
- **Zero-copy display.** Assign the frame's `IOSurface` to `layer.contents` with implicit animations off, and keep the sample buffer alive until the next frame (DeskPad's pattern). [C]
- **Damage-driven.** `SCFrameStatus.idle` means nothing changed, so skip those frames. `minimumFrameInterval` and other settings can change live with `updateConfiguration`. [C]
- **Our own cursor overlay.** Set `showsCursor = false` and draw the cursor ourselves from event-tap positions, so it isn't delayed by capture.
- **Numbers.**
  - Apple's OBS test: about 27% CPU vs 81% for legacy capture on a 2019 Intel Mac. [R]
  - An M-series Mac at 1080p60 on 26.3: median frame interval 17.4 ms. [R]
  - There are no Apple Silicon power figures, so we measure them ourselves with `powermetrics`.
- `CGDisplayStream`, which DeskPad uses, is obsolete in the 15+ SDK. [C]

## 3. Input

**How DeskPad does it** [C]:
- A click on the view calls `CGDisplayMoveCursorToPoint` onto the virtual display. From then on every event is real hardware input.
- A 0.25 s poll tints its title bar while the cursor is on the stage.
- The only way out is moving off the stage edge (issue #6 asks for an escape hotkey).
- DeskPad has no keyboard code. The app you click becomes active and receives keys naturally.

**Our design:**
- When the pointer enters the panel, `CGWarpMouseCursorPosition` moves the cursor to the mapped point on the stage. That call needs no Accessibility permission. [C]
- An event tap watches the stage edges and an escape hotkey, and warps the cursor back to the matching panel edge.
- The panel draws the cursor overlay.

**Synthetic per-process input**, the alternative without a stage, is contradictory:
- SpaceO found keyboard input works but synthetic mouse clicks never reach Chrome web content. [R]
- cua-driver gets clicks through with private `SLEventPostToPid`, window-location stamping and a "primer" click. Right-click becomes left-click, and canvas apps fail. [R]
- The Chrome DevTools Protocol works, but Chrome 136+ blocks remote debugging on the default profile. [R]
- **Conclusion:** keep it experimental only.

## 4. What doesn't work without SIP

- **Changing another app's window level** (yabai: `SLSSetWindowSubLevel`, tags bit 11). Only Dock's privileged connection is allowed to, which needs SIP partly disabled. [C]
- **Moving foreign windows between Spaces** fails on 26.6 with error 1006 from any process except Dock. [R] So our sticky-Space trick almost certainly can't take Brave's window directly; to be confirmed by spike.
- Afloat/SIMBL is dead. Apple added no window pinning in macOS 15 or 26. [R]

## 5. Web engine alternative

**WKWebView**
- Cheap to embed.
- Separate profiles via `WKWebsiteDataStore(forIdentifier:)` (macOS 14). [C]
- Safari-style web extensions via `WKWebExtension` (macOS 15.4+). [C]
- **Not the user's Brave:** no Brave profile, logins, extensions or Shields.
- **Passkeys** need a restricted entitlement. [R]

**CEF/Chromium**
- Roughly 200 MB+ [U], and still not the user's profile.

**Use:** a light "web panel" mode for single sites only.

## 6. Permissions and distribution

- **Screen Recording** is required, including for capturing our own virtual display. Sequoia re-asks monthly for apps that bypass the system picker; no change found in Tahoe. [R]
- **Accessibility** is needed to move and resize the target window (`kAXPositionAttribute`, `kAXSizeAttribute`) and for active event taps. [C]
- **Creating a virtual display or warping the cursor** needs no permission. [R]/[C]
- **Notarization** is fine with private APIs (Crisp, SpaceO). The Mac App Store is out, as it already is because we use SkyLight. [R]

## 7. Riskiest unknowns (spike first)

1. **Full-screen interaction.** Clicking into Brave on the stage while the main display shows a full-screen app: does activation switch Spaces or pull the panel away? Also test with "Displays have separate Spaces" off.
2. **Cursor-capture feel.** Warp jitter, edge-escape races on fast flicks, the Dock following the cursor to the stage, and three-finger swipes while captured.
3. **Chromium on the stage.** Does it hold 60 fps (vsync on a virtual display; one probe saw "@0 Hz")? Does it go hours without throttling? Are popups and menus in the capture?
4. **Stage hygiene.** Main-display hijack, crash recovery, window relocation when the stage goes away, and the arrangement after reboot.
5. **Per-process mouse input** into background Brave web content on 26.6 (the sources contradict each other).
6. **Moving a foreign window into our custom Space** with `SLSSpaceAddWindowsAndRemoveFromSpaces` (expect error 1006).

## Sources

**Projects and code**
- DeskPad and its issues: <https://github.com/Stengo/DeskPad> (#6, #33, #43, #48, #52, #62)
- macOS 26.4 headers: <https://github.com/thatmarcel/macOS-26.4-headers>
- go-macos/virtualdisplay: <https://pkg.go.dev/github.com/go-macos/virtualdisplay>
- SpaceO: <https://github.com/ParthJadhav/SpaceO>
- Crisp: <https://github.com/didriksg/Crisp>
- SideScreen: <https://github.com/tranvuongquocdat/SideScreen>
- Miroo: <https://github.com/nurul-hasan27/Miroo>
- BetterDisplay wiki: <https://github.com/waydabber/BetterDisplay/wiki>
- Topit: <https://github.com/lihaoyun6/Topit>
- Pipiri: <https://lowtechguys.com/pipiri/>
- cua: <https://cua.ai/blog/inside-macos-window-internals>
- yabai: <https://github.com/koekeishiya/yabai>
- creasty/dotfiles PR #148: <https://github.com/creasty/dotfiles/pull/148>

**Chromium**
- Occlusion checker: <https://chromium.googlesource.com/chromium/src/+/main/content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm>

**Apple and press**
- WWDC22 ScreenCaptureKit: <https://developer.apple.com/videos/play/wwdc2022/10156>
- Sequoia monthly Screen Recording prompt: <https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/>
