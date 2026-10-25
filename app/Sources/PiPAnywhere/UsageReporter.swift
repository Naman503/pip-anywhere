import AppKit
import Foundation
import PiPCore

/// Anonymous usage reporting (menu → Settings → Share anonymous usage), on by default.
/// Sends feature names, daily counts, setup milestones and crash types to
/// POST /v1/app/pipanywhere with a random install id, every 6 hours. Never window or
/// video titles, app names, URLs or screen content. Turning it off deletes what was sent.
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

    func start() {
        guard active else { return }
        installCrashHandler()
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

    func event(_ name: String, _ props: [String: String] = [:]) {
        guard enabled else { return }
        var list = pending
        guard list.count < 500 else { return }
        var e: [String: Any] = ["n": name, "t": Self.now()]
        if !props.isEmpty { e["p"] = props }
        list.append(e)
        pending = list
    }

    func count(_ name: String, _ props: [String: String] = [:], by n: Int = 1) {
        guard enabled else { return }
        var c = counters
        let key = UsageKeys.counter(day: UsageKeys.day(), name: name, props: props)
        c[key, default: 0] += n
        counters = c
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

    private func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            // Type and call stack only: the reason can contain titles.
            let stack = exception.callStackSymbols.prefix(20).joined(separator: "\n")
            let fp = String(UInt32(truncatingIfNeeded: (exception.name.rawValue + exception.callStackSymbols.prefix(3).joined()).hashValue), radix: 16)
            var list = UserDefaults.standard.array(forKey: "usage.crashes") as? [[String: Any]] ?? []
            if list.count < 20 {
                list.append(["fp": fp, "m": exception.name.rawValue, "st": String(stack.prefix(4000)), "t": UsageReporter.now(), "fatal": true])
                UserDefaults.standard.set(list, forKey: "usage.crashes")
                UserDefaults.standard.synchronize()
            }
        }
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
