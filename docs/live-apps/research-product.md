# Live Apps: product and UX research (2026-10-09)

**Live Apps** means any app window, live and fully interactive, inside the floating PiP Anywhere window.

**Method:** Reddit was blocked to the research crawler. Sources are Hacker News, the Keyboard Maestro, Apple Developer and Parallels forums, GitHub issue trackers, App Store reviews, Product Hunt and vendor blogs. Points without a source are marked *(inferred)*.

## 1. The four techniques on the market

macOS has no public API for pinning another app's window on top. Every product picks one of four workarounds, and most user complaints trace back to that choice.

| Technique | Products | Strengths | Typical complaints |
|---|---|---|---|
| **A. Re-raise the real window via Accessibility** (polling or on focus change) | PinTop, KeepTop, AlwaysOnTop (re-raises every 0.5 s), Floaty | Real window, real input | Fights for focus; doesn't work over full-screen Spaces; flicker; usually one window |
| **B. Change the window level** (private API or code injection) | Afloat/AfloatX (SIMBL), yabai scripting addition, BetterTouchTool "set window level" | True float, transparency, click-through | Needs SIP partly disabled; broke at Mojave; users distrust it |
| **C. Mirror with ScreenCaptureKit into your own floating panel** | Topit (open source), PiPHero, Hover, MenuPiP, Pocket Screen, Lufra, BetterDisplay 5 window PiP | Works over full screen and on all Spaces; multiple windows; opacity; crop | Mostly passive (can't click); **freezes when the source is on another Space or minimized**; typing/copy-paste broken; blurry when scaled; CPU cost; monthly Screen Recording prompt; DRM shows black |
| **D. Host the real window on a hidden virtual display and mirror that** | PIPin (2026), DeskPad (open source), BetterDisplay virtual screens + PiP | The source never stops rendering; resolution you choose | Interaction relies on warping the cursor; private CGVirtualDisplay; windows rearrange when the display is attached or detached |

**Gap in the market:** no product found does fully interactive click, type and scroll inside the float well. That is our target.

### Product notes

**Topit** (open source, 1.4k stars, uses ScreenCaptureKit). Its README warns about battery drain with many pins. Its open issues are a free list of failure modes ([issues](https://github.com/lihaoyun6/Topit/issues)):
- Doesn't work over full-screen apps (#15, #30).
- Misbehaves with Stage Manager (#34).
- Focus fights with the menu bar (#29).
- Flicker where two pinned windows overlap (#37).
- IME candidate paging fails (#39).
- VS Code caret position is wrong (#26).
- Pins aren't restored after reboot (#32).
- Users want a window-picker hotkey and cycling between pinned windows (#20).

**PiPHero.** [Sir Apfelot measured](https://www.sir-apfelot.de/piphero-app-53876/) about 21% CPU for one view and 42–45% for three; the reviewer considered that a bug. A minimized source shows a smeared Dock icon instead of the window.

**Hover.** Mirrors at 60 fps and forwards keystrokes, but copy-paste doesn't work; one user asked for a refund over it. The duplicate window "cannot be clicked on", and dragging is slow ([App Store](https://apps.apple.com/app/hover-floating-window-image/id1502873830)).

**MenuPiP.** Frame rate per window (1, 5, 15, 30 or 60 fps) to save energy; region crop; click-through toggled with ⌃⌥P; works on all Spaces and over full screen ([GitHub](https://github.com/Joowonoil/MenuPiP)).

**Pocket Screen.** "A live, passive mirror": you interact with the original window. CPU rises with fast-changing content. It pauses automatically when the source is minimized, but doesn't show that it's paused. v1.6 hides floats from screenshots and screen sharing ([Product Hunt](https://www.producthunt.com/posts/pocket-screen)).

**PIPin** (2026). Uses a hidden virtual display so the source "never stops rendering". ⌘-click warps the cursor to the real window, for example to approve a prompt without switching Spaces. Can stream to an iPhone or iPad ([hunted.space](https://www.hunted.space/product/pipin)).

**BetterDisplay 5.0.5.** PiP of a window or window group, with a target frame rate per stream. Open requests: click-through in the PiP menu, warp the cursor back when leaving PiP, and "move apps into the PiP screen" ([release notes](https://newreleases.io/project/github/waydabber/BetterDisplay/release/v5.0.5)).

**DeskPad.** Shows a virtual display in a window. You interact by moving the pointer onto the virtual display; the title bar turns blue. The default resolution is 3360×2100; users choose about 1280×800 HiDPI ([podfeet](https://www.podfeet.com/blog/?p=33319)).

**Browser-specific tools:**
- Helium (now HeliumLift): translucent mode passes clicks through.
- Floating: grabs browser tabs via AppleScript.
- [Document Picture-in-Picture](https://developer.chrome.com/docs/web-platform/document-picture-in-picture) (Chrome 116+): an always-on-top window holding any HTML, but it can't be navigated or positioned and dies with its tab.

**Gold standard for summon/dismiss:**
- iTerm2's Hotkey Window.
- Ghostty's quick terminal: position, size %, auto-hide, and configurable animation including 0 ms.

**Windows equivalents:**
- **PowerToys Always On Top**: Win+Ctrl+T, a colored border, a sound, an excluded-apps list, and no float during Game Mode.
- **WindowTop**: click-through, "shrink with interact" (click forwarding), and saved configurations. Reviewers find accidental click-through confusing.

## 2. Use cases, ranked by how often they come up

1. Reference material while coding: docs, a tutorial video, specs.
2. Chat: Slack, Discord, AI chat.
3. A terminal or log tail.
4. A video call alongside notes.
5. Media: video and music.
6. Monitoring dashboards and long-running tasks. "Approve a prompt" from a coding agent fits here, and it's very relevant now.
7. Small utilities: to-do, calculator, dictionary.
8. iPhone Mirroring.

Full-screen IDEs and presentation mode are repeatedly given as the reason people need the float at all.

Sources:
- [Keyboard Maestro forum, 2025-11](https://forum.keyboardmaestro.com/t/always-on-top-window-pin-keep-on-top-you-name-it/50686): BTT is the only tool "reliable enough"; AlwaysOnTop's focus issue makes it unusable; yabai would mean disabling SIP.
- [Show HN: Floaty](https://news.ycombinator.com/item?id=46065780): ⌘-scroll to change opacity.

## 3. Performance expectations

- **Unacceptable:** about 20% CPU per view (PiPHero) is seen as a bug.
- **Expected:** near zero when idle or hidden, and low single-digit CPU for static content *(inferred)*.
- **ScreenCaptureKit vs legacy capture:** Apple's OBS demo measured about 27% CPU vs 81% ([gigazine](https://gigazine.net/gsc_news/en/20220201-apple-obs-general-capture-pull-request)).
- **Idle frames:** ScreenCaptureKit marks unchanged frames as `.idle`; skip them ([forum](https://developer.apple.com/forums/thread/718356)).
- **Levers vendors use:**
  - a frame-rate cap per window;
  - keeping floats small;
  - pausing when the window is hidden.

## 4. Pitfalls to design around

1. **Full screen.** Requires a non-activating panel with `.canJoinAllSpaces` + `.fullScreenAuxiliary` and an accessory activation policy. We already have this. A non-key panel can't receive typing, so it must become key when clicked.
2. **Source on another Space, minimized or occluded.** Plain window mirrors freeze in these cases, which is why the virtual-display approach exists. Show an explicit "paused" state, and never minimize the source.
3. **Input.**
   - Synthetic events need Accessibility permission.
   - Secure Event Input (password fields, Terminal's secure keyboard entry) blocks injected keystrokes *(inferred: detect `IsSecureEventInputEnabled()` and bring the real window forward)*.
   - IME and caret bugs, and copy-paste bugs, are common in mirrored windows.
4. **Permissions.**
   - Screen Recording and Accessibility are both needed.
   - Sequoia asks again every month ([9to5mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/)), and a purple recording indicator shows.
   - Topit #31: screen capture blocks Apple Watch auto-unlock.
5. **DRM.** Protected video captures as black. Detect it and offer "open the real window".
6. **Hiding from screen sharing.** `sharingType = .none` is only best effort with ScreenCaptureKit-based sharers ([forum](https://developer.apple.com/forums/thread/808016)).
7. **Stage Manager.** There is no API to detect it ([forum](https://developer.apple.com/forums/thread/801933)). Test it.
8. **Mission Control.** Floats should stay put.
9. **Multiple monitors.** Restore floats to the right display. Attaching or detaching a virtual display rearranges windows.
10. **Notch and menu bar.** Keep floats below the menu bar, where Topit #29 had focus fights.
11. **Touch ID and authentication sheets.** These appear in separate system windows that won't show in a mirror. Bring the real app forward *(inferred)*.
12. **Focus theft.** The number one complaint. Never take focus on a Space switch, a hover or an update.

## 5. Prioritized features (from this research)

**MVP**
1. Float any window over every Space and full-screen apps, never stealing focus.
2. Fully interactive click, scroll and type, with explicit focus handoff back to the previous app.
3. Crisp text: the app thinks it has a small screen (virtual display or real resize), not a downscaled video.
4. A summon/dismiss hotkey; slide to the edge with hover-to-peek.
5. Opacity and ghost mode, with a hold-modifier override and a visible indicator.
6. An energy governor: skip idle frames, lower fps when the pointer is away, pause when slid away.
7. Honest states: paused, DRM black, secure input, source closed.
8. Clear permission onboarding.

**Next**
9. Multiple floats in a tab stack, a cycle hotkey, and "retarget to current window".
10. Per-app presets and an excluded-apps list.
11. Clipboard and drag-and-drop bridging.
12. Activity badges while slid away.
13. Region crop and zoom.
14. Restore after reboot and display changes.
15. Privacy options.

**Later**
16. Workspace snapshots.
17. Auto-fade and ⌘-scroll opacity.
18. Game Mode and presentation rules.
19. A compact tab switcher for browsers.
20. Streaming to an iPhone or iPad.
21. A CLI and Shortcuts support.

## 6. UX principles

1. **Never steal focus or your place.**
2. **Always legible and honest about state.** No silent freezes or black boxes.
3. **Present without being in the way.** One key or flick to stash, peek or summon; click-through is never a trap.
4. **Invisible cost.** Spend energy only when something changes and you're looking.
5. **Remember everything, configure nothing.**
