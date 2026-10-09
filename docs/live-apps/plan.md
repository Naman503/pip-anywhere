# Live Apps: plan

**Goal:** put a real, fully usable app (for example your whole Brave window with all its tabs, or Slack, Notes, a terminal or VS Code) inside the floating PiP Anywhere window.

The window must:
- stay on top of everything, including full-screen apps and every desktop;
- stay still during desktop swipes;
- let you click, type, scroll, switch tabs and drag, exactly as in the real app;
- cost almost nothing while nothing changes.

Status: **planning**, 2026-10-09. Research:
- [research-technical.md](research-technical.md): how to build it.
- [research-product.md](research-product.md): what exists, what users want, and pitfalls.

---

## 1. The core idea: a hidden "stage"

```
            your screen                                 stage (virtual display, invisible to you)
┌──────────────────────────────────────┐          ┌───────────────────────────────┐
│  full-screen Xcode / anything        │          │  ┌─────────────────────────┐  │
│                                      │  capture │  │  real Brave window      │  │
│                     ┌──────────────┐ │ ◀─────── │  │  (your profile, tabs,   │  │
│                     │ floating     │ │  60 fps  │  │  extensions, logins)    │  │
│                     │ panel shows  │ │ zero-copy│  └─────────────────────────┘  │
│                     │ the stage    │ │          │                               │
│                     └──────────────┘ │ ───────▶ │  cursor warped here while     │
│                                      │  cursor  │  you point at the panel       │
└──────────────────────────────────────┘          └───────────────────────────────┘
```

1. **Stage.** PiP Anywhere creates a virtual display with `CGVirtualDisplay`. This is the same private API that DeskPad, BetterDisplay and Crisp use; no extra permission is needed.
2. **Move.** You pick a window. We move it onto the stage with the Accessibility API and size it to the panel. **The app genuinely thinks it has a small screen**: it re-lays itself out, and text stays sharp, unlike a scaled-down video.
3. **Show.** ScreenCaptureKit captures the stage. Each frame's IOSurface goes straight into the panel's layer, so there's no copy, encode or decode. Unchanged frames cost nothing.
4. **Interact.** When your pointer enters the panel, the real cursor is warped to the same spot on the stage, and the panel draws a cursor overlay. Clicks, typing, scrolling, right-click, drag, IME and shortcuts are then real hardware input, which is why every app accepts them. Leaving the panel, or pressing the escape hotkey, warps the cursor back.

**Why not simpler routes:**

| Route | Why not |
|---|---|
| Mirror the window where it is | It freezes when covered, minimized or on another desktop, because browsers stop drawing hidden windows. |
| Fake clicks into a background window | Chromium ignores synthetic mouse clicks in web content. |
| Make Brave's own window float | Needs System Integrity Protection disabled on macOS 26. |
| An embedded browser | It wouldn't be *your* Brave: no profile, extensions or logins. We keep this as an optional light mode. |

What we already have and reuse: the floating panel that shows over full-screen apps and stays still during swipes, slide-to-edge with blur, ghost mode, resizing, hotkeys, the menu, and the scripting interface.

## 2. Modes

| Mode | For | How it works | Trade-off |
|---|---|---|---|
| **Live app** (primary) | Any app: Brave, Slack, Terminal, VS Code… | Stage, capture and cursor warp | Needs Screen Recording and Accessibility permissions. While you interact, the real cursor lives on the stage. |
| **Mirror** (fallback) | When you don't want a stage | Capture the window where it is. Hover swaps in the real window (Topit's trick). | Normal desktops only. Freezes when the window is covered or minimized. |
| **Web panel** (light) | One website (docs, chat, dashboard) | Built-in WKWebView with its own profile | Not your Brave session, but very light. |
| **Video** (exists today) | Browser videos | The current extension pipeline | – |

## 3. Features

