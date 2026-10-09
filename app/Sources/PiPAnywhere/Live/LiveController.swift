import AppKit
import Combine
import ScreenCaptureKit

/// Live Apps: floats a real app window in the panel. The window is moved onto the
/// hidden stage, captured zero-copy into the panel, and driven with the real cursor.
@MainActor
final class LiveController {
    let stage = Stage()
    let capture: StageCapture
    let bridge = CursorBridge()
    /// The cursor drawn over the floated app (the real one is on the stage). A plain layer
    /// moved directly on every mouse move: no SwiftUI re-render per event.
    let cursorLayer: CALayer

    static func makeCursorLayer() -> CALayer {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 10
        return layer
    }

    private let model: PlayerModel
    private let panel: PanelController
    private var session: Session?
    private var cancellables = Set<AnyCancellable>()
    private var watchdog: Timer?
    private var fpsCap = 0
    private var fpsOverride: Int?
    private var lastStatsLog = Date.distantPast
    private var missedChecks = 0

    private struct Session {
        let app: NSRunningApplication
        let window: WindowMover.Window
        /// Where the window was on the desktop; restored on unfloat.
        let original: CGRect
        /// It was in native full screen; it goes back to full screen on unfloat.
        let wasFullScreen: Bool
        /// The window was opened just for floating (⌃⌥N): closing the float closes it.
        /// Otherwise it was the user's own window and goes back where it was.
        let owned: Bool
        /// Current frame on the stage (global top-left points).
        var frame: CGRect
    }

    static let defaultSurfaceSize = CGSize(width: 1000, height: 660)

    init(model: PlayerModel, panel: PanelController, capture: StageCapture, cursorLayer: CALayer) {
        self.model = model
        self.panel = panel
        self.capture = capture
        self.cursorLayer = cursorLayer
        bridge.surfaceRect = { [unowned panel] in panel.liveSurfaceRect }
        bridge.stageWindowRect = { [unowned self] in session?.frame ?? .zero }
        bridge.stageBounds = { [unowned self] in stage.bounds }
        bridge.onCursor = { [unowned self] in showCursor(at: $0) }
        bridge.onCaptureChange = { [unowned self] captured in
            model.liveCaptured = captured
            applyFrameRateCap()
        }
        capture.onStats = { [unowned self] in statsUpdated($0) }
        panel.onLiveResize = { [unowned self] in resize(to: $0) }
        panel.stageScreen = { [unowned self] in stage.screen }
        panel.liveMaxSurfaceSize = { [unowned self] in stage.isActive ? stage.workArea.size : nil }
        model.$isStashed.dropFirst().sink { [unowned self] stashed in
            if stashed { bridge.release() }
            DispatchQueue.main.async { self.applyFrameRateCap() }
        }.store(in: &cancellables)
    }

    var isFloating: Bool { session != nil }

    // MARK: Float / unfloat

    /// Floats the app the user is currently in (hotkey).
    func floatFrontmost() async {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        await float(app)
    }

    // MARK: A new browser window, just for floating (⌃⌥N)

