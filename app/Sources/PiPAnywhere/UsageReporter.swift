import AppKit
import Foundation
import PiPCore

/// Anonymous usage reporting (menu → Share anonymous usage), on by default.
/// Sends feature names, daily counts, fixed-enum props, duration/latency buckets, a daily
/// settings snapshot, setup milestones and crash types to POST /v1/app/pipanywhere with a
/// random install id, every 6 hours. Never window or video titles, app names, URLs or
/// screen content. Turning it off deletes what was sent.
@MainActor
final class UsageReporter {
    static let shared = UsageReporter()
    static let endpoint = URL(string: "https://api.np-dev.duckdns.org/v1/app/pipanywhere")!

    /// Test copies (another port) never report.
    var active = true
    private let store = UserDefaults.standard
    private var timer: Timer?

    private var installId: String {
        if let id = store.string(forKey: "usage.installId") { return id }
        let id = UUID().uuidString.lowercased()
        store.set(id, forKey: "usage.installId")
        return id
    }

    var enabled: Bool { active && Settings.shareUsage }

    /// Called once a day (first flush of the day) to record the settings snapshot.
    var onDaily: () -> Void = {}

    func start() {
        guard active else { return }
        collectSignalCrash()
        installCrashHandler()
        count("app_open")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if let last = store.string(forKey: "usage.lastVersion") {
            if last != version { event("app_update", ["from": String(last.prefix(16)), "to": version]) }
        } else {
            once("app_installed")
        }
        store.set(version, forKey: "usage.lastVersion")
        Task { try? await Task.sleep(for: .seconds(120)); await self.flush() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await UsageReporter.shared.flush() }
        }
    }

    // MARK: recording

    /// One row. Props: fixed enums, buckets, numbers or booleans only.
    func event(_ name: String, _ props: [String: Any] = [:]) {
        guard enabled, UsageCatalog.isValidName(name) else { return }
        var list = pending
        guard list.count < 500 else { return }
        var e: [String: Any] = ["n": name, "t": Self.now()]
        let clean = UsageCatalog.cleanProps(props)
        if !clean.isEmpty { e["p"] = clean }
        list.append(e)
        pending = list
    }

    /// A daily counter (one row per day and prop combination). `day` defaults to today.
    func count(_ name: String, _ props: [String: String] = [:], by n: Int = 1, day: String? = nil) {
        guard enabled, n > 0, UsageCatalog.isValidName(name) else { return }
        var c = counters
        let key = UsageKeys.counter(day: day ?? UsageKeys.day(), name: name, props: props)
        c[key] = min(c[key, default: 0] + n, 1_000_000)
        counters = c
    }

    // MARK: Floating window sessions

    private var openSince: [String: Date] = [:]

    /// A floating window started showing `mode` (video, browser, live, test).
    /// Emits pip_started once per session (a video re-configuring mid-stream doesn't count).
    func windowStarted(mode: String, source: String, _ extra: [String: Any] = [:]) {
        guard openSince[mode] == nil else { return }
        var props: [String: Any] = ["mode": mode, "source": source, "others_open": openSince.count]
        props.merge(extra) { a, _ in a }
        openSince[mode] = Date()
        if mode == "test" {
            count("test_pattern_shown")
            return
        }
        event("pip_started", props)
        once("first_pip")
        once("first_\(mode)")
    }

    /// The `mode` session ended; `how` is a fixed enum (close_button, menu, shortcut, …).
    func windowEnded(mode: String, how: String, _ extra: [String: Any] = [:]) {
        guard let since = openSince.removeValue(forKey: mode) else { return }
        guard mode != "test" else { return }
        let seconds = Date().timeIntervalSince(since)
        var props: [String: Any] = ["mode": mode, "how": how, "dur": UsageCatalog.durationBucket(seconds: seconds)]
        props.merge(extra) { a, _ in a }
        event("window_closed", props)
        let minutes = Int((seconds / 60).rounded())
        if minutes > 0 { count("pip_minutes", ["mode": mode], by: minutes) }
    }

    func isOpen(_ mode: String) -> Bool { openSince[mode] != nil }

    /// Quitting: every open session ends as "app_quit".
    func appWillQuit() {
        for mode in openSince.keys { windowEnded(mode: mode, how: "app_quit") }
    }

    /// A failure at a known point: `pip_failed` with fixed-enum mode and reason.
    func failed(_ mode: String, _ reason: String, _ extra: [String: Any] = [:]) {
        var props: [String: Any] = ["mode": mode, "reason": reason]
        props.merge(extra) { a, _ in a }
        event("pip_failed", props)
    }

    /// A non-fatal error worth fixing: recorded as a crash with fatal=false. Only the
    /// NSError domain and code are kept (never the localized description).
    func nonFatal(_ place: String, _ error: Error) {
        guard enabled else { return }
        let ns = error as NSError
        let domain = String(ns.domain.prefix(80))
        let message = "\(place): \(domain) \(ns.code)"
        appendCrash(["fp": UsageCatalog.fingerprint(message), "m": message, "t": Self.now(), "fatal": false])
    }

    func once(_ name: String) {
        guard enabled else { return }
        var done = store.stringArray(forKey: "usage.once") ?? []
        guard !done.contains(name) else { return }
        done.append(name)
        store.set(done, forKey: "usage.once")
        event(name)
    }

    func turnedOff() {
        store.removeObject(forKey: "usage.pending")
        store.removeObject(forKey: "usage.counters")
        store.removeObject(forKey: "usage.crashes")
        store.set(true, forKey: "usage.offPending")
        Task { await flush() }
    }

    func turnedOn() { store.set(false, forKey: "usage.offPending") }

    // MARK: sending

    func flush() async {
        guard active else { return }
        if store.bool(forKey: "usage.offPending") {
            if await post(base().merging(["off": true]) { $1 }) { store.set(false, forKey: "usage.offPending") }
            return
        }
        guard enabled else { return }
        let today = UsageKeys.day()
        if store.string(forKey: "usage.dailyChecked") != today {
            store.set(today, forKey: "usage.dailyChecked")
            if LiveController.screenRecordingGranted() { once("setup_permission") }
            onDaily()
        }
        let sentPending = pending
        let sentCounters = counters.filter { UsageKeys.parse($0.key)?.day != today }
        let sentCrashes = crashes
        var events = sentPending
        for (key, n) in sentCounters {
            guard let k = UsageKeys.parse(key) else { continue }
            var e: [String: Any] = ["n": k.name, "t": UsageKeys.noon(of: k.day), "c": n]
            if !k.props.isEmpty { e["p"] = k.props }
            events.append(e)
        }
        guard !events.isEmpty || !sentCrashes.isEmpty else { return }
        guard await post(base().merging(["e": events, "cr": sentCrashes]) { $1 }) else { return }
        pending = Array(pending.dropFirst(sentPending.count))
        crashes = Array(crashes.dropFirst(sentCrashes.count))
        var c = counters
        for k in sentCounters.keys { c.removeValue(forKey: k) }
        counters = c
    }

    private func base() -> [String: Any] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var model = "Mac"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buf, &size, nil, 0)
            model = String(cString: buf)
        }
        return [
            "i": installId,
            "v": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "pf": "macos",
            "os": "macOS",
            "osv": "\(v.majorVersion).\(v.minorVersion)",
            "dc": "desktop",
            "dm": String(model.prefix(48)),
            "loc": String(Locale.current.identifier.prefix(16)),
        ]
    }

    private func post(_ body: [String: Any]) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }

    // MARK: crashes

    private func appendCrash(_ crash: [String: Any]) {
        var list = crashes
        guard list.count < 20 else { return }
        list.append(crash)
        crashes = list
    }

    private func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            // Like `enabled`: the handler is only installed when `active`, so the switch decides.
            // The signal handler then skips this crash either way (it's the same one).
            crashExceptionRecorded = 1
            guard Settings.shareUsage else { return }
            // Type and call stack only: the reason can contain titles.
            let symbols = exception.callStackSymbols
            let stack = symbols.prefix(20).joined(separator: "\n")
            let fp = UsageCatalog.fingerprint(exception.name.rawValue + symbols.prefix(4).map(UsageCatalog.symbolOnly).joined(separator: "|"))
            var list = UserDefaults.standard.array(forKey: "usage.crashes") as? [[String: Any]] ?? []
            if list.count < 20 {
                list.append(["fp": fp, "m": String("NSException \(exception.name.rawValue)".prefix(500)), "st": String(stack.prefix(4000)), "t": UsageReporter.now(), "fatal": true])
                UserDefaults.standard.set(list, forKey: "usage.crashes")
                UserDefaults.standard.synchronize()
            }
        }
        installSignalHandlers()
    }

    /// Fatal signals (crashes in Swift code: force-unwraps, fatalError, bad memory) are
    /// written with async-signal-safe calls to a file; the next launch turns it into a crash.
    private func installSignalHandlers() {
        let path = Self.signalFile.path
        crashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard crashFD >= 0 else { return }
        // Allocate the backtrace buffer now: a lazy global first touched inside the
        // handler would run its initialiser (malloc) in signal context.
        crashFrames.initialize(repeating: nil, count: 64)
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }

    static var signalFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PiP Anywhere", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-crash.txt")
    }

    /// Reads what the signal handler wrote last run (if anything) into a crash entry.
    private func collectSignalCrash() {
        let url = Self.signalFile
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
        defer { try? Data().write(to: url) }
        guard enabled else { return }
        var lines = text.split(separator: "\n").map(String.init)
        let head = lines.isEmpty ? "" : lines.removeFirst()
        let number = Int32(head.dropFirst()) ?? 0
        let name = UsageCatalog.signalName(number)
        // Skip our handler's own frames (backtrace + the handler itself).
        let frames = lines.filter { !$0.contains("crashSignalHandler") && !$0.contains(" backtrace ") && !$0.contains("_sigtramp") }
        let fp = UsageCatalog.fingerprint(name + frames.prefix(5).map(UsageCatalog.symbolOnly).joined(separator: "|"))
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? Date()
        appendCrash(["fp": fp, "m": "fatal signal \(name)", "st": String(frames.prefix(40).joined(separator: "\n").prefix(4000)),
                     "t": Int64(modified.timeIntervalSince1970 * 1000), "fatal": true])
    }

    // MARK: storage

    nonisolated static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var pending: [[String: Any]] {
        get { store.array(forKey: "usage.pending") as? [[String: Any]] ?? [] }
        set { store.set(newValue, forKey: "usage.pending") }
    }
    private var counters: [String: Int] {
        get { store.dictionary(forKey: "usage.counters") as? [String: Int] ?? [:] }
        set { store.set(newValue, forKey: "usage.counters") }
    }
    private var crashes: [[String: Any]] {
        get { store.array(forKey: "usage.crashes") as? [[String: Any]] ?? [] }
        set { store.set(newValue, forKey: "usage.crashes") }
    }
}

// Signal-handler state: plain globals, set up before any handler can run.
nonisolated(unsafe) private var crashFD: Int32 = -1
nonisolated(unsafe) private var crashExceptionRecorded: Int32 = 0
nonisolated(unsafe) private let crashFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)

/// Async-signal-safe: write(), backtrace() into a preallocated buffer, backtrace_symbols_fd().
private func crashSignalHandler(_ sig: Int32) {
    if crashFD >= 0 && crashExceptionRecorded == 0 {
        var line: (UInt8, UInt8, UInt8, UInt8) = (0x53, 0x30 + UInt8(truncatingIfNeeded: (sig / 10) % 10), 0x30 + UInt8(truncatingIfNeeded: sig % 10), 0x0A)
        _ = withUnsafeBytes(of: &line) { write(crashFD, $0.baseAddress, 4) }
        let n = backtrace(crashFrames, 64)
        backtrace_symbols_fd(crashFrames, n, crashFD)
        fsync(crashFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
