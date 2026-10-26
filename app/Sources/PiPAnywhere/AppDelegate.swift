import AppKit
import Combine
import ScreenCaptureKit
import PiPCore
import ServiceManagement

struct LaunchOptions {
    var testPattern = false
    var showControls = false
    var snapshotPath: String?
    var quitAfter: Double?
    var port = WireProtocol.port

    init(_ arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--test-pattern": testPattern = true
            case "--show-controls": showControls = true
            case "--snapshot": snapshotPath = it.next()
            case "--quit-after": quitAfter = it.next().flatMap(Double.init)
            case "--port": port = it.next().flatMap(UInt16.init) ?? port
            default: break
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private let model = PlayerModel()
    private let renderer = VideoRenderer()
    private lazy var testPattern = TestPattern(renderer: renderer)
    private var server: MediaServer!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var hideTask: Task<Void, Never>?
    private var lastStatsLog = Date.distantPast
    private var live: LiveController!
    private let browser = BrowserModel()
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    /// The app the user was in before opening our menu ("Float the app I'm in").
    private var lastUserApp: NSRunningApplication?
    /// Why the extension last stopped the video (fixed enum), for the window_closed event.
    private var lastStopReason = "dropped"

    init(options: LaunchOptions) {
        self.options = options
        if options.port != WireProtocol.port { Settings.useSeparateStore(for: options.port) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SkyLight.allowCursorChangesInBackground()
        // Test copies on another port never report usage.
        UsageReporter.shared.active = options.port == WireProtocol.port
        UsageReporter.shared.onDaily = { [weak self] in self?.recordDailySnapshot() }
        UsageReporter.shared.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                UsageReporter.shared.count("space_switch", ["mode": self.currentMode, "stay_still": String(Settings.stayStillOnSpaceSwitch)])
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { self?.lastUserApp = app }
        }
        let capture = StageCapture()
        let cursorLayer = LiveController.makeCursorLayer()
        panel = PanelController(model: model, videoLayer: renderer.layer, liveLayer: capture.layer, cursorLayer: cursorLayer, browser: browser) { [unowned self] controller in
            PanelActions(
                dragChanged: { controller.dragChanged() },
                dragEnded: { controller.dragEnded() },
                magnifyChanged: { controller.magnifyChanged($0) },
                magnifyEnded: { controller.magnifyEnded() },
                resizeChanged: { controller.resizeChanged($0) },
                resizeEnded: { controller.resizeEnded() },
                toggleStash: { controller.toggleStash() },
                toggleZoom: { controller.toggleZoom() },
                close: { self.closeStream(how: "close_button") },
                liveHover: { self.live.bridge.enter(at: $0) },
                liveReturn: { Task { await self.live.unfloat(how: "return_button") } }
            )
        }
        live = LiveController(model: model, panel: panel, capture: capture, cursorLayer: cursorLayer)
        model.sendCommand = { [unowned self] action, value in self.send(.command(action, value: value)) }
        setUpServer()
        setUpStatusItem()
        setUpHotKeys()
        setUpBrowserShortcuts()

        DistributedNotificationCenter.default().addObserver(forName: Settings.reloadNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.applySettings()
                log("settings reloaded (level \(Settings.level.rawValue))")
            }
        }

        // Scriptable control, e.g. from Shortcuts or tests: post "local.pipanywhere.command"
        // with object "toggle", "seek:-10", "rate:1.5", "window:stash", ... (spikes/send-command.swift)
        // Copies on other ports (tests) only answer "<name>.<port>".
        var commandNames = [Notification.Name("\(Settings.commandNotification.rawValue).\(options.port)")]
        if options.port == WireProtocol.port { commandNames.append(Settings.commandNotification) }
        for name in commandNames {
            DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let parts = (note.object as? String ?? "").split(separator: ":", maxSplits: 1).map { String($0) }
                guard let name = parts.first else { return }
                let argument = parts.count > 1 ? parts[1] : nil
                MainActor.assumeIsolated {
                    log("scripted command: \(name) \(argument ?? "")")
                    let known = ["window", "browser", "live", "debug", "snapshot"].contains(name) || CommandAction(rawValue: name) != nil
                    UsageReporter.shared.count("scripted_command", ["kind": known ? name : "other"])
                    self?.runScripted(name, argument)
                }
            }
        }

