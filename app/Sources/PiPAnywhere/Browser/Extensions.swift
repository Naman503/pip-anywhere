import AppKit
import WebKit

/// Web extensions for the floating browser (WebKit's WKWebExtension, macOS 15.4+).
/// Every unpacked extension (a folder with a manifest.json) in
/// ~/Library/Application Support/PiP Anywhere/Extensions is loaded, with the
/// permissions it asks for. Content scripts, declarativeNetRequest ad blockers and
/// storage work; toolbar popups don't have a place in the window yet.
@MainActor
enum BrowserExtensions {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PiP Anywhere/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Unpacked extension folders (symbolic links to a build folder work too).
    static func installed() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items
            .map { $0.resolvingSymlinksInPath() }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Builds a controller with every installed extension loaded; nil before macOS 15.4
    /// or when there are none.
    static func makeController() async -> AnyObject? {
        guard #available(macOS 15.4, *) else {
            log("extensions: need macOS 15.4 or later")
            return nil
        }
        let folders = installed()
        guard !folders.isEmpty else { return nil }
        let controller = WKWebExtensionController(configuration: .default())
        for url in folders {
            do {
                let ext = try await WKWebExtension(resourceBaseURL: url)
                let context = WKWebExtensionContext(for: ext)
                // The user put it there themselves: grant what it asks for.
                for permission in ext.requestedPermissions {
                    context.setPermissionStatus(.grantedExplicitly, for: permission)
                }
                for pattern in ext.allRequestedMatchPatterns {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
                context.isInspectable = true
                try controller.load(context)
                let problems = ext.errors.map(\.localizedDescription)
                log("extensions: loaded \(ext.displayName ?? url.lastPathComponent) \(ext.version ?? "")"
                    + (problems.isEmpty ? "" : " · warnings: \(problems.joined(separator: "; "))"))
            } catch {
                log("extensions: \(url.lastPathComponent) failed to load: \(error.localizedDescription)")
            }
        }
        return controller
    }

    static func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
