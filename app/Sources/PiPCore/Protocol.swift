import Foundation

/// Wire protocol between the browser extension and the app. See docs/protocol.md.
public enum WireProtocol {
    public static let port: UInt16 = 47823
    public static let extensionOrigin = "chrome-extension://angpoecfkgeeclnkdmafakhldmadjdih"
    public static let version = "1"
}

// MARK: - Binary video packets

public enum FrameKind: UInt8, Sendable {
    case key = 1
    case delta = 2
}

public struct VideoPacket: Sendable, Equatable {
    public static let headerSize = 9

    public var kind: FrameKind
    /// Presentation timestamp in microseconds.
    public var timestamp: Double
    /// One H.264 access unit, AVCC (length-prefixed) NAL units.
    public var payload: Data

    public init(kind: FrameKind, timestamp: Double, payload: Data) {
        self.kind = kind
        self.timestamp = timestamp
        self.payload = payload
    }

    /// `[kind: u8][timestamp: f64 LE][payload]`, or nil if malformed.
    public static func parse(_ data: Data) -> VideoPacket? {
        guard data.count > headerSize, let kind = FrameKind(rawValue: data[data.startIndex]) else { return nil }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits |= UInt64(data[data.startIndex + 1 + i]) << (8 * UInt64(i))
        }
        let timestamp = Double(bitPattern: bits)
        guard timestamp.isFinite else { return nil }
        return VideoPacket(kind: kind, timestamp: timestamp, payload: data.subdata(in: (data.startIndex + headerSize)..<data.endIndex))
    }

    public func serialized() -> Data {
        var data = Data([kind.rawValue])
        var bits = timestamp.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

// MARK: - JSON messages

public struct StreamConfig: Codable, Equatable, Sendable {
    public var codec: String
    public var width: Int
    public var height: Int
    /// base64 avcC (AVCDecoderConfigurationRecord).
    public var description: String
    /// Size of the captured tab frame the video was cropped from (diagnostics).
    public var sourceWidth: Int?
    public var sourceHeight: Int?

    public var avcC: Data? { Data(base64Encoded: description) }

    public init(codec: String, width: Int, height: Int, description: String) {
        self.codec = codec
        self.width = width
        self.height = height
        self.description = description
    }
}

public struct PlaybackState: Codable, Equatable, Sendable {
    public var title: String
    public var site: String
    public var paused: Bool
    public var currentTime: Double
    public var duration: Double
    public var rate: Double
    /// 0...1. Optional: older extension builds don't send it.
    public var volume: Double?
    public var muted: Bool?

    public init(title: String, site: String, paused: Bool, currentTime: Double, duration: Double, rate: Double,
                volume: Double? = nil, muted: Bool? = nil) {
        self.title = title
        self.site = site
        self.paused = paused
        self.currentTime = currentTime
        self.duration = duration
        self.rate = rate
        self.volume = volume
        self.muted = muted
    }
}

public enum Inbound: Equatable, Sendable {
    case hello(version: String)
    case config(StreamConfig)
    case state(PlaybackState)
    case stop(reason: String)
    case unknown(type: String)

    private struct Envelope: Decodable {
        var type: String
        var version: String?
        var reason: String?
    }

    public static func decode(_ data: Data) -> Inbound? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        switch envelope.type {
        case "hello":
            return .hello(version: envelope.version ?? "?")
        case "config":
            return (try? decoder.decode(StreamConfig.self, from: data)).map(Inbound.config)
        case "state":
            return (try? decoder.decode(PlaybackState.self, from: data)).map(Inbound.state)
        case "stop":
            return .stop(reason: envelope.reason ?? "")
        default:
            return .unknown(type: envelope.type)
        }
    }
}

public enum CommandAction: String, Codable, Sendable {
    case play, pause, toggle, seek, seekTo, rate, focusTab, close
    /// value 0...1
    case volume
    /// value 1 = mute, 0 = unmute
    case mute
}

public enum Outbound: Equatable, Sendable {
    case hello
    case command(CommandAction, value: Double? = nil)
    case keyframe

    public func encoded() -> Data {
        var object: [String: Any]
        switch self {
        case .hello:
            object = ["type": "hello", "version": WireProtocol.version]
        case let .command(action, value):
            object = ["type": "command", "action": action.rawValue]
            if let value { object["value"] = value }
        case .keyframe:
            object = ["type": "keyframe"]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
