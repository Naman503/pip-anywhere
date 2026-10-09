import AppKit
import ApplicationServices

/// Real-cursor input for live apps. Pointing at the panel warps the actual cursor to
/// the same spot on the floated window on the stage, so every click, scroll, drag,
/// right-click and keystroke is genuine hardware input to the real app. Moving past
/// the window's edge warps the cursor back to the matching edge of the panel.
///
/// All rectangles are global display points, origin at the main display's top-left.
@MainActor
final class CursorBridge {
    /// The panel's live surface on screen.
    var surfaceRect: () -> CGRect = { .zero }
    /// The floated window on the stage.
    var stageWindowRect: () -> CGRect = { .zero }
    /// The whole stage display (stray-cursor guard).
    var stageBounds: () -> CGRect = { .zero }
    /// Overlay cursor position in surface-local points; nil hides it.
    var onCursor: (CGPoint?) -> Void = { _ in }
    var onCaptureChange: (Bool) -> Void = { _ in }
    /// The floated app, so focus can be handed back when leaving it.
    var targetPID: pid_t = 0
    var returnFocusOnExit = true

    private(set) var isCaptured = false
    private var monitor: Any?
    private var previousApp: NSRunningApplication?
    private var lastExit = Date.distantPast

    init() {
        // Without this, macOS swallows mouse events for 0.25 s after every warp.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
    }

    func activate() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.moved(type) }
        }
    }

    func deactivate() {
        if isCaptured { release() }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The pointer entered the panel's live surface at `local` (surface points).
    func enter(at local: CGPoint) {
        guard !isCaptured, Date().timeIntervalSince(lastExit) > 0.15 else { return }
        let window = stageWindowRect()
        guard window.width > 0 else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != targetPID { previousApp = front }
        isCaptured = true
        warp(to: CGPoint(x: window.minX + local.x, y: window.minY + local.y))
        onCursor(local)
        onCaptureChange(true)
    }

    /// Escape hotkey / stash / close: put the cursor back on the panel's top bar.
    func release() {
        guard isCaptured else { return }
        let surface = surfaceRect()
        finishExit(at: CGPoint(x: surface.midX, y: surface.minY - 8))
    }

    private func moved(_ type: NSEvent.EventType) {
        guard let p = CGEvent(source: nil)?.location else { return }
        let window = stageWindowRect()
        if isCaptured {
            if window.contains(p) {
                onCursor(CGPoint(x: p.x - window.minX, y: p.y - window.minY))
            } else if type == .mouseMoved {
                exit(from: p, window: window)
            } else {
                // Dragging past the edge (e.g. selecting text): keep the drag, clamp the overlay.
                onCursor(CGPoint(x: min(max(p.x - window.minX, 0), window.width), y: min(max(p.y - window.minY, 0), window.height)))
            }
        } else if stageBounds().contains(p) {
            // The cursor wandered onto the stage on its own (it sits beside the screen).
            let main = CGDisplayBounds(CGMainDisplayID()).insetBy(dx: 2, dy: 2)
            warp(to: CGPoint(x: min(max(p.x, main.minX), main.maxX), y: min(max(p.y, main.minY), main.maxY)))
        }
    }

    /// Leaves through the edge the cursor crossed, landing just outside the panel there.
    private func exit(from p: CGPoint, window: CGRect) {
        let surface = surfaceRect()
        var target = CGPoint(
            x: surface.minX + min(max(p.x - window.minX, 0), surface.width),
            y: surface.minY + min(max(p.y - window.minY, 0), surface.height)
        )
        if p.x < window.minX { target.x = surface.minX - 4 }
        if p.x > window.maxX { target.x = surface.maxX + 4 }
        if p.y < window.minY { target.y = surface.minY - 4 }
        if p.y > window.maxY { target.y = surface.maxY + 4 }
        finishExit(at: target)
    }

    private func finishExit(at point: CGPoint) {
        isCaptured = false
        lastExit = Date()
        warp(to: point)
        onCursor(nil)
        onCaptureChange(false)
        if returnFocusOnExit { handFocusBack() }
    }

    /// Give the keyboard back to the app the user was in before pointing at the panel.
    private func handFocusBack() {
        guard let previous = previousApp, !previous.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
        // A background app can't simply activate another one on macOS 14+;
        // the Accessibility "frontmost" attribute can.
        let element = AXUIElementCreateApplication(previous.processIdentifier)
        if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
            previous.activate()
        }
    }

    private func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
