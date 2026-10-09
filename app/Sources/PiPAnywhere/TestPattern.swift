import AppKit
import CoreMedia
import CoreVideo

/// A moving 1280×720 test card, so the window can be checked without a browser
/// (menu bar → "Show test pattern", or launch with --test-pattern).
final class TestPattern: @unchecked Sendable { // runs on the renderer queue
    private let renderer: VideoRenderer
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private let size = CGSize(width: 1280, height: 720)

    init(renderer: VideoRenderer) {
        self.renderer = renderer
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: renderer.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        frame += 1
        guard let buffer = draw(frame: frame) else { return }
        renderer.enqueue(pixelBuffer: buffer, time: CMTime(value: CMTimeValue(frame), timescale: 30))
    }

    private func draw(frame: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Background bars
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple]
        let barWidth = size.width / CGFloat(colors.count)
        for (i, color) in colors.enumerated() {
            ctx.setFillColor(color.withAlphaComponent(0.55).cgColor)
            ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: 0, width: barWidth, height: size.height))
        }
        // Moving marker shows motion smoothness.
        let x = CGFloat(frame * 8 % Int(size.width))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: x, y: 0, width: 24, height: size.height))

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let text = "PiP Anywhere test pattern\nframe \(frame) · \(Date().formatted(date: .omitted, time: .standard))"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 54, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
            .strokeColor: NSColor.black,
            .strokeWidth: -3,
        ]
        text.draw(in: CGRect(x: 0, y: size.height / 2 - 90, width: size.width, height: 180), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return buffer
    }
}
