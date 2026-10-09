import AppKit

enum PanelLevel: String, CaseIterable {
    case floating, statusBar, screenSaver

    var level: NSWindow.Level {
        switch self {
        case .floating: .floating
        case .statusBar: .statusBar
        case .screenSaver: .screenSaver
        }
    }

    var title: String {
        switch self {
        case .floating: "Floating"
        case .statusBar: "Status bar (default)"
        case .screenSaver: "Screen saver (above everything)"
        }
    }
}

/// UserDefaults-backed preferences. Another process can change them with
/// `defaults write local.pipanywhere.PiPAnywhere <key> <value>` and then post the
/// distributed notification `Settings.reloadNotification` (used by spikes/tests).
enum Settings {
    static let reloadNotification = Notification.Name("local.pipanywhere.reload")
    static let commandNotification = Notification.Name("local.pipanywhere.command")

    /// Copies started on a non-default --port (tests) keep their own preferences,
    /// so they never change the real app's window position or options.
    private(set) static var defaults = UserDefaults.standard

    static func useSeparateStore(for port: UInt16) {
        defaults = UserDefaults(suiteName: "local.pipanywhere.PiPAnywhere.port\(port)") ?? .standard
    }

    static var level: PanelLevel {
        get { PanelLevel(rawValue: defaults.string(forKey: "level") ?? "") ?? .statusBar }
        set { defaults.set(newValue.rawValue, forKey: "level") }
    }

    static var opacity: Double {
        get { defaults.object(forKey: "opacity") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "opacity") }
    }

    static var snapToCorners: Bool {
        get { defaults.object(forKey: "snapToCorners") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "snapToCorners") }
    }

    /// Keep the window still while swiping between desktops (see StickySpace).
    static var stayStillOnSpaceSwitch: Bool {
        get { defaults.object(forKey: "stayStillOnSpaceSwitch") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stayStillOnSpaceSwitch") }
    }

    static var muteWhenStashed: Bool {
        get { defaults.bool(forKey: "muteWhenStashed") }
        set { defaults.set(newValue, forKey: "muteWhenStashed") }
    }

    /// Thin progress line along the bottom while the controls are hidden.
    static var showProgressLine: Bool {
        get { defaults.object(forKey: "showProgressLine") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showProgressLine") }
    }

    /// Two-finger scroll over the window seeks (sideways) and changes volume (up/down).
    static var scrollGestures: Bool {
        get { defaults.object(forKey: "scrollGestures") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "scrollGestures") }
    }

    static var hideFromScreenSharing: Bool {
        get { defaults.bool(forKey: "hideFromScreenSharing") }
        set { defaults.set(newValue, forKey: "hideFromScreenSharing") }
    }

    static var pauseWhenStashed: Bool {
        get { defaults.bool(forKey: "pauseWhenStashed") }
        set { defaults.set(newValue, forKey: "pauseWhenStashed") }
    }

    /// Size of the last live app surface (restored next time).
    static var liveSurfaceSize: CGSize? {
        get { defaults.string(forKey: "liveSurfaceSize").map(NSSizeFromString).flatMap { $0.width > 0 ? $0 : nil } }
        set { defaults.set(newValue.map(NSStringFromSize), forKey: "liveSurfaceSize") }
    }

    static var savedFrame: NSRect? {
        get { defaults.string(forKey: "frame").map(NSRectFromString).flatMap { $0.width > 0 ? $0 : nil } }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: "frame") }
    }
}

/// Logs to stderr and to ~/Library/Logs/PiP Anywhere/PiPAnywhere.log (kept under ~2 MB),
/// so problems can be diagnosed even when the app was opened from Finder.
func log(_ message: String) {
    let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
    let line = Data("[\(stamp)] \(message)\n".utf8)
    FileHandle.standardError.write(line)
    LogFile.shared.append(line)
}

final class LogFile: @unchecked Sendable {
    static let shared = LogFile()
    private let queue = DispatchQueue(label: "pipanywhere.log")
    let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/PiP Anywhere", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("PiPAnywhere.log")
    }()

    func append(_ data: Data) {
        queue.async { [url] in
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url.appendingPathExtension("old"))
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
