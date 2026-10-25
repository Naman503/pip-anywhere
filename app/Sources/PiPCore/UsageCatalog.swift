import Foundation

/// Pure helpers for anonymous usage reporting: buckets, stable fingerprints, and the
/// allow-list that extension-reported events must pass before the app records them.
/// Everything here produces fixed enums, buckets or counts only.
public enum UsageCatalog {
    // MARK: Names and props (mirrors the API contract)

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z][a-z0-9_]{0,47}$"#, options: .regularExpression) != nil
    }

    public static func isValidPropKey(_ key: String) -> Bool {
        key.range(of: #"^[a-z][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil
    }

    /// Keeps at most 8 valid keys, with String (≤64), finite Int/Double or Bool values.
    public static func cleanProps(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in props.keys.sorted() where isValidPropKey(key) && out.count < 8 {
            switch props[key] {
            case let v as Bool: out[key] = v
            case let v as Int: out[key] = v
            case let v as Double where v.isFinite: out[key] = v
            case let v as String: out[key] = String(v.prefix(64))
            default: continue
            }
        }
        return out
    }

    // MARK: Buckets

    /// How long a floating window stayed open.
    public static func durationBucket(seconds: Double) -> String {
        switch seconds {
        case ..<10: "lt10s"
        case ..<60: "10s_1m"
        case ..<300: "1_5m"
        case ..<900: "5_15m"
        case ..<1800: "15_30m"
        case ..<3600: "30_60m"
        case ..<7200: "1_2h"
        default: "2h_plus"
        }
    }

    /// Latency of an operation (floating an app, opening the browser…).
    public static func latencyBucket(ms: Double) -> String {
        switch ms {
        case ..<250: "lt250ms"
        case ..<500: "250_500ms"
        case ..<1000: "500ms_1s"
        case ..<2000: "1_2s"
        case ..<5000: "2_5s"
        default: "5s_plus"
        }
    }

    /// Video height → a resolution class.
    public static func resolutionBucket(height: Int) -> String {
        switch height {
        case ..<1: "unknown"
        case ..<481: "sd"
        case ..<721: "720p"
        case ..<1081: "1080p"
        case ..<1441: "1440p"
        default: "4k"
        }
    }

    public static func fpsBucket(_ fps: Int) -> String {
        switch fps {
        case ..<1: "0"
        case ..<15: "lt15"
        case ..<25: "15_24"
        case ..<35: "25_34"
        case ..<55: "35_54"
        default: "55_plus"
        }
    }

    /// Small counts (tabs, displays, extensions): 0, 1, 2, 3_5, 6_10, 11_plus.
    public static func countBucket(_ n: Int) -> String {
        switch n {
        case ..<1: "0"
        case 1: "1"
        case 2: "2"
        case 3...5: "3_5"
        case 6...10: "6_10"
        default: "11_plus"
        }
    }

    /// Opacity setting as a percentage step (100, 85, 70, 50, or "other").
    public static func opacityBucket(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return [100, 85, 70, 50].contains(pct) ? String(pct) : "other"
    }

    /// Playback speeds offered in the speed menu; anything else is "other".
    public static func rateBucket(_ rate: Double) -> String {
        let known: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.85, 3]
        guard let hit = known.first(where: { abs($0 - rate) < 0.001 }) else { return "other" }
        return hit == hit.rounded() ? String(Int(hit)) : String(hit)
    }

    // MARK: Stable fingerprints (Swift's hashValue is randomised per process)

    /// FNV-1a 32-bit, hex: the same input gives the same fingerprint on every run.
    public static func fingerprint(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(hash, radix: 16)
    }

    /// Stack frames without addresses/offsets, so a fingerprint survives ASLR:
    /// "3  PiPAnywhere  0x0001  $s4main3fooyyF + 12" → "PiPAnywhere $s4main3fooyyF".
    public static func symbolOnly(_ frame: String) -> String {
        let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return frame }
        // [index, module, address, symbol..., "+", offset]
        var symbol = parts.dropFirst(3)
        if symbol.count >= 2, symbol[symbol.endIndex - 2] == "+" { symbol = symbol.dropLast(2) }
        return "\(parts[1]) \(symbol.joined(separator: " "))"
    }

    public static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGABRT: "SIGABRT"
        case SIGFPE: "SIGFPE"
        case SIGTRAP: "SIGTRAP"
        default: "SIG\(signal)"
        }
    }

    // MARK: Video stream stop reasons (the extension sends fixed English strings)

    public static func stopReason(_ text: String) -> String {
        switch text {
        case "closed from the browser": "closed_browser"
        case "switched tabs": "switched_tabs"
        case "back to the tab": "back_to_tab"
        case "closed in the app": "closed_in_app"
        case "tab closed": "tab_closed"
        case "app disconnected": "app_disconnected"
        case "capture ended": "capture_ended"
        case "start failed": "start_failed"
        case "replaced": "replaced"
        case "error": "error"
        default: "other"
        }
    }

    // MARK: Extension-reported events

    /// The only events (and prop values) the browser extension may report through the app.
    /// Anything else is dropped, so a modified extension can't smuggle data through.
    public static let extensionEvents: [String: [String: Set<String>]] = [
        "ext_installed": ["reason": ["install", "update", "browser_update", "other"]],
        "ext_toggle": ["via": ["button", "shortcut", "context_menu", "test"]],
        "ext_start": ["result": ["ok", "no_video", "app_not_running", "capture_failed", "error"]],
        "ext_stop": ["reason": ["closed_browser", "switched_tabs", "back_to_tab", "closed_in_app", "tab_closed",
                                "app_disconnected", "capture_ended", "start_failed", "replaced", "error", "other"]],
        "ext_script_injected": [:],
        "ext_page_reloaded": [:],
        "ext_error": ["where": ["background", "offscreen"],
                      "kind": ["uncaught", "rejection", "encoder", "frame", "no_encoder"]],
        "ext_encoder": ["res": ["sd", "720p", "1080p", "1440p", "4k", "unknown"]],
    ]

    public struct ExtensionItem: Equatable, Sendable {
        public var name: String
        public var props: [String: String]
        public var count: Int
        public var day: String?
    }

    /// Validates items from a `{"type":"usage","items":[{n,p,c,d}]}` message.
    public static func sanitizeExtensionItems(_ raw: [[String: Any]], today: String) -> [ExtensionItem] {
        var out: [ExtensionItem] = []
        for item in raw.prefix(200) {
            guard let name = item["n"] as? String, let allowed = extensionEvents[name] else { continue }
            var props: [String: String] = [:]
            var ok = true
            for (key, value) in item["p"] as? [String: Any] ?? [:] {
                guard let values = allowed[key], let v = value as? String, values.contains(v) else { ok = false; break }
                props[key] = v
            }
            guard ok else { continue }
            let count = min(max((item["c"] as? Int) ?? 1, 1), 10_000)
            var day = item["d"] as? String
            if let d = day, d.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil || d > today { day = nil }
            out.append(ExtensionItem(name: name, props: props, count: count, day: day))
        }
        return out
    }
}
