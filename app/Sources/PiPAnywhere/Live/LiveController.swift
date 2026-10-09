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

    private let model: PlayerModel
    private let panel: PanelController
    private var session: Session?
    private var cancellables = Set<AnyCancellable>()
    private var watchdog: Timer?
    private var fpsCap = 0
    private var fpsOverride: Int?
    private var lastStatsLog = Date.distantPast

    private struct Session {
        let app: NSRunningApplication
        let window: WindowMover.Window
        /// Where the window was on the desktop; restored on unfloat.
        let original: CGRect
        /// Current frame on the stage (global top-left points).
        var frame: CGRect
    }

    static let defaultSurfaceSize = CGSize(width: 1000, height: 660)

    init(model: PlayerModel, panel: PanelController, capture: StageCapture) {
        self.model = model
        self.panel = panel
        self.capture = capture
        bridge.surfaceRect = { [unowned panel] in panel.liveSurfaceRect }
        bridge.stageWindowRect = { [unowned self] in session?.frame ?? .zero }
        bridge.stageBounds = { [unowned self] in stage.bounds }
        bridge.onCursor = { [unowned model] in model.liveCursor = $0 }
        bridge.onCaptureChange = { [unowned self] captured in
            model.liveCaptured = captured
            applyFrameRateCap()
        }
        capture.onStats = { [unowned self] in statsUpdated($0) }
        panel.onLiveResize = { [unowned self] in resize(to: $0) }
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

    func float(_ app: NSRunningApplication) async {
        if session != nil { await unfloat() }
        guard permissionsGranted(prompt: true) else { return }
        guard stage.create(), await waitForStage(), let displayID = stage.displayID else {
            log("live: stage not ready")
            return
        }
        guard let window = WindowMover.mainWindow(of: app), let original = WindowMover.frame(of: window) else {
            log("live: \(app.localizedName ?? "app") has no window to float")
            return
        }

        // The window gets exactly the panel's surface size: the app lays itself out for
        // that size, and capture is 1:1 (sharp text, cursor speed unchanged).
        let work = stage.workArea
        let wanted = Settings.liveSurfaceSize ?? Self.defaultSurfaceSize
        let size = CGSize(width: min(max(wanted.width, PanelController.liveMinSize.width), work.width),
                          height: min(max(wanted.height, PanelController.liveMinSize.height), work.height))
        WindowMover.setFrame(window, CGRect(origin: work.origin, size: size))
        try? await Task.sleep(for: .milliseconds(150))
        let frame = WindowMover.frame(of: window) ?? CGRect(origin: work.origin, size: size)

        session = Session(app: app, window: window, original: original, frame: frame)
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
        if WindowMover.isAlive(s.window) { WindowMover.setFrame(s.window, s.original) }
        model.live = nil
        model.liveCursor = nil
        model.liveCaptured = false
        Settings.liveSurfaceSize = panel.liveSurfaceSize
        panel.exitLiveMode()
        panel.hide()
        stage.destroy()
        log("live: returned window to \(s.original.integral)")
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

    /// 60 fps while you're using it, 15 when visible but idle, ~1 when slid away or hidden.
    /// Unchanged frames are skipped by ScreenCaptureKit at any cap.
    private func applyFrameRateCap() {
        guard session != nil else { return }
        let cap: Int
        if let fpsOverride { cap = fpsOverride }
        else if model.isStashed || !panel.isVisible { cap = 1 }
        else if model.liveCaptured { cap = 60 }
        else { cap = 15 }
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
        if s.app.isTerminated || !WindowMover.isAlive(s.window) {
            model.live?.notice = "\(s.app.localizedName ?? "The app") closed"
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                await self.unfloat()
            }
            session = nil
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
        case "unfloat":
            Task { await unfloat() }
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
