# Changelog

## Unreleased

### Changed
- Slide to the edge / bring back is now `⌃⌥Z` (was `⌃⌥P`), so it's easy to press with one hand.

## 0.4.0: 2026-10-15

Two new things can float, next to video.

### Added: Floating browser (`⌃⌥N`, no permissions)
- A WebKit browser that lives entirely inside the floating window: tabs, address bar (a URL or a search), back/forward/reload, zoom, kept logins, tabs restored, and downloads.
- **Built-in ad and tracker blocking.**
  - EasyList and EasyPrivacy are converted to WebKit content rules (about 111k network and 10k element-hiding rules). They're compiled once and refreshed every 4 days.
  - YouTube ads are skipped in the page.
- **Web extensions** (macOS 15.4+): unpacked extensions in the Extensions folder load with the permissions they ask for.
- "Open Brave's / Chrome's / Safari's current tab here", and send a page back to your browser.

### Added: Live Apps (beta)
- Float a real app window, fully usable, with genuine clicks and typing:
  - `⌃⌥⇧N` opens a new Brave window just for floating; it closes with the float.
  - `⌃⌥F` floats the app you're in; it goes back where it was.
- The window lives on a hidden virtual display, so it never stops rendering. ScreenCaptureKit shows it zero-copy, and your real cursor is handed to it while you point at the floating window.
- Resizing the floating window resizes the app. In full screen, the app fills the floating window.
- Full-screen windows are taken out of full screen to float, and put back afterwards.
- Up to 60 fps while visible, and about 1 fps when slid away.

### Changed
- The menu has three sections (Video, Floating browser, Live Apps). The status icon shows the mode.
- Settings moved into a submenu. Shortcuts are grouped by mode.
- A new app icon.
- The resize arrow only shows in the edge and corner zones.
- The floating window can never end up on the hidden display.
- A log file is kept at `~/Library/Logs/PiP Anywhere/PiPAnywhere.log`.
- `scripts/bundle.sh` takes an optional `SIGN_IDENTITY`, so Live Apps permissions survive rebuilds.

## 0.3.0: 2026-10-09

### Added
- Volume and mute: speaker button, `⌃⌥M`, or scroll up/down over the video.
- Scroll sideways over the video to seek 5 s, with an on-screen confirmation ("+5 s", "Volume 40%").
- Double-click to switch between big (half the screen) and your size.
- Menu → *Size* presets and *Move to corner*.
- *Mute while slid to edge* option.
- A thin progress line while the controls are hidden.
- A list of keyboard shortcuts in the menu.

### Changed
- The video behind the slid-away strip is heavily blurred, so the strip can't reveal it.
- Minimum window width is 200 pt (was 120 pt), so the window can't shrink out of sight.
- Larger resize grab zones.

### Fixed
- Bringing the window back from the edge returns it to exactly where it was. Before, an old position could be reused, so it often ended up at the side.
- The resize cursor now shows on the edges and corners. The app never becomes active, so macOS had been ignoring its cursor changes.

## 0.2.0: 2026-10-08

### Added
- The window stays perfectly still while you swipe between desktops.
- Free placement anywhere, including half off-screen. Corner snapping is now optional.
- Resizing from any edge or corner, pinch, and `⌃⌥=` / `⌃⌥-`, from small up to the full screen.
- 2.85× playback speed.

### Changed
- Capture and encoding run at up to 60 fps (was 30). Output resolution goes up to 2560 px.

### Fixed
- Frame drops no longer snowball. A frame skipped before encoding had been forcing a key frame.

## 0.1.0: 2026-10-08

First version:
- A Mac menu-bar app with a floating window that stays visible over full-screen apps and on every desktop.
- A Chromium extension that captures the tab, crops it to the video, and streams H.264 to the app.
- Hover controls (play/pause, ±10 s, seek, speed, back to tab), slide to the edge, ghost mode, opacity, hide from screen sharing, global shortcuts.
- A scriptable command interface, unit tests, end-to-end tests, and window-server probes.
