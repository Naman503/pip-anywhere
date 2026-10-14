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

    init(options: LaunchOptions) {
        self.options = options
        if options.port != WireProtocol.port { Settings.useSeparateStore(for: options.port) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SkyLight.allowCursorChangesInBackground()
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
                close: { self.closeStream() },
                liveHover: { self.live.bridge.enter(at: $0) },
                liveReturn: { Task { await self.live.unfloat() } }
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
            DispatchQueue.main.async { model.connected = true }
        }
        server.onDisconnect = { [weak self] in
            renderer.reset()
            DispatchQueue.main.async { self?.streamEnded() }
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
                DispatchQueue.main.async { self?.streamEnded() }
            case let .hello(version):
                log("extension hello (protocol \(version))")
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
            log("could not start server on port \(options.port): \(error)")
        }
    }

    private func send(_ message: Outbound) {
        if model.testPattern {
            if case .command(.close, _) = message { stopTestPattern() }
            return
        }
        let server = server!
        renderer.queue.async { server.send(message) }
    }

    private func streamStarted(_ config: StreamConfig) {
        hideTask?.cancel()
        // The window is showing a live app or the browser; the video keeps decoding but isn't shown.
        if model.live != nil || model.browserActive { return }
        if model.testPattern { stopTestPattern() }
        model.connected = true
        panel.setVideoSize(width: config.width, height: config.height)
        panel.show()
    }

    private func streamEnded() {
        model.connected = false
        model.playback = nil
        model.stats = StreamStats()
        guard !model.testPattern else { return }
        // Short grace period: the extension reconnects when the crop size changes.
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !self.model.connected else { return }
            self.panel.hide()
        }
    }

    private func closeStream() {
        if model.browserActive {
            closeBrowser()
        } else if live.isFloating {
            Task { await live.unfloat() }
        } else if model.testPattern {
            stopTestPattern()
        } else {
            send(.command(.close))
            panel.hide()
        }
    }

    private func statsUpdated(_ stats: StreamStats) {
        model.stats = stats
        if Date().timeIntervalSince(lastStatsLog) >= 5 {
            lastStatsLog = Date()
            let playback = model.playback.map {
                " · \($0.paused ? "paused" : "playing") \(formatTime(model.currentTime())) @\($0.rate)× '\($0.title)'"
            } ?? ""
            log("stats: \(stats.summary)\(playback)")
        }
    }

    private func startTestPattern() {
        model.testPattern = true
        panel.setVideoSize(width: 1280, height: 720)
        panel.show()
        let pattern = testPattern
        renderer.queue.async { pattern.start() }
    }

    private func stopTestPattern() {
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
    func openBrowser(_ url: URL? = nil) {
        if live.isFloating { Task { await live.unfloat() } }
        if model.testPattern { stopTestPattern() }
        Task {
            await browser.prepare() // extensions + ad blocker, before the first tab
            browser.restoreSession()
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

    func closeBrowser() {
        guard model.browserActive else { return }
        browser.saveSession()
        Settings.browserSize = panel.panel.frame.size
        model.browserActive = false
        panel.exitLiveMode()
        panel.hide()
        log("browser: closed (tabs kept)")
    }

    func toggleBrowser() {
        if model.browserActive {
            if model.isStashed { panel.toggleStash() } else { closeBrowser() }
        } else {
            openBrowser()
        }
    }

    /// Asks Brave / Chrome / Safari for its current tab's address (Apple Events; macOS asks once).
    private func currentTabURL(of appName: String) -> URL? {
        let source = appName == "Safari"
            ? "tell application \"Safari\" to return URL of current tab of front window"
            : "tell application \"\(appName)\" to return URL of active tab of front window"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log("browser: couldn't read \(appName)'s tab: \(error[NSAppleScript.errorMessage] ?? error)") }
        return result?.stringValue.flatMap(URL.init(string:))
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
        if flags == .control, event.keyCode == 48 { browser.selectNext(1); return true }           // ⌃Tab
        if flags == [.control, .shift], event.keyCode == 48 { browser.selectNext(-1); return true } // ⌃⇧Tab
        let edit: Selector? = switch (flags, key) {
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        if let edit { return NSApp.sendAction(edit, to: nil, from: nil) }
        guard flags == .command || flags == [.command, .shift] else { return false }
        switch key {
        case "t": browser.newTab()
        case "w": if let tab { browser.close(tab) }; if browser.isEmpty { closeBrowser() }
        case "l": browser.focusAddressBar += 1
        case "r": tab?.webView.reload()
        case "[": tab?.webView.goBack()
        case "]": tab?.webView.goForward()
        case "=", "+": tab.map { $0.webView.pageZoom = min($0.webView.pageZoom + 0.1, 3) }
        case "-": tab.map { $0.webView.pageZoom = max($0.webView.pageZoom - 0.1, 0.3) }
        case "0": tab?.webView.pageZoom = 1
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
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
            case "close": closeBrowser()
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
            case let arg? where arg.hasPrefix("open:"): openBrowser(URL(string: String(arg.dropFirst(5))))
            default: openBrowser()
            }
        } else if name == "live", let argument {
            live.run(argument)
        } else if name == "debug", let argument {
            DebugInput.run(argument)
        } else if name == "snapshot", let path = argument {
            snapshot(to: path)
        } else if let action = CommandAction(rawValue: name) {
            model.command(action, argument.flatMap(Double.init))
        }
    }

    // MARK: Hotkeys

    private func setUpHotKeys() {
        let keys = HotKeys.shared
        keys.register(.toggleStash) { [unowned self] in
            if !panel.isVisible, model.connected || model.testPattern { panel.show() } else { panel.toggleStash() }
        }
        keys.register(.playPause) { [unowned self] in model.command(.toggle) }
        keys.register(.back10) { [unowned self] in model.seek(by: -10) }
        keys.register(.forward10) { [unowned self] in model.seek(by: 10) }
        keys.register(.mute) { [unowned self] in model.toggleMute() }
        keys.register(.ghost) { [unowned self] in panel.toggleGhost() }
        keys.register(.backToTab) { [unowned self] in model.command(.focusTab) }
        keys.register(.toggleBrowser) { [unowned self] in toggleBrowser() }
        keys.register(.floatNewBrowserWindow) { [unowned self] in Task { await self.live.toggleNewBrowserWindow() } }
        keys.register(.floatFrontmost) { [unowned self] in Task { await self.live.floatFrontmost() } }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
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
        menu.addItem(ClosureMenuItem(model.testPattern ? "Stop test pattern" : "Show test pattern") { [unowned self] in
            model.testPattern ? stopTestPattern() : startTestPattern()
        })

        // ── Floating browser ──
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Floating browser — built in, no permissions"))
        if model.browserActive {
            menu.addItem(.disabled("● \(browser.tabs.count) tab\(browser.tabs.count == 1 ? "" : "s") open"))
            menu.addItem(ClosureMenuItem("Close the floating browser  (⌃⌥N)") { [unowned self] in closeBrowser() })
        } else {
            menu.addItem(ClosureMenuItem("Open the floating browser  (⌃⌥N)") { [unowned self] in openBrowser() })
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for (bundleID, name) in Self.knownBrowsers where running.contains(bundleID) {
            menu.addItem(ClosureMenuItem("Open \(name)'s current tab here") { [unowned self] in
                if let url = currentTabURL(of: name) { openBrowser(url) }
            })
        }
        menu.addItem(ClosureMenuItem("Block ads and trackers, skip YouTube ads", checked: Settings.blockAds) { [unowned self] in
            Settings.blockAds.toggle()
            browser.applyContentBlocking()
        })
        menu.addItem(ClosureMenuItem("Extensions…") { [unowned self] in browser.revealExtensionsFolder() })

        // ── Live Apps ──
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Live Apps (beta) — real apps, fully usable"))
        let browserName = LiveController.preferredBrowser
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        if let info = model.live {
            menu.addItem(.disabled("● \(info.appName)\(info.title.isEmpty ? "" : " — \(info.title)")"))
            menu.addItem(ClosureMenuItem("Close the floating window") { [unowned self] in Task { await live.unfloat() } })
            if model.liveCaptured {
                menu.addItem(ClosureMenuItem("Release the cursor  (⌃⌥E)") { [unowned self] in live.bridge.release() })
            }
        } else {
            menu.addItem(.disabled("Not active"))
        }
        if let browserName {
            menu.addItem(ClosureMenuItem("Float a new \(browserName) window  (⌃⌥⇧N)") { [unowned self] in
                Task { await live.toggleNewBrowserWindow() }
            })
        }
        menu.addItem(ClosureMenuItem("Float the app I'm in  (⌃⌥F)") { [unowned self] in
            // The menu itself is frontmost now; use the app that was active before it opened.
            if let app = lastUserApp { Task { await live.float(app) } }
        })
        menu.addItem(submenu("Float an app", floatableApps().map { app in
            let item = ClosureMenuItem(app.localizedName ?? "App") { [unowned self] in Task { await live.float(app) } }
            item.image = app.icon.map { icon in
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                return small
            }
            return item
        }))
        if !live.permissionsGranted(prompt: false) {
            menu.addItem(ClosureMenuItem("⚠︎ Needs Screen Recording + Accessibility — Grant…") { [unowned self] in
                _ = live.permissionsGranted(prompt: true)
            })
        }

        // ── The floating window ──
        if panel.isVisible || model.connected || model.testPattern || model.live != nil || model.browserActive {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Floating window"))
            menu.addItem(ClosureMenuItem(panel.isVisible ? "Hide" : "Show") { [unowned self] in
                panel.isVisible ? panel.hide() : panel.show()
            })
            menu.addItem(ClosureMenuItem(model.isStashed ? "Bring back from edge  (⌃⌥P)" : "Slide to edge  (⌃⌥P)") { [unowned self] in
                panel.toggleStash()
            })
            if model.live == nil && !model.browserActive {
                menu.addItem(submenu("Size", [
                    ClosureMenuItem("Small") { [unowned self] in panel.setWidth(320) },
                    ClosureMenuItem("Medium") { [unowned self] in panel.setWidth(480) },
                    ClosureMenuItem("Large") { [unowned self] in panel.setWidth(720) },
                    ClosureMenuItem("Half the screen") { [unowned self] in panel.setWidth((NSScreen.main?.frame.width ?? 1440) / 2) },
                    ClosureMenuItem("Toggle big / normal  (double-click the video)") { [unowned self] in panel.toggleZoom() },
                ]))
            }
            menu.addItem(submenu("Move to corner", [
                ClosureMenuItem("Top left") { [unowned self] in panel.move(to: .topLeft) },
                ClosureMenuItem("Top right") { [unowned self] in panel.move(to: .topRight) },
                ClosureMenuItem("Bottom left") { [unowned self] in panel.move(to: .bottomLeft) },
                ClosureMenuItem("Bottom right") { [unowned self] in panel.move(to: .bottomRight) },
            ]))
        }

        // ── Settings, shortcuts, app ──
        menu.addItem(.separator())
        menu.addItem(settingsMenu())
        menu.addItem(submenu("Keyboard shortcuts", shortcutItems()))
        let loginEnabled = SMAppService.mainApp.status == .enabled
        menu.addItem(ClosureMenuItem("Open at login", checked: loginEnabled) {
            do {
                if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            } catch {
                log("login item change failed: \(error)")
            }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit PiP Anywhere") { NSApp.terminate(nil) })
    }

    private func settingsMenu() -> NSMenuItem {
        let opacity = submenu("Opacity", [1.0, 0.85, 0.7, 0.5].map { value in
            ClosureMenuItem("\(Int(value * 100))%", checked: abs(Settings.opacity - value) < 0.01) { [unowned self] in
                Settings.opacity = value
                panel.applySettings()
            }
        })
        let level = submenu("Window level", PanelLevel.allCases.map { option in
            ClosureMenuItem(option.title, checked: Settings.level == option) { [unowned self] in
                Settings.level = option
                panel.applySettings()
            }
        })
        return submenu("Settings", [
            .sectionHeader(title: "Window"),
            opacity,
            ClosureMenuItem("Ghost mode: see-through, clicks pass through  (⌃⌥G)", checked: model.ghost) { [unowned self] in
                panel.toggleGhost()
            },
            ClosureMenuItem("Stay still when switching desktops", checked: Settings.stayStillOnSpaceSwitch && StickySpace.isAvailable) { [unowned self] in
                Settings.stayStillOnSpaceSwitch.toggle()
                panel.applySettings()
            },
            ClosureMenuItem("Snap to corners", checked: Settings.snapToCorners) { Settings.snapToCorners.toggle() },
            ClosureMenuItem("Hide from screen sharing", checked: Settings.hideFromScreenSharing) { [unowned self] in
                Settings.hideFromScreenSharing.toggle()
                panel.applySettings()
            },
            level,
            .separator(),
            .sectionHeader(title: "Video"),
            ClosureMenuItem("Pause while slid to edge", checked: Settings.pauseWhenStashed) { Settings.pauseWhenStashed.toggle() },
            ClosureMenuItem("Mute while slid to edge", checked: Settings.muteWhenStashed) { Settings.muteWhenStashed.toggle() },
            ClosureMenuItem("Thin progress line when controls are hidden", checked: Settings.showProgressLine) { [unowned self] in
                Settings.showProgressLine.toggle()
                model.objectWillChange.send()
            },
            ClosureMenuItem("Scroll over the video: sideways seeks, up/down volume", checked: Settings.scrollGestures) {
                Settings.scrollGestures.toggle()
            },
        ])
    }

    private func shortcutItems() -> [NSMenuItem] {
        let groups: [(String, [(String, String)])] = [
            ("Video", [("Pop out (in the browser)", "⌥⇧P"), ("Play / pause", "⌃⌥Space"), ("Back / forward 10 s", "⌃⌥← / ⌃⌥→"),
                       ("Mute", "⌃⌥M"), ("Back to the tab", "⌃⌥B")]),
            ("Floating browser", [("Open / close", "⌃⌥N"), ("New tab · close tab", "⌘T · ⌘W"), ("Address bar", "⌘L"),
                                  ("Back · forward · reload", "⌘[ · ⌘] · ⌘R"), ("Zoom", "⌘+ · ⌘- · ⌘0"), ("Next / previous tab", "⌃Tab · ⌃⇧Tab")]),
            ("Live Apps", [("Float a new Brave window", "⌃⌥⇧N"), ("Float the app I'm in", "⌃⌥F"), ("Release the cursor", "⌃⌥E")]),
            ("Window", [("Slide to edge / bring back", "⌃⌥P"), ("Bigger / smaller", "⌃⌥= / ⌃⌥-"), ("Ghost mode", "⌃⌥G")]),
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

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

private extension NSMenuItem {
    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