        if options.testPattern { startTestPattern() }
        if options.showControls { model.hovering = true }
        if let path = options.snapshotPath {
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                self.snapshot(to: path)
            }
        }
        if let seconds = options.quitAfter {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Streaming

    private func setUpServer() {
        let renderer = renderer
        let model = model
        server = MediaServer(port: options.port, allowedOrigins: [WireProtocol.extensionOrigin], queue: renderer.queue)
        let server = server!
        server.onConnect = {
            server.send(.hello)
            DispatchQueue.main.async {
                model.connected = true
                UsageReporter.shared.count("ext_connected")
            }
        }
        server.onDisconnect = { [weak self] in
            renderer.reset()
            DispatchQueue.main.async {
                UsageReporter.shared.count("ext_disconnected")
                self?.streamEnded()
            }
        }
        server.onRejected = {
            DispatchQueue.main.async { UsageReporter.shared.count("ext_rejected") }
        }
        server.onMessage = { [weak self] message in
            switch message {
            case let .config(config):
                log("config: \(config.codec) \(config.width)×\(config.height) from \(config.sourceWidth ?? 0)×\(config.sourceHeight ?? 0) tab")
                renderer.configure(config)
                DispatchQueue.main.async { self?.streamStarted(config) }
            case let .state(state):
                DispatchQueue.main.async { model.update(state) }
            case let .stop(reason):
                log("stream stopped: \(reason)")
                renderer.reset()
                DispatchQueue.main.async {
                    let mapped = UsageCatalog.stopReason(reason)
                    self?.lastStopReason = mapped
                    UsageReporter.shared.count("video_stream_stopped", ["reason": mapped])
                    self?.streamEnded()
                }
            case let .hello(version, ext):
                log("extension hello (protocol \(version), extension \(ext ?? "?"))")
                DispatchQueue.main.async {
                    UsageReporter.shared.count("ext_hello", ["ext_version": ext ?? "old", "protocol": version == WireProtocol.version ? version : "other"])
                }
            case let .usage(items):
                DispatchQueue.main.async {
                    for item in items { UsageReporter.shared.count(item.name, item.props, by: item.count, day: item.day) }
                }
            case let .unknown(type):
                log("unknown message type \(type)")
            }
        }
        server.onVideo = { renderer.enqueue($0) }
        renderer.onNeedKeyframe = { server.send(.keyframe) }
        renderer.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.statsUpdated(stats) }
        }
        do {
            try server.start()
        } catch {
            UsageReporter.shared.failed("video", "server_start_failed")
            UsageReporter.shared.nonFatal("server.start", error)
            log("could not start server on port \(options.port): \(error)")
        }
    }

    private func send(_ message: Outbound) {
        if model.testPattern {
            if case .command(.close, _) = message { stopTestPattern(how: "close_button") }
            return
        }
        let server = server!
        renderer.queue.async { server.send(message) }
    }

    private func streamStarted(_ config: StreamConfig) {
        if UsageReporter.shared.isOpen("video") {
            UsageReporter.shared.count("video_reconfigured")
        } else {
            UsageReporter.shared.windowStarted(mode: "video", source: "extension", [
                "res": UsageCatalog.resolutionBucket(height: config.height),
                "behind": model.live != nil || model.browserActive,
            ])
        }
        lastStopReason = "dropped"
        hideTask?.cancel()
        // The window is showing a live app or the browser; the video keeps decoding but isn't shown.
        if model.live != nil || model.browserActive { return }
        if model.testPattern { stopTestPattern(how: "replaced") }
        model.connected = true
        panel.setVideoSize(width: config.width, height: config.height)
        panel.show()
    }

    private func streamEnded() {
        let fps = model.stats.fps
        model.connected = false
        model.playback = nil
        model.stats = StreamStats()
        guard !model.testPattern else { return }
        // Short grace period: the extension reconnects when the crop size changes.
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !self.model.connected else { return }
            UsageReporter.shared.windowEnded(mode: "video", how: "stream_ended", ["reason": self.lastStopReason, "fps": UsageCatalog.fpsBucket(max(fps, self.peakFps))])
            self.peakFps = 0
            self.panel.hide()
        }
    }

    /// Highest frame rate seen in this video session (usage: fps bucket at close).
    private var peakFps = 0

    private func closeStream(how: String) {
        if model.browserActive {
            closeBrowser(how: how)
        } else if live.isFloating {
            Task { await live.unfloat(how: how) }
        } else if model.testPattern {
            stopTestPattern(how: how)
        } else {
            UsageReporter.shared.windowEnded(mode: "video", how: how, ["fps": UsageCatalog.fpsBucket(peakFps)])
            peakFps = 0
            send(.command(.close))
            panel.hide()
        }
    }

    private func statsUpdated(_ stats: StreamStats) {
        model.stats = stats
        peakFps = max(peakFps, stats.fps)
        if Date().timeIntervalSince(lastStatsLog) >= 5 {
            lastStatsLog = Date()
            let playback = model.playback.map {
                " · \($0.paused ? "paused" : "playing") \(formatTime(model.currentTime())) @\($0.rate)× '\($0.title)'"
            } ?? ""
            log("stats: \(stats.summary)\(playback)")
        }
    }

    private func startTestPattern() {
        UsageReporter.shared.windowStarted(mode: "test", source: "menu")
        model.testPattern = true
        panel.setVideoSize(width: 1280, height: 720)
        panel.show()
        let pattern = testPattern
        renderer.queue.async { pattern.start() }
    }

    private func stopTestPattern(how: String = "menu") {
        UsageReporter.shared.windowEnded(mode: "test", how: how)
        let pattern = testPattern
        let renderer = renderer
        renderer.queue.async {
            pattern.stop()
            renderer.reset()
        }
        model.testPattern = false
        model.stats = StreamStats()
        panel.hide()
    }

    // MARK: Floating browser

    /// Shows the built-in browser (restoring its tabs), optionally opening `url` in a new tab.
    /// `source`: menu, shortcut, current_tab, script (fixed enum, for anonymous usage).
    func openBrowser(_ url: URL? = nil, source: String = "menu", browserKind: String? = nil) {
        let began = Date()
        if live.isFloating { Task { await live.unfloat(how: "replaced") } }
        if model.testPattern { stopTestPattern(how: "replaced") }
        Task {
            await browser.prepare() // extensions + ad blocker, before the first tab
            let restored = browser.tabs.isEmpty ? Settings.browserTabs.count : browser.tabs.count
            browser.restoreSession()
            var props: [String: Any] = [
                "restored_tabs": UsageCatalog.countBucket(restored),
                "ms": UsageCatalog.latencyBucket(ms: Date().timeIntervalSince(began) * 1000),
            ]
            if let browserKind { props["from_browser"] = browserKind }
            UsageReporter.shared.windowStarted(mode: "browser", source: source, props)
            if let url { browser.newTab(url) }
            model.browserActive = true
            let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            let size = Settings.browserSize ?? CGSize(width: min(1000, screen.width * 0.6), height: min(700, screen.height * 0.7))
            panel.enterBrowserMode(size: size)
            panel.show()
            panel.focus()
            log("browser: open with \(browser.tabs.count) tab(s)")
        }
    }

    func closeBrowser(how: String = "menu") {
        guard model.browserActive else { return }
        UsageReporter.shared.windowEnded(mode: "browser", how: how, ["tabs": UsageCatalog.countBucket(browser.tabs.count)])
        browser.saveSession()
        Settings.browserSize = panel.panel.frame.size
        model.browserActive = false
        panel.exitLiveMode()
        panel.hide()
        log("browser: closed (tabs kept)")
    }

    func toggleBrowser() {
        if model.browserActive {
            if model.isStashed { panel.toggleStash() } else { closeBrowser(how: "shortcut") }
        } else {
            openBrowser(source: "shortcut")
        }
    }

    /// Asks Brave / Chrome / Safari for its current tab's address (Apple Events; macOS asks once).
    private func currentTabURL(of appName: String) -> URL? {
        let source = appName == "Safari"
            ? "tell application \"Safari\" to return URL of current tab of front window"
            : "tell application \"\(appName)\" to return URL of active tab of front window"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: the user hasn't allowed Automation for that browser.
            UsageReporter.shared.failed("browser", code == -1743 ? "current_tab_not_allowed" : "current_tab_unreadable",
                                        ["from_browser": Self.browserKind(appName)])
        }
        if let error { log("browser: couldn't read \(appName)'s tab: \(error[NSAppleScript.errorMessage] ?? error)") }
        return result?.stringValue.flatMap(URL.init(string:))
    }

    /// Fixed enum for one of `knownBrowsers` (never anything the user typed or named).
    private static func browserKind(_ appName: String) -> String {
        switch appName {
        case "Brave Browser": "brave"
        case "Google Chrome": "chrome"
        case "Safari": "safari"
        case "Arc": "arc"
        case "Microsoft Edge": "edge"
        default: "other"
        }
    }

    private static let knownBrowsers = [
        ("com.brave.Browser", "Brave Browser"), ("com.google.Chrome", "Google Chrome"),
        ("com.apple.Safari", "Safari"), ("company.thebrowser.Browser", "Arc"), ("com.microsoft.edgemac", "Microsoft Edge"),
    ]

    /// ⌘-shortcuts while the floating browser has the keyboard. A menu-bar app has no
    /// Edit menu, so copy/paste/undo are routed here too.
    private func setUpBrowserShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread; only a Bool leaves the isolated block.
            nonisolated(unsafe) let keyEvent = event
            let handled = MainActor.assumeIsolated {
                guard let self, self.model.browserActive, self.panel.panel.isKeyWindow else { return false }
                return self.handleBrowserKey(keyEvent)
            }
            return handled ? nil : event
        }
    }

    private func handleBrowserKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let tab = browser.selected
        let track = { (action: String) in UsageReporter.shared.count("browser_action", ["action": action, "via": "keyboard"]) }
        if flags == .control, event.keyCode == 48 { track("next_tab"); browser.selectNext(1); return true }           // ⌃Tab
        if flags == [.control, .shift], event.keyCode == 48 { track("previous_tab"); browser.selectNext(-1); return true } // ⌃⇧Tab
        let edit: Selector? = switch (flags, key) {
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        if let edit {
            track("edit_command")
            return NSApp.sendAction(edit, to: nil, from: nil)
        }
        guard flags == .command || flags == [.command, .shift] else { return false }
        switch key {
        case "t": track("new_tab"); browser.newTab()
        case "w": track("close_tab"); if let tab { browser.close(tab) }; if browser.isEmpty { closeBrowser(how: "last_tab_closed") }
        case "l": track("address_bar"); browser.focusAddressBar += 1
        case "r": track("reload"); tab?.webView.reload()
        case "[": track("back"); tab?.webView.goBack()
        case "]": track("forward"); tab?.webView.goForward()
        case "=", "+": track("zoom_in"); tab.map { $0.webView.pageZoom = min($0.webView.pageZoom + 0.1, 3) }
        case "-": track("zoom_out"); tab.map { $0.webView.pageZoom = max($0.webView.pageZoom - 0.1, 0.3) }
        case "0": track("zoom_reset"); tab?.webView.pageZoom = 1
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            track("select_tab_number")
            let index = Int(key)! - 1
            if index < browser.tabs.count { browser.select(browser.tabs[key == "9" ? browser.tabs.count - 1 : index]) }
        default: return false
        }
        return true
    }

    /// "window:stash|unstash|show|hide|ghost" or a playback action ("seek:-10").
    private func runScripted(_ name: String, _ argument: String?) {
        if name == "window" {
            switch argument {
            case "stash": if !model.isStashed { panel.toggleStash() }
            case "unstash": panel.unstash()
            case "show": panel.show()
            case "hide": panel.hide()
            case "ghost": panel.toggleGhost()
            case "grow": panel.scale(by: 1.15)
            case "shrink": panel.scale(by: 1 / 1.15)
            case "zoom": panel.toggleZoom()
            case let arg? where arg.hasPrefix("width:"):
                if let width = Double(arg.dropFirst(6)) { panel.setWidth(width) }
            case let arg? where arg.hasPrefix("moveto:"):
                let n = arg.dropFirst(7).split(separator: ",").compactMap { Double($0) }
                if n.count == 2 { panel.moveOrigin(to: NSPoint(x: n[0], y: n[1])) }
            case let arg? where arg.hasPrefix("corner:"):
                if let corner = ScreenCorner(rawValue: String(arg.dropFirst(7))) { panel.move(to: corner) }
            default: break
            }
        } else if name == "browser" {
            switch argument {
            case "close": closeBrowser(how: "script")
            case let arg? where arg.hasPrefix("eval:"):
                // Debug: run JavaScript (may return a promise) in the current tab and log the result.
                let script = String(arg.dropFirst(5))
                Task {
                    do {
                        let result = try await browser.selected?.webView.callAsyncJavaScript(script, contentWorld: .page)
                        log("browser eval: \(result.map { "\($0)" } ?? "nil")")
                    } catch {
                        log("browser eval failed: \(error.localizedDescription)")
                    }
                }
            case let arg? where arg.hasPrefix("open:"): openBrowser(URL(string: String(arg.dropFirst(5))), source: "script")
            default: openBrowser(source: "script")
            }
        } else if name == "live", let argument {
            live.run(argument)
        } else if name == "debug", let argument {
            DebugInput.run(argument)
        } else if name == "snapshot", let path = argument {
            snapshot(to: path)
        } else if let action = CommandAction(rawValue: name) {
            model.command(action, argument.flatMap(Double.init), via: "script")
        }
    }

    // MARK: Hotkeys

    private func setUpHotKeys() {
        let keys = CountingHotKeys()
        keys.register(.toggleStash) { [unowned self] in
            if !panel.isVisible, model.connected || model.testPattern { panel.show() } else { panel.toggleStash() }
        }
        keys.register(.playPause) { [unowned self] in model.command(.toggle, via: "shortcut") }
        keys.register(.back10) { [unowned self] in model.seek(by: -10, via: "shortcut") }
        keys.register(.forward10) { [unowned self] in model.seek(by: 10, via: "shortcut") }
        keys.register(.mute) { [unowned self] in model.toggleMute(via: "shortcut") }
        keys.register(.ghost) { [unowned self] in panel.toggleGhost() }
        keys.register(.backToTab) { [unowned self] in model.command(.focusTab, via: "shortcut") }
        keys.register(.toggleBrowser) { [unowned self] in toggleBrowser() }
        keys.register(.floatNewBrowserWindow) { [unowned self] in Task { await self.live.toggleNewBrowserWindow(source: "shortcut_new_window") } }
        keys.register(.floatFrontmost) { [unowned self] in Task { await self.live.floatFrontmost(source: "shortcut_frontmost") } }
        keys.register(.releaseCursor) { [unowned self] in live.bridge.release() }
        keys.register(.grow) { [unowned self] in panel.scale(by: 1.15) }
        keys.register(.shrink) { [unowned self] in panel.scale(by: 1 / 1.15) }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if options.port != WireProtocol.port {
            // Copies started for testing must never be mistaken for the real app.
            statusItem.button?.title = "TEST"
            statusItem.button?.font = .systemFont(ofSize: 9, weight: .bold)
            statusItem.button?.imagePosition = .imageLeading
            statusItem.button?.toolTip = "PiP Anywhere — test copy (port \(options.port))"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
        // The icon shows the mode: idle, a video popped out, or an app floating.
        Publishers.CombineLatest4(model.$connected, model.$testPattern, model.$live.map { $0 != nil }, model.$browserActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
    }

    private func updateStatusIcon() {
        let symbol: String
        let description: String
        if model.browserActive {
            symbol = "globe"
            description = "PiP Anywhere — floating browser"
        } else if model.live != nil {
            symbol = "macwindow.on.rectangle"
            description = "PiP Anywhere — app floating"
        } else if model.connected || model.testPattern {
            symbol = "pip.fill"
            description = "PiP Anywhere — video popped out"
        } else {
            symbol = "pip"
            description = "PiP Anywhere"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    }

    /// What the floating window is showing (fixed enum for usage): browser, live, video, test, none.
    private var currentMode: String {
        model.browserActive ? "browser" : model.live != nil ? "live" : model.testPattern ? "test" : model.connected ? "video" : "none"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        UsageReporter.shared.count("menu_opened", ["mode": currentMode])
        menu.removeAllItems()
        if options.port != WireProtocol.port {
            menu.addItem(.disabled("Test copy · port \(options.port) · separate settings"))
            menu.addItem(.separator())
        }

        // ── Video picture-in-picture ──
        menu.addItem(.sectionHeader(title: "Video picture-in-picture"))
        if model.testPattern {
            menu.addItem(.disabled("● Showing test pattern"))
        } else if model.connected {
            menu.addItem(.disabled("● \(model.playback?.title ?? "Video")"))
            menu.addItem(.disabled("    \(model.stats.summary)"))
        } else {
            menu.addItem(.disabled("Not active — press ⌥⇧P on a video in the browser"))
        }
        menu.addItem(ClosureMenuItem(model.testPattern ? "Stop test pattern" : "Show test pattern", id: "test_pattern") { [unowned self] in
            model.testPattern ? stopTestPattern() : startTestPattern()
        })

        // ── Floating browser ──
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Floating browser — built in, no permissions"))
        if model.browserActive {
            menu.addItem(.disabled("● \(browser.tabs.count) tab\(browser.tabs.count == 1 ? "" : "s") open"))
            menu.addItem(ClosureMenuItem("Close the floating browser  (⌃⌥N)", id: "browser_close") { [unowned self] in closeBrowser(how: "menu") })
        } else {
            menu.addItem(ClosureMenuItem("Open the floating browser  (⌃⌥N)", id: "browser_open") { [unowned self] in openBrowser(source: "menu") })
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for (bundleID, name) in Self.knownBrowsers where running.contains(bundleID) {
            menu.addItem(ClosureMenuItem("Open \(name)'s current tab here", id: "browser_current_tab") { [unowned self] in
                if let url = currentTabURL(of: name) { openBrowser(url, source: "current_tab", browserKind: Self.browserKind(name)) }
            })
        }
        menu.addItem(ClosureMenuItem("Block ads and trackers, skip YouTube ads", checked: Settings.blockAds, id: "block_ads") { [unowned self] in
            Settings.blockAds.toggle()
            settingChanged("block_ads", Settings.blockAds)
            browser.applyContentBlocking()
        })
        menu.addItem(ClosureMenuItem("Extensions…", id: "extensions_folder") { [unowned self] in browser.revealExtensionsFolder() })

        // ── Live Apps ──
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Live Apps (beta) — real apps, fully usable"))
        let browserName = LiveController.preferredBrowser
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        if let info = model.live {
            menu.addItem(.disabled("● \(info.appName)\(info.title.isEmpty ? "" : " — \(info.title)")"))
            menu.addItem(ClosureMenuItem("Close the floating window", id: "live_close") { [unowned self] in Task { await live.unfloat(how: "menu") } })
            if model.liveCaptured {
                menu.addItem(ClosureMenuItem("Release the cursor  (⌃⌥E)", id: "live_release_cursor") { [unowned self] in live.bridge.release() })
            }
        } else {
            menu.addItem(.disabled("Not active"))
        }
        if let browserName {
            menu.addItem(ClosureMenuItem("Float a new \(browserName) window  (⌃⌥⇧N)", id: "live_new_window") { [unowned self] in
                Task { await live.toggleNewBrowserWindow(source: "menu_new_window") }
            })
        }
        menu.addItem(ClosureMenuItem("Float the app I'm in  (⌃⌥F)", id: "live_frontmost") { [unowned self] in
            // The menu itself is frontmost now; use the app that was active before it opened.
            if let app = lastUserApp { Task { await live.float(app, source: "menu_frontmost") } }
        })
        menu.addItem(submenu("Float an app", floatableApps().map { app in
            let item = ClosureMenuItem(app.localizedName ?? "App", id: "live_pick_app") { [unowned self] in Task { await live.float(app, source: "menu_pick") } }
            item.image = app.icon.map { icon in
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                return small
            }
            return item
        }))
        if !live.permissionsGranted(prompt: false) {
            menu.addItem(ClosureMenuItem("⚠︎ Needs Screen Recording + Accessibility — Grant…", id: "grant_permissions") { [unowned self] in
                _ = live.permissionsGranted(prompt: true)
            })
        }

        // ── The floating window ──
        if panel.isVisible || model.connected || model.testPattern || model.live != nil || model.browserActive {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Floating window"))
            menu.addItem(ClosureMenuItem(panel.isVisible ? "Hide" : "Show", id: panel.isVisible ? "window_hide" : "window_show") { [unowned self] in
                panel.isVisible ? panel.hide() : panel.show()
            })
            menu.addItem(ClosureMenuItem(model.isStashed ? "Bring back from edge  (⌃⌥Z)" : "Slide to edge  (⌃⌥Z)", id: "window_stash") { [unowned self] in
                panel.toggleStash()
            })
            if model.live == nil && !model.browserActive {
                menu.addItem(submenu("Size", [
                    ClosureMenuItem("Small", id: "size_small") { [unowned self] in panel.setWidth(320) },
                    ClosureMenuItem("Medium", id: "size_medium") { [unowned self] in panel.setWidth(480) },
                    ClosureMenuItem("Large", id: "size_large") { [unowned self] in panel.setWidth(720) },
                    ClosureMenuItem("Half the screen", id: "size_half") { [unowned self] in panel.setWidth((NSScreen.main?.frame.width ?? 1440) / 2) },
                    ClosureMenuItem("Toggle big / normal  (double-click the video)", id: "size_zoom") { [unowned self] in panel.toggleZoom() },
                ]))
            }
            menu.addItem(submenu("Move to corner", [
                ClosureMenuItem("Top left", id: "corner") { [unowned self] in panel.move(to: .topLeft) },
                ClosureMenuItem("Top right", id: "corner") { [unowned self] in panel.move(to: .topRight) },
                ClosureMenuItem("Bottom left", id: "corner") { [unowned self] in panel.move(to: .bottomLeft) },
                ClosureMenuItem("Bottom right", id: "corner") { [unowned self] in panel.move(to: .bottomRight) },
            ]))
        }

        // ── Settings, shortcuts, app ──
        menu.addItem(.separator())
        menu.addItem(settingsMenu())
        menu.addItem(submenu("Keyboard shortcuts", shortcutItems()))
        menu.addItem(ClosureMenuItem("Share anonymous usage", checked: Settings.shareUsage) {
            Settings.shareUsage.toggle()
            if Settings.shareUsage {
                UsageReporter.shared.turnedOn()
                UsageReporter.shared.event("usage_sharing_on")
            } else {
                UsageReporter.shared.turnedOff()
            }
        })
        let loginEnabled = SMAppService.mainApp.status == .enabled
        menu.addItem(ClosureMenuItem("Open at login", checked: loginEnabled, id: "open_at_login") { [unowned self] in
            do {
                if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
                settingChanged("open_at_login", !loginEnabled)
            } catch {
                UsageReporter.shared.failed("app", "login_item_failed")
                UsageReporter.shared.nonFatal("login_item", error)
                log("login item change failed: \(error)")
            }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit PiP Anywhere", id: "quit") { NSApp.terminate(nil) })
    }

    private func settingsMenu() -> NSMenuItem {
        let opacity = submenu("Opacity", [1.0, 0.85, 0.7, 0.5].map { value in
            ClosureMenuItem("\(Int(value * 100))%", checked: abs(Settings.opacity - value) < 0.01) { [unowned self] in
                Settings.opacity = value
                settingChanged("opacity", UsageCatalog.opacityBucket(value))
                panel.applySettings()
            }
        })
        let level = submenu("Window level", PanelLevel.allCases.map { option in
            ClosureMenuItem(option.title, checked: Settings.level == option) { [unowned self] in
                Settings.level = option
                settingChanged("level", option.rawValue)
                panel.applySettings()
            }
        })
        return submenu("Settings", [
            .sectionHeader(title: "Window"),
            opacity,
            ClosureMenuItem("Ghost mode: see-through, clicks pass through  (⌃⌥G)", checked: model.ghost, id: "ghost") { [unowned self] in
                panel.toggleGhost()
            },
            ClosureMenuItem("Stay still when switching desktops", checked: Settings.stayStillOnSpaceSwitch && StickySpace.isAvailable) { [unowned self] in
                Settings.stayStillOnSpaceSwitch.toggle()
                settingChanged("stay_still", Settings.stayStillOnSpaceSwitch)
                panel.applySettings()
            },
            ClosureMenuItem("Snap to corners", checked: Settings.snapToCorners) { [unowned self] in
                Settings.snapToCorners.toggle()
                settingChanged("snap_corners", Settings.snapToCorners)
            },
            ClosureMenuItem("Hide from screen sharing", checked: Settings.hideFromScreenSharing) { [unowned self] in
                Settings.hideFromScreenSharing.toggle()
                settingChanged("hide_sharing", Settings.hideFromScreenSharing)
                panel.applySettings()
            },
            level,
            .separator(),
            .sectionHeader(title: "Video"),
            ClosureMenuItem("Pause while slid to edge", checked: Settings.pauseWhenStashed) { [unowned self] in
                Settings.pauseWhenStashed.toggle()
                settingChanged("pause_stashed", Settings.pauseWhenStashed)
            },
            ClosureMenuItem("Mute while slid to edge", checked: Settings.muteWhenStashed) { [unowned self] in
                Settings.muteWhenStashed.toggle()
                settingChanged("mute_stashed", Settings.muteWhenStashed)
            },
            ClosureMenuItem("Thin progress line when controls are hidden", checked: Settings.showProgressLine) { [unowned self] in
                Settings.showProgressLine.toggle()
                settingChanged("progress_line", Settings.showProgressLine)
                model.objectWillChange.send()
            },
            ClosureMenuItem("Scroll over the video: sideways seeks, up/down volume", checked: Settings.scrollGestures) { [unowned self] in
                Settings.scrollGestures.toggle()
                settingChanged("scroll_gestures", Settings.scrollGestures)
            },
        ])
    }

    // MARK: Usage: settings

    private func settingChanged(_ setting: String, _ value: Any) {
        UsageReporter.shared.event("setting_changed", ["setting": setting, "value": value])
    }

    /// Once a day: every setting (enum/bool only), permission states and the environment.
    private func recordDailySnapshot() {
        let r = UsageReporter.shared
        r.event("settings_snapshot", [
            "opacity": UsageCatalog.opacityBucket(Settings.opacity),
            "level": Settings.level.rawValue,
            "stay_still": Settings.stayStillOnSpaceSwitch,
            "snap_corners": Settings.snapToCorners,
            "hide_sharing": Settings.hideFromScreenSharing,
            "block_ads": Settings.blockAds,
            "open_at_login": SMAppService.mainApp.status == .enabled,
            "browser_tabs": UsageCatalog.countBucket(Settings.browserTabs.count),
        ])
        r.event("settings_snapshot_video", [
            "pause_stashed": Settings.pauseWhenStashed,
            "mute_stashed": Settings.muteWhenStashed,
            "progress_line": Settings.showProgressLine,
            "scroll_gestures": Settings.scrollGestures,
        ])
        r.event("permissions_snapshot", [
            "accessibility": WindowMover.isTrusted(prompt: false),
            "screen_recording": CGPreflightScreenCaptureAccess(),
        ])
        let extensions = BrowserExtensions.installed().count
        var env: [String: Any] = [
            "displays": UsageCatalog.countBucket(NSScreen.screens.filter { $0 != live.stage.screen }.count),
            "web_extensions": UsageCatalog.countBucket(extensions),
            "sticky_space": StickySpace.isAvailable,
            "chromium_browser": LiveController.preferredBrowser != nil,
        ]
        if #available(macOS 15.4, *) { env["ext_support"] = true } else { env["ext_support"] = false }
        r.event("env_snapshot", env)
    }

    func applicationWillTerminate(_ notification: Notification) {
        UsageReporter.shared.appWillQuit()
    }

    private func shortcutItems() -> [NSMenuItem] {
        let groups: [(String, [(String, String)])] = [
            ("Video", [("Pop out (in the browser)", "⌥⇧P"), ("Play / pause", "⌃⌥Space"), ("Back / forward 10 s", "⌃⌥← / ⌃⌥→"),
                       ("Mute", "⌃⌥M"), ("Back to the tab", "⌃⌥B")]),
            ("Floating browser", [("Open / close", "⌃⌥N"), ("New tab · close tab", "⌘T · ⌘W"), ("Address bar", "⌘L"),
                                  ("Back · forward · reload", "⌘[ · ⌘] · ⌘R"), ("Zoom", "⌘+ · ⌘- · ⌘0"), ("Next / previous tab", "⌃Tab · ⌃⇧Tab")]),
            ("Live Apps", [("Float a new Brave window", "⌃⌥⇧N"), ("Float the app I'm in", "⌃⌥F"), ("Release the cursor", "⌃⌥E")]),
            ("Window", [("Slide to edge / bring back", "⌃⌥Z"), ("Bigger / smaller", "⌃⌥= / ⌃⌥-"), ("Ghost mode", "⌃⌥G")]),
        ]
        return groups.flatMap { title, items in
            [NSMenuItem.sectionHeader(title: title)] + items.map { NSMenuItem.disabled("\($0.1)    \($0.0)") }
        }
    }

    /// Regular apps with a Dock presence, except us.
    private func floatableApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    // MARK: Debug

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    /// Writes a PNG of the window as it appears on screen, video included. Capturing
    /// our own window needs no Screen Recording permission. CGWindowListCreateImage is
    /// unavailable to the macOS 15+ SDK, hence dlsym; falls back to drawing the views.
    private func snapshot(to path: String) {
        // With Screen Recording allowed, ScreenCaptureKit shows exactly what is on screen.
        if CGPreflightScreenCaptureAccess() {
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.panel.windowNumber) }) else {
                        log("snapshot: own window not in shareable content")
                        return
                    }
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * 2)
                    config.height = Int(window.frame.height * 2)
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    log("snapshot (ScreenCaptureKit) written to \(path)")
                } catch {
                    log("snapshot failed: \(error)")
                }
            }
            return
        }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let url = URL(fileURLWithPath: path)
        var data: Data?
        if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(pointer, to: CreateImage.self)(
               .null, 1 << 3 /* optionIncludingWindow */, UInt32(panel.panel.windowNumber), 1 /* boundsIgnoreFraming */
           )?.takeRetainedValue() {
            data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        } else if let view = panel.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        do {
            try data?.write(to: url)
            log("snapshot written to \(path), window frame \(NSStringFromRect(panel.panel.frame))")
        } catch {
            log("snapshot failed: \(error)")
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    /// Fixed id counted as menu_action (never the title: it can contain app names).
    private let usageID: String?

    init(_ title: String, checked: Bool = false, id: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        self.usageID = id
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() {
        if let usageID { MainActor.assumeIsolated { UsageReporter.shared.count("menu_action", ["item": usageID]) } }
        handler()
    }
}

private extension NSMenuItem {
    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// Registers global shortcuts and counts their use (shortcut name only) for usage reporting.
@MainActor
private struct CountingHotKeys {
    func register(_ key: HotKeys.Shortcut, handler: @escaping () -> Void) {
        HotKeys.shared.register(key) {
            MainActor.assumeIsolated { UsageReporter.shared.count("shortcut_used", ["shortcut": key.title]) }
            handler()
        }
    }
}
