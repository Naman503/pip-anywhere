import AppKit
import PiPCore
import SwiftUI

/// The floating window. A non-activating panel is what lets it appear over other
/// apps' full-screen Spaces (Apple DTS, forum thread 826308); the style mask is
/// final at creation because changing it at runtime breaks windows on macOS 26.
final class PiPPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "PiP Anywhere"
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        minSize = NSSize(width: PanelGeometry.minWidth, height: PanelGeometry.minWidth * 9 / 16)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel and its behaviours: free placement (optional corner snapping),
/// edge/corner/pinch resizing, stash to edge, staying still across Space switches,
/// level / opacity / ghost / screen-sharing settings, and frame persistence.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: PiPPanel
    private let model: PlayerModel
    private var aspect: CGFloat = 16 / 9
    /// When a drag began: mouse position, window origin (what the drag moves), and
    /// where the window rested before (restored if the drag ends in a flick-to-stash).
    private var dragStart: (mouse: NSPoint, origin: NSPoint, before: NSRect)?
    private var magnifyStart: NSRect?
    private var resizeStart: (mouse: NSPoint, frame: NSRect)?
    /// Exactly where the window was before it was slid into the edge; restored on return.
    private var restingFrame: NSRect?
    /// Frame to go back to after a double-click zoom.
    private var unzoomedFrame: NSRect?
    /// Live apps are any shape; videos keep their aspect ratio.
    private var freeShape = false
    /// Frame the video window had before switching to a live app.
    private var videoFrame: NSRect?
    /// Live apps: called with the live surface's new size after a resize.
    var onLiveResize: ((CGSize) -> Void)?
    private var liveResizeWork: DispatchWorkItem?
    private var lastLiveResize = Date.distantPast
    static let liveMinSize = CGSize(width: 320, height: 220)

    init(model: PlayerModel, videoLayer: CALayer, liveLayer: CALayer, browser: BrowserModel, actions: @escaping (PanelController) -> PanelActions) {
        self.model = model
        let fallback = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Settings.savedFrame.map { PanelGeometry.keptOnScreen($0, in: Self.screenFrame(containing: $0)) }
            ?? PanelGeometry.initial(in: fallback)
        panel = PiPPanel(contentRect: frame)
        super.init()

        let hosting = PiPHostingView(rootView: PlayerView(model: model, videoLayer: videoLayer, liveLayer: liveLayer, browser: browser, actions: actions(self)))
        hosting.sizingOptions = []
        hosting.onScroll = { [weak self] event in self?.scrolled(event) }
        hosting.resizeZones = { [weak self] in
            guard let self, !model.isStashed, !model.ghost else { return nil }
            return freeShape ? ResizeZones.live : ResizeZones.video
        }
        panel.contentView = hosting
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.delegate = self
        applySettings()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func applySettings() {
        panel.level = Settings.level.level
        panel.alphaValue = model.ghost ? min(Settings.opacity, 0.35) : Settings.opacity
        panel.ignoresMouseEvents = model.ghost
        panel.sharingType = Settings.hideFromScreenSharing ? .none : .readOnly
        if panel.isVisible {
            if Settings.stayStillOnSpaceSwitch { StickySpace.attach(panel) } else { StickySpace.detach(panel) }
        }
    }

    func show() {
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
        // Ordering out drops the window from our space; re-add it every time.
        if Settings.stayStillOnSpaceSwitch { StickySpace.attach(panel) }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggleGhost() {
        model.ghost.toggle()
        applySettings()
    }

    /// Adapts the window to the video's aspect ratio.
    func setVideoSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let newAspect = CGFloat(width) / CGFloat(height)
        guard abs(newAspect - aspect) > 0.01 else { return }
        aspect = newAspect
        panel.contentAspectRatio = NSSize(width: width, height: height)
        if model.isStashed {
            restingFrame = restingFrame.map { PanelGeometry.fitted($0, aspect: aspect) }
            stash(edge: model.stashEdge)
        } else {
            panel.setFrame(PanelGeometry.fitted(panel.frame, aspect: aspect), display: true)
            settle(animated: false)
        }
    }

    // MARK: Drag, pinch, snap

    func dragChanged() {
        if dragStart == nil {
            // Dragging a stashed window out of the edge: its old resting place still counts.
            let before = model.isStashed ? (restingFrame ?? panel.frame) : panel.frame
            if model.isStashed { leaveStash() }
            dragStart = (NSEvent.mouseLocation, panel.frame.origin, before)
            unzoomedFrame = nil
        }
        guard let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    func dragEnded() {
        guard let start = dragStart else { return }
        dragStart = nil
        // Flicking the window mostly past a screen edge stashes it there; it comes back
        // to where it was before the flick.
        if let edge = PanelGeometry.stashEdge(for: panel.frame, in: visibleFrame) {
            stash(edge: edge, returningTo: start.before)
        } else {
            settle(animated: true)
        }
    }

    func magnifyChanged(_ scale: CGFloat) {
        if freeShape { return } // a pinch over a live app belongs to the app
        if magnifyStart == nil {
            magnifyStart = panel.frame
            unzoomedFrame = nil
        }
        guard let start = magnifyStart, !model.isStashed else { return }
        panel.setFrame(PanelGeometry.scaled(start, by: scale, aspect: aspect, maxSize: screenFrame.size), display: true)
    }

    /// Edge/corner handles: the opposite side stays put, aspect ratio is kept.
    func resizeChanged(_ handle: ResizeHandle) {
        if resizeStart == nil {
            resizeStart = (NSEvent.mouseLocation, panel.frame)
            unzoomedFrame = nil
        }
        guard let start = resizeStart, !model.isStashed else { return }
        let mouse = NSEvent.mouseLocation
        let delta = CGVector(dx: mouse.x - start.mouse.x, dy: mouse.y - start.mouse.y)
        let frame = freeShape
            ? PanelGeometry.resizedFree(start.frame, handle: handle, delta: delta,
                                        minSize: CGSize(width: Self.liveMinSize.width, height: Self.liveMinSize.height + LiveView.barHeight),
                                        maxSize: screenFrame.size)
            : PanelGeometry.resized(start.frame, handle: handle, delta: delta, aspect: aspect, maxSize: screenFrame.size)
        panel.setFrame(frame, display: true)
    }

    func resizeEnded() {
        resizeStart = nil
        settle(animated: true)
    }

    // MARK: Live apps

    /// Switches the window to a free-shape live app whose surface is `contentSize`.
    func enterLiveMode(contentSize: CGSize) {
        if !freeShape { videoFrame = panel.frame }
        freeShape = true
        panel.resizeIncrements = NSSize(width: 1, height: 1) // clears the aspect-ratio lock
        setLiveSurfaceSize(contentSize)
    }

    /// The floating browser: free shape, and any click makes the window take the keyboard
    /// (without activating the app, so the app you were in stays in front).
    func enterBrowserMode(size: CGSize) {
        if !freeShape { videoFrame = panel.frame }
        freeShape = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.resizeIncrements = NSSize(width: 1, height: 1)
        let frame = panel.frame
        let target = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(PanelGeometry.clamped(target, in: visibleFrame), display: true)
    }

    func focus() {
        panel.makeKey()
    }

    func exitLiveMode() {
        guard freeShape else { return }
        panel.becomesKeyOnlyIfNeeded = true
        freeShape = false
        panel.contentAspectRatio = NSSize(width: aspect, height: 1)
        if let videoFrame { panel.setFrame(videoFrame, display: true) }
        videoFrame = nil
    }

    /// Resizes the window so the live surface is exactly `size` (keeps the top-left corner,
    /// and keeps a live app fully on screen when it fits).
    func setLiveSurfaceSize(_ size: CGSize) {
        let frame = panel.frame
        let height = size.height + LiveView.barHeight
        let target = NSRect(x: frame.minX, y: frame.maxY - height, width: size.width, height: height)
        let visible = visibleFrame
        let fits = target.width <= visible.width && target.height <= visible.height
        panel.setFrame(fits ? PanelGeometry.clamped(target, in: visible) : PanelGeometry.keptOnScreen(target, in: screenFrame), display: true)
    }

    var liveSurfaceSize: CGSize {
        CGSize(width: panel.frame.width, height: panel.frame.height - LiveView.barHeight)
    }

    /// The live surface in global top-left coordinates (what the cursor bridge maps from).
    var liveSurfaceRect: CGRect {
        let frame = panel.frame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return CGRect(x: frame.minX, y: primaryTop - frame.maxY + LiveView.barHeight,
                      width: frame.width, height: frame.height - LiveView.barHeight)
    }

    /// Grow (> 1) or shrink (< 1) around the centre, from the keyboard.
    func scale(by factor: CGFloat) {
        guard !model.isStashed else { return }
        var target = PanelGeometry.scaled(panel.frame, by: factor, aspect: aspect, maxSize: screenFrame.size)
        // Growing around the centre would push a corner-parked window off-screen;
        // a window that was fully visible stays fully visible.
        if screenFrame.contains(panel.frame) { target = PanelGeometry.clamped(target, in: screenFrame) }
        move(to: target, animated: true)
        Settings.savedFrame = target
        unzoomedFrame = nil
    }

    /// Double-click: switch between the current size and a large one (half the screen
    /// width), and back to exactly where it was.
    func toggleZoom() {
        guard !model.isStashed, !freeShape else { return }
        if let previous = unzoomedFrame {
            unzoomedFrame = nil
            move(to: previous, animated: true)
            Settings.savedFrame = previous
            return
        }
        let screen = screenFrame
        let big = PanelGeometry.sized(panel.frame, width: max(screen.width * 0.5, panel.frame.width * 1.5), aspect: aspect, in: screen)
        unzoomedFrame = panel.frame
        move(to: PanelGeometry.clamped(big, in: visibleFrame), animated: true)
    }

    /// Menu size presets, keeping the window's nearest corner in place.
    func setWidth(_ width: CGFloat) {
        guard !model.isStashed else { return }
        unzoomedFrame = nil
        var target = PanelGeometry.sized(panel.frame, width: width, aspect: aspect, in: screenFrame)
        if screenFrame.contains(panel.frame) { target = PanelGeometry.clamped(target, in: screenFrame) }
        move(to: target, animated: true)
        Settings.savedFrame = target
    }

    func move(to corner: ScreenCorner) {
        if model.isStashed { leaveStash() }
        unzoomedFrame = nil
        let target = PanelGeometry.cornered(panel.frame, corner, in: visibleFrame)
        move(to: target, animated: true)
        Settings.savedFrame = target
    }

    func magnifyEnded() {
        magnifyStart = nil
        if !model.isStashed { settle(animated: true) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        settle(animated: true)
    }

    /// Any resize (our handles, the window edge, a preset) resizes a live app with it,
    /// continuously while dragging and once more at the end.
    func windowDidResize(_ notification: Notification) {
        guard freeShape else { return }
        liveResizeWork?.cancel()
        if Date().timeIntervalSince(lastLiveResize) > 0.08 {
            lastLiveResize = Date()
            onLiveResize?(liveSurfaceSize)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lastLiveResize = Date()
            onLiveResize?(liveSurfaceSize)
        }
        liveResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Where the window rests after a drag or resize: snapped to a corner if that's
    /// on, otherwise exactly where it was left (only pulled back if almost gone).
    private func restingTarget(for frame: NSRect) -> NSRect {
        if Settings.snapToCorners {
            let visible = visibleFrame
            return PanelGeometry.snapped(PanelGeometry.clamped(frame, in: visible), in: visible)
        }
        return PanelGeometry.keptOnScreen(frame, in: screenFrame)
    }

    private func settle(animated: Bool) {
        let target = restingTarget(for: panel.frame)
        if target != panel.frame { move(to: target, animated: animated) }
        Settings.savedFrame = target
    }

    // MARK: Stash

    func toggleStash() {
        if model.isStashed { unstash() } else { stash(edge: PanelGeometry.nearestEdge(of: panel.frame, in: visibleFrame)) }
    }

    /// Slides into `edge`. Remembers the current frame (or `returningTo`) exactly, so
    /// un-stashing puts the window back where it was. While already stashed (aspect or
    /// screen changes) it just re-places the window and keeps the remembered frame.
    func stash(edge: StashEdge, returningTo origin: NSRect? = nil) {
        if !model.isStashed {
            restingFrame = origin ?? panel.frame
            unzoomedFrame = nil
            if Settings.pauseWhenStashed { model.command(.pause) }
            if Settings.muteWhenStashed { model.command(.mute, 1) }
        }
        let resting = restingFrame ?? panel.frame
        model.stashEdge = edge
        model.isStashed = true
        move(to: PanelGeometry.stashed(resting, edge: edge, in: Self.screen(containing: resting)?.visibleFrame ?? visibleFrame), animated: true)
    }

    func unstash() {
        guard model.isStashed else { return }
        let target = PanelGeometry.keptOnScreen(restingFrame ?? panel.frame, in: screenFrame)
        leaveStash()
        move(to: target, animated: true)
        Settings.savedFrame = target
    }

    /// Clears the stashed state (and undoes pause/mute-while-stashed).
    private func leaveStash() {
        model.isStashed = false
        restingFrame = nil
        if Settings.pauseWhenStashed { model.command(.play) }
        if Settings.muteWhenStashed { model.command(.mute, 0) }
    }

    // MARK: Scroll

    private func scrolled(_ event: NSEvent) {
        // Momentum after lifting the fingers would overshoot.
        guard Settings.scrollGestures, !model.isStashed, model.live == nil, !model.browserActive, event.momentumPhase.isEmpty else { return }
        // Physical finger/wheel direction, whatever the "natural scrolling" setting.
        let inverted = event.isDirectionInvertedFromDevice
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX // < 0: fingers moved left
        let dy = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY // > 0: fingers moved up
        model.scroll(dx: dx, dy: dy, precise: event.hasPreciseScrollingDeltas)
    }

    // MARK: Helpers

    private func screensChanged() {
        if model.isStashed { stash(edge: model.stashEdge) } else { settle(animated: false) }
    }

    private func move(to frame: NSRect, animated: Bool) {
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private var referenceFrame: NSRect { model.isStashed ? (restingFrame ?? panel.frame) : panel.frame }

    /// Visible area (minus menu bar and Dock) of the screen the window is on.
    private var visibleFrame: NSRect { Self.screen(containing: referenceFrame)?.visibleFrame ?? Self.fallback }

    /// The whole screen the window is on.
    private var screenFrame: NSRect { Self.screenFrame(containing: referenceFrame) }

    private static let fallback = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private static func screenFrame(containing frame: NSRect) -> NSRect {
        screen(containing: frame)?.frame ?? fallback
    }

    private static func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
            ?? NSScreen.main
    }
}

/// Hosting view that hands scroll-wheel / two-finger scroll events to the controller.
final class PiPHostingView: NSHostingView<PlayerView> {
    var onScroll: ((NSEvent) -> Void)?
    /// Current resize zones (nil = none, e.g. while slid to the edge).
    var resizeZones: () -> (edge: CGFloat, corner: CGFloat)? = { nil }
    private var tracking: NSTrackingArea?
    private var showingResizeCursor = false

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    // The cursor is decided here, from the same zone geometry the drag handles use:
    // a resize arrow only in an edge/corner zone, the normal arrow everywhere else.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCursor(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateCursor(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        showingResizeCursor = false
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(event)
    }

    private func updateCursor(_ event: NSEvent) {
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        if let zones = resizeZones(), let handle = PanelGeometry.handle(at: p, in: bounds.size, edge: zones.edge, corner: zones.corner) {
            handle.cursor.set()
            showingResizeCursor = true
        } else if showingResizeCursor {
            // Leaving a resize zone: back to the arrow once; after that, views like the
            // web page set their own cursors (I-beam, link hand).
            NSCursor.arrow.set()
            showingResizeCursor = false
        }
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
