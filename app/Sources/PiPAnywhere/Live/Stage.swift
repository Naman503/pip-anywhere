import AppKit
import CVirtualDisplay

/// The hidden "stage": a virtual display that floated app windows live on, so they
/// are never covered, minimized or on another Space, and keep rendering at full rate.
/// It disappears automatically when the process exits, and windows on it return to
/// the real screens.
@MainActor
final class Stage {
    /// Looks-like size of the stage in points; HiDPI doubles the pixels.
    static let size = CGSize(width: 1600, height: 1000)

    private var display: PAVirtualDisplay?

    var displayID: CGDirectDisplayID? { display?.displayID }
    var isActive: Bool { display != nil }

    /// Creates the stage if needed. Returns false if the private API is unavailable.
    @discardableResult
    func create() -> Bool {
        if display != nil { return true }
        guard PAVirtualDisplay.isAvailable() else {
            log("stage: CGVirtualDisplay is not available on this macOS")
            return false
        }
        let mainBefore = CGMainDisplayID()
        let size = Self.size
        display = PAVirtualDisplay(
            name: "PiP Anywhere Stage",
            maxPixels: CGSize(width: size.width * 2, height: size.height * 2),
            modes: [NSValue(size: size)],
            refreshRate: 60,
            hiDPI: true
        )
        guard let id = displayID else {
            log("stage: could not create the virtual display")
            return false
        }
        // A new display can be adopted as the main one (menu bar moves); never allow that.
        if CGMainDisplayID() != mainBefore {
            log("stage: WARNING main display changed \(mainBefore) → \(CGMainDisplayID())")
        }
        log("stage: created display \(id) \(describe())")
        return true
    }

    func destroy() {
        guard let id = displayID else { return }
        display = nil
        log("stage: destroyed display \(id)")
    }

    /// Stage bounds in global display coordinates (points, origin top-left of the main display).
    var bounds: CGRect {
        guard let id = displayID else { return .zero }
        return CGDisplayBounds(id)
    }

    var screen: NSScreen? {
        guard let id = displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    /// Where floated windows go: inside the stage's visible area (below its menu bar
    /// strip, away from the edges so the Dock is never triggered), global top-left coordinates.
    var workArea: CGRect {
        let b = bounds
        guard let screen, let primary = NSScreen.screens.first else { return b.insetBy(dx: 40, dy: 40) }
        let v = screen.visibleFrame
        let topLeftY = primary.frame.maxY - v.maxY
        return CGRect(x: v.minX, y: topLeftY, width: v.width, height: v.height).insetBy(dx: 40, dy: 40)
    }

    func describe() -> String {
        guard let id = displayID else { return "(no stage)" }
        let b = bounds
        var mode = "?"
        if let m = CGDisplayCopyDisplayMode(id) {
            mode = "\(m.width)×\(m.height) pt, \(m.pixelWidth)×\(m.pixelHeight) px @\(Int(m.refreshRate)) Hz"
        }
        let scale = screen?.backingScaleFactor ?? 0
        return "bounds \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height)) · mode \(mode) · scale \(scale) · main \(CGMainDisplayID() == id ? "STAGE (bad)" : "unchanged") · work area \(workArea.integral)"
    }
}
