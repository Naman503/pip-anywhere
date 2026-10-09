import AppKit
import ScreenCaptureKit

/// Captures one app's window on the stage and shows it in `layer`, zero-copy: each
/// frame's IOSurface becomes the layer's contents. ScreenCaptureKit only delivers
/// "complete" frames when pixels changed; idle frames cost nothing and are skipped.
final class StageCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Shown inside the panel. Contents are set on the main thread.
    let layer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }()

    struct Stats {
        var complete = 0
        var idle = 0
    }

    /// Called on the main thread about once a second.
    var onStats: ((Stats) -> Void)?

    private let queue = DispatchQueue(label: "pipanywhere.live.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var configuration = SCStreamConfiguration()
    /// Keeps the frame on screen alive (its IOSurface must not be recycled).
    private var current: CMSampleBuffer?
    private var stats = Stats()
    private var statsStart = Date()

    /// `sourceRect` is in the stage display's own points (origin top-left).
    @MainActor
    func start(displayID: CGDirectDisplayID, pid: pid_t, sourceRect: CGRect, scale: CGFloat, fps: Int) async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw LiveError.message("stage display not found in shareable content")
        }
        guard let app = content.applications.first(where: { $0.processID == pid }) else {
            throw LiveError.message("app \(pid) not found in shareable content")
        }
        // Display + app filter (not a single-window filter) so the app's menus,
        // dropdowns and popups, which are separate windows, are captured too.
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(sourceRect.width * scale)
        config.height = Int(sourceRect.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA // no chroma subsampling: sharp coloured text
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = false // the real cursor is drawn by the panel's overlay
        config.queueDepth = 4
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        if #available(macOS 14.2, *) { config.includeChildWindows = true }
        config.shouldBeOpaque = true
        configuration = config

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        layer.contentsScale = scale
        log("live capture: started \(config.width)×\(config.height) px from \(sourceRect.integral) at ≤\(fps) fps")
    }

    /// Live changes: crop rectangle (window moved/resized) and frame rate.
    func update(sourceRect: CGRect? = nil, scale: CGFloat? = nil, fps: Int? = nil) async {
        guard let stream else { return }
        let config = configuration
        if let sourceRect {
            config.sourceRect = sourceRect
            let s = scale ?? CGFloat(config.width) / max(config.sourceRect.width, 1)
            config.width = Int(sourceRect.width * s)
            config.height = Int(sourceRect.height * s)
        }
        if let fps { config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps)) }
        configuration = config
        do {
            try await stream.updateConfiguration(config)
        } catch {
            log("live capture: update failed: \(error)")
        }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        queue.async { self.current = nil }
        log("live capture: stopped")
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }

        if status == .complete, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
           let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
            stats.complete += 1
            let previous = current
            current = sampleBuffer
            DispatchQueue.main.async { [layer] in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.contents = surface
                CATransaction.commit()
                _ = previous // released after the new frame is on screen
            }
        } else if status == .idle {
            stats.idle += 1
        }

        if Date().timeIntervalSince(statsStart) >= 1 {
            let snapshot = stats
            stats = Stats()
            statsStart = Date()
            DispatchQueue.main.async { self.onStats?(snapshot) }
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("live capture: stream stopped with error: \(error)")
    }
}

enum LiveError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case let .message(m): m
        }
    }
}