### MVP (v1.0, Live app)
1. **Pick a window.** From the menu or a hotkey, choose a window from a list with live thumbnails. It moves onto the stage and floats.
2. **Fully interactive.** Click, type, scroll, drag, right-click, tabs, menus and popups.
3. **Sharp at any size.** Resizing the panel resizes the real window, so the app re-lays itself out.
4. **Focus handoff.** Clicking the floating app activates it. Leaving it or pressing Esc⌥ returns focus to the app you were in, exactly where you left off.
5. **Summon / dismiss hotkey** (a drop-down like the iTerm2 or Ghostty quick terminal), plus the existing slide-to-edge with blur and hover-to-peek.
6. **Ghost mode with a hold modifier.** It stays see-through and click-through; holding ⌥ lets you interact. A visible indicator means it can never become a trap.
7. **Energy governor:**
   - 60 fps while you're pointing at it or it's changing;
   - 10–15 fps when idle;
   - paused when slid away or hidden;
   - unchanged frames skipped.
8. **Honest states.** Clear badges instead of silent freezes for:
   - source closed (auto-close);
   - DRM content black ("open the real window");
   - password or secure input (bring the real window forward);
   - Touch ID or other system prompt.
9. **Safe return.** On close, quit or crash, the window goes back to where it came from. The stage disappears automatically if the app dies.
10. **Permission onboarding.** One screen explains Screen Recording and Accessibility, and the monthly macOS re-prompt.

### Next (v1.1)
11. **Multiple floating apps** on one stage, laid out side by side, each in its own panel or stacked as tabs. A hotkey cycles between them, plus "float the window I'm in now".
12. **Per-app presets:** size, position, edge, opacity, fps cap, ghost default. Remembered automatically, with an excluded-apps list.
13. **Activity badges while slid away.** A new message, or a title or pixel change, lights up the edge tab. Useful for chat and for "a long task needs your approval".
14. **Region crop and zoom:** float just part of a window, or zoom to read small code.
15. **Restore after reboot**, display changes, multiple monitors, notch-safe placement.
16. **Web panel mode** for single sites.

### Later
17. **Workspace snapshots:** named layouts of floating apps.
18. **Auto-fade** when the pointer is away, and ⌘-scroll for opacity.
19. **Context rules:** don't float during presentations, screen recording or Game Mode.
20. **A compact tab switcher overlay** for browsers in very small panels.
21. **Stream a floating app to an iPhone or iPad.**
22. **A CLI and Shortcuts actions** (we already have the command interface).

Clipboard and drag-and-drop **just work** in Live app mode, because it's the real app receiving real input. Passive mirrors, Hover for example, get refunds over exactly this.

## 4. Performance targets and how

| Situation | Target |
|---|---|
| Static content (chat or docs open, nothing moving) | **< 2% CPU**, near-zero GPU |
| Pointer over it, scrolling or typing | 60 fps, < 10% CPU, input-to-screen ≈ 2–3 frames (33–50 ms) |
| Video playing in the floating app | 60 fps; GPU-bound, like playing it normally |
| Slid away or hidden | Capture paused: **0%** |

How we get there:
- **Zero-copy.** The ScreenCaptureKit IOSurface goes straight into `CALayer.contents`. No encode, decode or Metal pass.
- **BGRA at native pixels, 1:1.** Text stays sharp and no scaling work is needed.
- **Damage-driven capture.** Idle frames are skipped; we only pay when pixels change.
- **Adaptive frame rate.** `minimumFrameInterval` changes live with `updateConfiguration` (60 / 15 / paused).
- **The stage is sized to the content.** It's a fixed generous HiDPI mode at 60 Hz, not 120 Hz. Panel resizes change the window, not the display, to avoid display reconfiguration churn.
- **Our own cursor overlay**, so the cursor never waits on capture.
- **Measured, not guessed.** `powermetrics --samplers cpu_power,gpu_power,tasks`, captured frames per second, and the share of idle frames, for static, scrolling and video content. These numbers go in the README.

## 5. Architecture (inside the existing app)

