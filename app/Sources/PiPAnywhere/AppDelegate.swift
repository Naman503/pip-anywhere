import AppKit
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

    init(options: LaunchOptions) {
        self.options = options
        if options.port != WireProtocol.port { Settings.useSeparateStore(for: options.port) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SkyLight.allowCursorChangesInBackground()
        panel = PanelController(model: model, videoLayer: renderer.layer) { [unowned self] controller in
            PanelActions(
                dragChanged: { controller.dragChanged() },
                dragEnded: { controller.dragEnded() },
                magnifyChanged: { controller.magnifyChanged($0) },
                magnifyEnded: { controller.magnifyEnded() },
                resizeChanged: { controller.resizeChanged($0) },
                resizeEnded: { controller.resizeEnded() },
                toggleStash: { controller.toggleStash() },
                toggleZoom: { controller.toggleZoom() },
                close: { self.closeStream() }
            )
        }
        model.sendCommand = { [unowned self] action, value in self.send(.command(action, value: value)) }
        setUpServer()
        setUpStatusItem()
        setUpHotKeys()

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
        if model.testPattern {
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
            case let arg? where arg.hasPrefix("corner:"):
                if let corner = ScreenCorner(rawValue: String(arg.dropFirst(7))) { panel.move(to: corner) }
            default: break
            }
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
        keys.register(.grow) { [unowned self] in panel.scale(by: 1.15) }
        keys.register(.shrink) { [unowned self] in panel.scale(by: 1 / 1.15) }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "PiP Anywhere")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if model.testPattern {
            status = "Showing test pattern"
        } else if model.connected {
            status = "Streaming: \(model.playback?.title ?? "video")"
        } else {
            status = "Waiting for the browser extension"
        }
        menu.addItem(.disabled(status))
        if model.connected || model.testPattern { menu.addItem(.disabled(model.stats.summary)) }
        menu.addItem(.separator())

        if model.connected || model.testPattern {
            menu.addItem(ClosureMenuItem(panel.isVisible ? "Hide window" : "Show window") { [unowned self] in
                panel.isVisible ? panel.hide() : panel.show()
            })
            menu.addItem(ClosureMenuItem(model.isStashed ? "Bring back from edge  (⌃⌥P)" : "Slide to edge  (⌃⌥P)") { [unowned self] in
                panel.toggleStash()
            })
            menu.addItem(submenu("Size", [
                ClosureMenuItem("Small") { [unowned self] in panel.setWidth(320) },
                ClosureMenuItem("Medium") { [unowned self] in panel.setWidth(480) },
                ClosureMenuItem("Large") { [unowned self] in panel.setWidth(720) },
                ClosureMenuItem("Half the screen") { [unowned self] in panel.setWidth((NSScreen.main?.frame.width ?? 1440) / 2) },
                ClosureMenuItem("Toggle big / normal  (double-click the video)") { [unowned self] in panel.toggleZoom() },
            ]))
            menu.addItem(submenu("Move to corner", [
                ClosureMenuItem("Top left") { [unowned self] in panel.move(to: .topLeft) },
                ClosureMenuItem("Top right") { [unowned self] in panel.move(to: .topRight) },
                ClosureMenuItem("Bottom left") { [unowned self] in panel.move(to: .bottomLeft) },
                ClosureMenuItem("Bottom right") { [unowned self] in panel.move(to: .bottomRight) },
            ]))
            menu.addItem(.separator())
        }

        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [1.0, 0.85, 0.7, 0.5] {
            opacityMenu.addItem(ClosureMenuItem("\(Int(value * 100))%", checked: abs(Settings.opacity - value) < 0.01) { [unowned self] in
                Settings.opacity = value
                panel.applySettings()
            })
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(ClosureMenuItem("Ghost mode: see-through, clicks pass through  (⌃⌥G)", checked: model.ghost) { [unowned self] in
            panel.toggleGhost()
        })
        menu.addItem(ClosureMenuItem("Stay still when switching desktops", checked: Settings.stayStillOnSpaceSwitch && StickySpace.isAvailable) { [unowned self] in
            Settings.stayStillOnSpaceSwitch.toggle()
            panel.applySettings()
        })
        menu.addItem(ClosureMenuItem("Snap to corners", checked: Settings.snapToCorners) {
            Settings.snapToCorners.toggle()
        })
        menu.addItem(ClosureMenuItem("Pause while slid to edge", checked: Settings.pauseWhenStashed) {
            Settings.pauseWhenStashed.toggle()
        })
        menu.addItem(ClosureMenuItem("Mute while slid to edge", checked: Settings.muteWhenStashed) {
            Settings.muteWhenStashed.toggle()
        })
        menu.addItem(ClosureMenuItem("Thin progress line when controls are hidden", checked: Settings.showProgressLine) { [unowned self] in
            Settings.showProgressLine.toggle()
            model.objectWillChange.send()
        })
        menu.addItem(ClosureMenuItem("Scroll over the video: sideways seeks, up/down volume", checked: Settings.scrollGestures) {
            Settings.scrollGestures.toggle()
        })
        menu.addItem(ClosureMenuItem("Hide from screen sharing", checked: Settings.hideFromScreenSharing) { [unowned self] in
            Settings.hideFromScreenSharing.toggle()
            panel.applySettings()
        })

        let level = NSMenuItem(title: "Window level", action: nil, keyEquivalent: "")
        let levelMenu = NSMenu()
        for option in PanelLevel.allCases {
            levelMenu.addItem(ClosureMenuItem(option.title, checked: Settings.level == option) { [unowned self] in
                Settings.level = option
                panel.applySettings()
            })
        }
        level.submenu = levelMenu
        menu.addItem(level)
        menu.addItem(submenu("Keyboard shortcuts", [
            ("Slide to edge / bring back", "⌃⌥P"), ("Play / pause", "⌃⌥Space"), ("Back / forward 10 s", "⌃⌥← / ⌃⌥→"),
            ("Mute", "⌃⌥M"), ("Bigger / smaller", "⌃⌥= / ⌃⌥-"), ("Ghost mode", "⌃⌥G"), ("Back to the tab", "⌃⌥B"),
            ("Pop out (in the browser)", "⌥⇧P"),
        ].map { NSMenuItem.disabled("\($0.1)    \($0.0)") }))
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(model.testPattern ? "Stop test pattern" : "Show test pattern") { [unowned self] in
            model.testPattern ? stopTestPattern() : startTestPattern()
        })
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