    /// Chromium browsers accept "--new-window" from a second launch and hand it to the
    /// running browser, so a fresh window opens in the user's own profile, with their
    /// extensions and ad blocking.
    static let floatableBrowsers = ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac",
                                    "com.vivaldi.Vivaldi", "org.chromium.Chromium"]

    static var preferredBrowser: String? {
        floatableBrowsers.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    /// ⌃⌥N: float a new browser window, or close it if one is already floating.
    func toggleNewBrowserWindow() async {
        if let s = session, s.owned {
            await unfloat()
        } else if let browser = Self.preferredBrowser {
            await floatNewWindow(bundleID: browser)
        } else {
            log("live: no Chromium browser (Brave, Chrome, Edge…) installed")
        }
    }

    func floatNewWindow(bundleID: String) async {
        guard permissionsGranted(prompt: true),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        if session != nil { await unfloat() }
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
        let before = existing.map(WindowMover.windowIDs(of:)) ?? []

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--new-window"]
        config.activates = false
        // A second instance passes "--new-window" to the running browser, then exits.
        config.createsNewApplicationInstance = existing != nil
        let launched: NSRunningApplication
        do {
            launched = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            log("live: couldn't open a new window: \(error)")
            return
        }
        let app = existing ?? launched
        // Wait for the new window (a cold start can take a few seconds).
        for _ in 0..<160 {
            try? await Task.sleep(for: .milliseconds(50))
            if let window = WindowMover.standardWindows(of: app).first(where: { $0.windowID.map { !before.contains($0) } ?? false }) {
                log("live: new \(app.localizedName ?? "browser") window \(window.windowID ?? 0) opened for floating")
                await float(app, window: window, owned: true)
                return
            }
        }
        log("live: no new window appeared in \(app.localizedName ?? bundleID)")
    }

    // MARK: Float any window

    func float(_ app: NSRunningApplication, window chosen: WindowMover.Window? = nil, owned: Bool = false) async {
        if session != nil { await unfloat() }
        guard permissionsGranted(prompt: true) else { return }
        guard stage.create(), await waitForStage(), let displayID = stage.displayID else {
            log("live: stage not ready")
            return
        }
        let name = app.localizedName ?? "The app"
        guard let window = chosen ?? WindowMover.mainWindow(of: app) else {
            log("live: \(name) has no window to float")
            stage.destroy()
            return
        }
        // A native full-screen window can't be moved: take it out of full screen first
        // (it goes back to full screen when unfloated).
        let wasFullScreen = WindowMover.isFullScreen(window)
        if wasFullScreen {
            log("live: \(name) is in full screen; leaving full screen first")
            WindowMover.setFullScreen(window, false)
            for _ in 0..<40 where WindowMover.isFullScreen(window) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(900)) // let the exit animation finish
        }
        guard let original = WindowMover.frame(of: window) else {
            log("live: can't read \(name)'s window frame")
            stage.destroy()
            return
        }

        // The window gets exactly the panel's surface size: the app lays itself out for
        // that size, and capture is 1:1 (sharp text, cursor speed unchanged).
        let work = stage.workArea
        // A floating window, not a second screen: at most 70% of the main screen.
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let remembered = Settings.liveSurfaceSize ?? Self.defaultSurfaceSize
        let wanted = CGSize(width: min(remembered.width, screen.width * 0.7), height: min(remembered.height, screen.height * 0.7))
        let size = CGSize(width: min(max(wanted.width, PanelController.liveMinSize.width), work.width),
                          height: min(max(wanted.height, PanelController.liveMinSize.height), work.height))
        WindowMover.setFrame(window, CGRect(origin: work.origin, size: size))
        try? await Task.sleep(for: .milliseconds(150))
        let frame = WindowMover.frame(of: window) ?? .zero

        // Never capture a window that didn't make it onto the stage.
        guard stage.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            log("live: \(name)'s window didn't move to the stage (it's at \(frame.integral)); giving up")
            if wasFullScreen { WindowMover.setFullScreen(window, true) }
            stage.destroy()
            model.live = LiveInfo(appName: name, title: window.title, icon: app.icon,
                                  notice: "macOS didn't let \(name)'s window move. Try again, or un-tile it first.")
            panel.enterLiveMode(contentSize: CGSize(width: 520, height: 160))
            panel.show()
            Task {
                try? await Task.sleep(for: .seconds(4))
                if self.session == nil, self.model.live?.notice != nil {
                    self.model.live = nil
                    self.panel.exitLiveMode()
                    self.panel.hide()
                }
            }
            return
        }

        session = Session(app: app, window: window, original: original, wasFullScreen: wasFullScreen, owned: owned, frame: frame)
        missedChecks = 0
        bridge.targetPID = app.processIdentifier
        model.live = LiveInfo(appName: app.localizedName ?? "App", title: window.title, icon: app.icon)
        panel.enterLiveMode(contentSize: frame.size)
        panel.show()
        do {
            try await capture.start(displayID: displayID, pid: app.processIdentifier, sourceRect: stageLocal(frame),
                                    scale: stage.screen?.backingScaleFactor ?? 2, fps: 60)
            fpsCap = 60
        } catch {
            log("live: capture failed: \(error) · screen recording preflight \(CGPreflightScreenCaptureAccess())")
            model.live?.notice = Self.explain(error)
        }
        bridge.activate()
        startWatchdog()
        applyFrameRateCap()
        log("live: floating \(app.localizedName ?? "?") window \(frame.integral) · surface \(panel.liveSurfaceRect.integral)")
    }

    /// Puts the window back where it came from and leaves live mode.
    func unfloat() async {
        guard let s = session else { return }
        session = nil
        bridge.deactivate()
        watchdog?.invalidate()
        await capture.stop()
        if WindowMover.isAlive(s.window) {
            if s.owned {
                // Opened just for floating: closing the float closes it.
                WindowMover.close(s.window)
            } else {
                WindowMover.setFrame(s.window, s.original)
                if s.wasFullScreen {
                    try? await Task.sleep(for: .milliseconds(300))
                    WindowMover.setFullScreen(s.window, true)
                }
            }
        }
        model.live = nil
        showCursor(at: nil)
        model.liveCaptured = false
        Settings.liveSurfaceSize = panel.liveSurfaceSize
        panel.exitLiveMode()
        panel.hide()
        stage.destroy()
        log(s.owned ? "live: closed the floating window" : "live: returned window to \(s.original.integral)")
    }

    /// The panel was resized: resize the real window to match (the app re-lays out).
    private func resize(to size: CGSize) {
        guard var s = session else { return }
        WindowMover.setFrame(s.window, CGRect(origin: s.frame.origin, size: size))
        let actual = WindowMover.frame(of: s.window) ?? CGRect(origin: s.frame.origin, size: size)
        s.frame = actual
        session = s
        // Apps can refuse sizes below their minimum; follow what the window really is.
        if abs(actual.width - size.width) > 1 || abs(actual.height - size.height) > 1 {
            panel.setLiveSurfaceSize(actual.size)
        }
        let rect = stageLocal(actual)
        Task { await capture.update(sourceRect: rect, scale: stage.screen?.backingScaleFactor ?? 2) }
        log("live: resized window to \(actual.size)")
    }

    // MARK: Energy governor

    /// Up to 60 fps whenever visible (video and scrolling must stay smooth even when you're
    /// only watching); ~1 when slid away or hidden. Unchanged frames are skipped by
    /// ScreenCaptureKit at any cap, so a still app costs almost nothing either way.
    private func applyFrameRateCap() {
        guard session != nil else { return }
        let cap: Int
        if let fpsOverride { cap = fpsOverride }
        else if model.isStashed || !panel.isVisible { cap = 1 }
        else { cap = 60 }
        guard cap != fpsCap else { return }
        fpsCap = cap
        Task { await capture.update(fps: cap) }
        log("live: frame-rate cap \(cap)")
    }

    private func statsUpdated(_ stats: StageCapture.Stats) {
        guard Date().timeIntervalSince(lastStatsLog) >= 5 else { return }
        lastStatsLog = Date()
        log("live stats: \(stats.complete) new frames/s, \(stats.idle) idle/s, cap \(fpsCap)")
    }

    // MARK: Watchdog

    /// Notices the app quitting or its window closing, and follows the window if the
    /// app moved or resized it itself.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSession() }
        }
    }

    private func checkSession() {
        guard var s = session else { return }
        // Only "gone" counts, and twice in a row: a busy app can briefly not answer.
        let liveness = s.app.isTerminated ? .gone : WindowMover.liveness(s.window)
        missedChecks = liveness == .gone ? missedChecks + 1 : 0
        if liveness != .alive && missedChecks < 2 { return }
        if missedChecks >= 2 {
            model.live?.notice = "\(s.app.localizedName ?? "The app") closed"
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                await self.unfloat()
            }
            watchdog?.invalidate()
            return
        }
        if let frame = WindowMover.frame(of: s.window), frame != s.frame {
            s.frame = frame
            session = s
            if abs(frame.width - panel.liveSurfaceSize.width) > 1 || abs(frame.height - panel.liveSurfaceSize.height) > 1 {
                panel.setLiveSurfaceSize(frame.size)
            }
            Task { await capture.update(sourceRect: stageLocal(frame)) }
        }
    }

    // MARK: Cursor overlay

    private func showCursor(at point: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let point {
            let cursor = NSCursor.currentSystem ?? .arrow
            let image = cursor.image
            if cursorLayer.contents as AnyObject? !== image { cursorLayer.contents = image }
            cursorLayer.bounds = CGRect(origin: .zero, size: image.size)
            cursorLayer.anchorPoint = CGPoint(x: cursor.hotSpot.x / max(image.size.width, 1), y: cursor.hotSpot.y / max(image.size.height, 1))
            cursorLayer.position = point
            cursorLayer.isHidden = false
        } else {
            cursorLayer.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: Helpers

    private func stageLocal(_ frame: CGRect) -> CGRect {
        frame.offsetBy(dx: -stage.bounds.minX, dy: -stage.bounds.minY)
    }

    /// A new display takes a moment to be configured (it reports 0×0 at first).
    private func waitForStage() async -> Bool {
        for _ in 0..<60 {
            if stage.bounds.width > 0, stage.screen != nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func permissionsGranted(prompt: Bool) -> Bool {
        let accessibility = WindowMover.isTrusted(prompt: prompt)
        var screen = CGPreflightScreenCaptureAccess()
        if !screen && prompt { screen = CGRequestScreenCaptureAccess() }
        if !accessibility || !screen {
            log("live: permissions: Accessibility \(accessibility ? "granted" : "MISSING"), Screen Recording \(screen ? "granted" : "MISSING")")
        }
        return accessibility && screen
    }

    // MARK: Scripted commands ("live:<command>")

    func run(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map { String($0) }
        let argument = parts.count > 1 ? parts[1] : nil
        switch parts.first {
        case "stage":
            if argument == "destroy" { stage.destroy() } else { stage.create() }
        case "status":
            log("live: \(stage.describe()) · floating \(session.map { "\($0.app.localizedName ?? "?") at \($0.frame.integral)" } ?? "nothing") · surface \(panel.liveSurfaceRect.integral) · captured \(bridge.isCaptured) · cap \(fpsCap)")
        case "diagnose":
            Task { await diagnose() }
        case "permissions":
            log("live: permissions \(permissionsGranted(prompt: true) ? "all granted" : "requested")")
        case "float":
            if let argument, let app = Self.findApp(argument) {
                Task { await float(app) }
            } else if argument == nil {
                Task { await floatFrontmost() }
            } else {
                log("live: no running app matches '\(argument ?? "")'")
            }
        case "newwindow":
            Task { await toggleNewBrowserWindow() }
        case "unfloat":
            Task { await unfloat() }
        case "size":
            let n = (argument ?? "").split(separator: ",").compactMap { Double($0) }
            if n.count == 2 { panel.setLiveSurfaceSize(CGSize(width: n[0], height: n[1])) }
        case "release":
            bridge.release()
        case "fps":
            fpsOverride = argument.flatMap(Int.init)
            fpsCap = 0
            applyFrameRateCap()
        default:
            log("live: unknown command \(command)")
        }
    }

    /// A notice that says what actually went wrong.
    static func explain(_ error: Error) -> String {
        let ns = error as NSError
        // ScreenCaptureKit "user declined" (-3801): permission missing or not yet applied.
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            return CGPreflightScreenCaptureAccess()
                ? "Screen Recording was just allowed: quit and reopen PiP Anywhere to apply it"
                : "Allow Screen Recording for PiP Anywhere in System Settings"
        }
        return "Can't capture: \(ns.localizedDescription)"
    }

    /// Checks everything Live Apps needs and logs the result ("live:diagnose").
    func diagnose() async {
        log("diagnose: accessibility \(WindowMover.isTrusted(prompt: false)) · screen recording preflight \(CGPreflightScreenCaptureAccess()) · CGVirtualDisplay \(stage.isActive ? "active" : "available") · \(Bundle.main.bundlePath)")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            log("diagnose: shareable content OK · \(content.displays.count) displays \(content.displays.map(\.displayID)) · \(content.applications.count) apps · \(content.windows.count) windows")
        } catch {
            let ns = error as NSError
            log("diagnose: shareable content FAILED · \(ns.domain) \(ns.code) · \(ns.localizedDescription)")
        }
    }

    /// By pid, bundle identifier, or app name.
    static func findApp(_ query: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let pid = pid_t(query) { return apps.first { $0.processIdentifier == pid } }
        return apps.first { $0.bundleIdentifier == query }
            ?? apps.first { $0.localizedName?.localizedCaseInsensitiveCompare(query) == .orderedSame }
    }
}

/// Synthetic input for automated tests ("debug:<command>"). Needs Accessibility.
/// Coordinates are global points, origin at the main display's top-left.
enum DebugInput {
    static func run(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map { String($0) }
        guard let name = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        let numbers = argument.split(separator: ",").compactMap { Double($0) }
        let point = numbers.count >= 2 ? CGPoint(x: numbers[0], y: numbers[1]) : nil
        switch name {
        case "move": if let point { post(.mouseMoved, at: point) }
        case "click":
            if let point {
                post(.mouseMoved, at: point)
                post(.leftMouseDown, at: point)
                post(.leftMouseUp, at: point)
            }
        case "clickhere":
            // Click wherever the cursor is now (e.g. after it was handed to the stage).
            if let here = CGEvent(source: nil)?.location {
                post(.leftMouseDown, at: here)
                post(.leftMouseUp, at: here)
            }
        case "type": type(argument)
        case "key": if let code = CGKeyCode(argument) { key(code) }
        default: log("debug: unknown command \(command)")
        }
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
    }

    private static func type(_ text: String) {
        for scalar in text.utf16 {
            var unit = scalar
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                event?.post(tap: .cghidEventTap)
                usleep(8_000)
            }
        }
    }

    private static func key(_ code: CGKeyCode) {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
