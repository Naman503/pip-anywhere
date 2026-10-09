import Foundation
import Network
import PiPCore

/// Loopback WebSocket server the extension streams into. One client at a time:
/// a new connection replaces the previous one. Callbacks run on `queue`.
final class MediaServer: @unchecked Sendable { // confined to `queue`
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onMessage: ((Inbound) -> Void)?
    var onVideo: ((VideoPacket) -> Void)?

    private let port: UInt16
    private let allowedOrigins: Set<String>
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connection: NWConnection?

    init(port: UInt16, allowedOrigins: Set<String>, queue: DispatchQueue) {
        self.port = port
        self.allowedOrigins = allowedOrigins
        self.queue = queue
    }

    func start() throws {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 16 * 1024 * 1024
        let origins = allowedOrigins
        websocket.setClientRequestHandler(queue) { _, headers in
            // Browsers always send Origin; only our extension may connect.
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let accepted = origins.contains(origin)
            if !accepted { log("rejected WebSocket from origin '\(origin)'") }
            return NWProtocolWebSocket.Response(status: accepted ? .accept : .reject, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("listening on ws://127.0.0.1:\(listener.port?.rawValue ?? 0)")
            case let .failed(error): log("listener failed: \(error)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func send(_ message: Outbound) {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: message.encoded(), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func accept(_ new: NWConnection) {
        if let old = connection {
            log("replacing previous stream connection")
            old.cancel()
        }
        connection = new
        new.stateUpdateHandler = { [weak self, weak new] state in
            guard let self, let new else { return }
            switch state {
            case .ready:
                log("extension connected")
                self.onConnect?()
            case .failed, .cancelled:
                if self.connection === new {
                    self.connection = nil
                    log("extension disconnected")
                    self.onDisconnect?()
                }
            default:
                break
            }
        }
        new.start(queue: queue)
        receive(on: new)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                if self.connection === connection { log("receive error: \(error)") }
                connection.cancel()
                return
            }
            if let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .binary:
                    if let packet = VideoPacket.parse(data) { self.onVideo?(packet) }
                case .text:
                    if let message = Inbound.decode(data) { self.onMessage?(message) }
                case .close:
                    connection.cancel()
                    return
                default:
                    break
                }
            }
            // Keep reading unless the connection was replaced or closed.
            if connection.state == .ready || connection.state == .preparing || connection.state == .setup {
                self.receive(on: connection)
            }
        }
    }
}
