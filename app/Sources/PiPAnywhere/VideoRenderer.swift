import AppKit
import AVFoundation
import CoreMedia
import PiPCore

/// Feeds H.264 access units (or raw pixel buffers for the test pattern) into an
/// AVSampleBufferDisplayLayer, which decodes in hardware. All methods must be
/// called on `queue`.
final class VideoRenderer: @unchecked Sendable { // confined to `queue`
    let layer = AVSampleBufferDisplayLayer()
    let queue = DispatchQueue(label: "pipanywhere.video", qos: .userInteractive)

    /// Called (on `queue`) when the decoder needs a key frame to resume.
    var onNeedKeyframe: (() -> Void)?
    /// Called (on `queue`) about once a second with stream statistics.
    var onStats: ((StreamStats) -> Void)?

    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private var counter = StatsCounter()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    private var renderer: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }

    func configure(_ config: StreamConfig) {
        guard let avcC = config.avcC else {
            log("config without a valid avcC description")
            return
        }
        let atoms = ["avcC": avcC as CFData] as CFDictionary
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: Int32(config.width),
            height: Int32(config.height),
            extensions: extensions,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            log("CMVideoFormatDescriptionCreate failed: \(status)")
            return
        }
        format = description
        waitingForKeyframe = true
        counter.size = (config.width, config.height)
    }

    func enqueue(_ packet: VideoPacket) {
        guard let format else { return }
        if waitingForKeyframe {
            guard packet.kind == .key else { return }
            waitingForKeyframe = false
        }
        recoverIfFailed()

        var block: CMBlockBuffer?
        let length = packet.payload.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return }
        packet.payload.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(packet.timestamp), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var size = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        markDisplayImmediately(sample, isKeyframe: packet.kind == .key)
        renderer.enqueue(sample)
        counter.count(bytes: length, report: onStats)
    }

    /// Test pattern / raw frames: no decoding needed.
    func enqueue(pixelBuffer: CVPixelBuffer, time: CMTime) {
        recoverIfFailed()
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
        guard let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        guard let sample else { return }
        markDisplayImmediately(sample, isKeyframe: true)
        renderer.enqueue(sample)
        counter.size = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        counter.count(bytes: 0, report: onStats)
    }

    func reset() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        format = nil
        waitingForKeyframe = true
    }

    private func recoverIfFailed() {
        guard renderer.status == .failed else { return }
        log("decoder failed (\(renderer.error?.localizedDescription ?? "unknown")); flushing")
        renderer.flush()
        waitingForKeyframe = true
        onNeedKeyframe?()
    }

    private func markDisplayImmediately(_ sample: CMSampleBuffer, isKeyframe: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
        if !isKeyframe {
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
    }
}

struct StreamStats: Equatable {
    var width = 0
    var height = 0
    var fps = 0
    var kbps = 0

    var summary: String {
        width == 0 ? "no video" : "\(width)×\(height) · \(fps) fps" + (kbps > 0 ? " · \(String(format: "%.1f", Double(kbps) / 1000)) Mbps" : "")
    }
}

private struct StatsCounter {
    var size = (0, 0)
    private var frames = 0
    private var bytes = 0
    private var windowStart = Date()

    mutating func count(bytes: Int, report: ((StreamStats) -> Void)?) {
        // After an idle gap (new stream), start a fresh measuring window.
        if Date().timeIntervalSince(windowStart) > 2 {
            windowStart = Date()
            frames = 0
            self.bytes = 0
        }
        frames += 1
        self.bytes += bytes
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= 1 else { return }
        report?(StreamStats(
            width: size.0, height: size.1,
            fps: Int((Double(frames) / elapsed).rounded()),
            kbps: Int(Double(self.bytes) * 8 / 1000 / elapsed)
        ))
        frames = 0
        self.bytes = 0
        windowStart = Date()
    }
}