```
app/Sources/
  PiPCore/            + StageGeometry (panel ↔ stage coordinate mapping, layout of multiple windows), unit-tested
  PiPAnywhere/
    Live/
      Stage.swift          CGVirtualDisplay lifecycle, mode pinning, main-display guard, crash-safe
      WindowMover.swift    AX: list windows, move/resize onto the stage, restore original frame
      StageCapture.swift   SCStream (display + app filter, sourceRect, BGRA), adaptive fps, idle skip
      CursorBridge.swift   warp in/out, event tap for stage edges, escape hotkey, cursor overlay
      FocusHandoff.swift   remember the previous app, restore focus on leave
      WindowPicker.swift   SwiftUI picker with live thumbnails (SCScreenshotManager)
      LiveSession.swift    ties one floating panel to one staged window; states and badges
    CGVirtualDisplay.h     private interface (from DeskPad + 26.4 headers), via a module map
```

The panel, sticky Space, stash, blur, ghost, resizing, hotkeys and menu are all reused unchanged.

## 6. Phase 0 spikes (do first, 3–4 days)

Each spike has a pass/fail result that decides the design.

| # | Spike | Pass when |
|---|---|---|
| S1 | Create a 3200×2000 HiDPI 60 Hz stage | The mode sticks. `CGMainDisplayID` is unchanged after sleep/wake and plugging in a monitor. Killing the app removes the stage and windows return. |
| S2 | Move a Brave window onto the stage with AX and capture it into a panel over full-screen Safari | Live, sharp, popups and menus visible. Brave's rAF counter keeps 60 fps and `document.visibilityState` stays `visible` for 30 min. |
| S3 | Cursor warp in and out with an event tap; type in the omnibox, use a context menu, an extension popup, drag-select, scroll | Feels native. Escape works on fast flicks. The Dock doesn't move to the stage. |
| S4 | **Click into Brave on the stage while the main screen shows a full-screen app** | The main screen stays on its full-screen Space and the panel stays visible. Also test with "Displays have separate Spaces" off. |
| S5 | Energy: static page, scrolling, 60 fps video at 60 / 15 / 5 fps | Static < 2% CPU; numbers recorded. |
| S6 | Side checks: put a foreign window into our sticky Space (expect error 1006); send a per-process synthetic click into background Brave | Decides whether Mirror mode can get input without the stage. |

If S4 fails, the fallback is to dedicate the floating app's interaction to normal desktops and keep view-only display over full-screen apps. That's still useful, but the spike decides it.

## 7. Phases and timeline

Focused working days, solo with Claude.

| Phase | What | Days |
|---|---|---|
| 0 | Spikes S1–S6, results in `decisions.md` | 3–4 |
| 1 | Stage + WindowMover + StageCapture into the existing panel, adaptive fps | 4–5 |
| 2 | CursorBridge (warp, edges, escape, overlay) + FocusHandoff | 4–5 |
| 3 | Window picker, summon hotkey, ghost-with-modifier, honest states, safe return, onboarding | 4–5 |
| 4 | Robustness: crash/relaunch recovery, display changes, sleep/wake, multi-monitor; energy measurements in the README | 3–4 |
| **MVP v1.0** | | **≈ 3–4 weeks** |
| 5 | Multiple floating apps, presets, activity badges, crop/zoom | 5–6 |
| 6 | Web panel mode, Mirror fallback | 3–4 |

## 8. Risks

| Risk | Mitigation |
|---|---|
| Private `CGVirtualDisplay` changes in a future macOS | It has been stable since macOS 11 and is used by several shipping apps. Load it at runtime; if it's missing, fall back to Mirror mode. |
| The stage becomes the main display, or windows move after a reboot | Stable display identity. Check on every reconfiguration. Place the stage at the edge away from the menu bar. |
| The cursor wanders onto the stage by accident | An edge event tap pushes it back. The stage sits on the side you rarely move towards. |
| Activating the floating app disturbs a full-screen Space | Spike S4 decides this before any feature work. |
| Two permissions (Screen Recording, Accessibility) and the monthly re-prompt | One clear onboarding screen. Request only when Live mode is first used. |
| DRM, secure input, system prompts don't show in a capture | Detect each and show an honest badge with a one-click "open the real window". |
| Battery | Energy governor plus measured targets; pause whenever it isn't visible. |
