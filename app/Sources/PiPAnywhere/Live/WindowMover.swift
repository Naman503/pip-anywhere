import AppKit
import ApplicationServices

/// Finds, moves and resizes other apps' windows through the Accessibility API.
/// Coordinates are global display points with the origin at the main display's top-left
/// (the Accessibility / Core Graphics convention).
@MainActor
enum WindowMover {
    struct Window {
        let element: AXUIElement
        let pid: pid_t
        let windowID: CGWindowID?
        let appName: String
        let title: String
    }

    /// Whether we may control other apps; `prompt` shows the system dialog.
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// All of the app's standard windows.
    static func standardWindows(of app: NSRunningApplication) -> [Window] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let all: [AXUIElement] = copy(appElement, kAXWindowsAttribute) ?? []
        return all.filter { (copy($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }.map {
            Window(element: $0, pid: app.processIdentifier, windowID: windowID(of: $0),
                   appName: app.localizedName ?? "App", title: copy($0, kAXTitleAttribute) ?? "")
        }
    }

    static func windowIDs(of app: NSRunningApplication) -> Set<CGWindowID> {
        Set(standardWindows(of: app).compactMap(\.windowID))
    }

    /// Clicks the window's close button (like the user would).
    @discardableResult
    static func close(_ window: Window) -> Bool {
        guard let button: AXUIElement = copy(window.element, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// The app's focused / main / first standard window.
    static func mainWindow(of app: NSRunningApplication) -> Window? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var candidates: [AXUIElement] = []
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w: AXUIElement = copy(appElement, attribute) { candidates.append(w) }
        }
        if let all: [AXUIElement] = copy(appElement, kAXWindowsAttribute) { candidates += all }
        guard let element = candidates.first(where: { (copy($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole })
            ?? candidates.first else { return nil }
        return Window(
            element: element,
            pid: app.processIdentifier,
            windowID: windowID(of: element),
            appName: app.localizedName ?? "App",
            title: copy(element, kAXTitleAttribute) ?? ""
        )
    }

    static func frame(of window: Window) -> CGRect? {
        guard let posValue: AXValue = copy(window.element, kAXPositionAttribute),
              let sizeValue: AXValue = copy(window.element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Moves and resizes. Size is set before and after the move because macOS clamps a
    /// window's size to the display it is currently on.
    @discardableResult
    static func setFrame(_ window: Window, _ frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return false }
        let first = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sz)
        let move = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, pos)
        let second = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sz)
        if move != .success || (first != .success && second != .success) {
            log("window mover: set frame failed (move \(move.rawValue), size \(first.rawValue)/\(second.rawValue))")
            return false
        }
        return true
    }

    /// Native full-screen windows live in their own Space and can't be moved.
    static func isFullScreen(_ window: Window) -> Bool {
        (copy(window.element, "AXFullScreen") as Bool?) ?? false
    }

    @discardableResult
    static func setFullScreen(_ window: Window, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(window.element, "AXFullScreen" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    enum Liveness { case alive, gone, unknown }

    /// `.gone` only when macOS says the window no longer exists. A busy app (e.g. while
    /// it re-lays out during a resize) can time out; that is `.unknown`, not closed.
    static func liveness(_ window: Window) -> Liveness {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &value) {
        case .success: return .alive
        case .invalidUIElement: return .gone
        default: return .unknown
        }
    }

    static func isAlive(_ window: Window) -> Bool { liveness(window) != .gone }

    // MARK: Private

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// `_AXUIElementGetWindow` (private, widely used) maps an AX window to its CGWindowID.
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindow.self) }

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}
