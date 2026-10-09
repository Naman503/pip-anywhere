import CoreGraphics
import Foundation
import XCTest
@testable import PiPCore

final class ProtocolTests: XCTestCase {
    func testPacketRoundTrip() {
        let packet = VideoPacket(kind: .key, timestamp: 1_234_567.5, payload: Data([0, 0, 0, 2, 0x65, 0x88]))
        XCTAssertEqual(VideoPacket.parse(packet.serialized()), packet)
    }

    func testPacketParsesSlices() {
        // Data slices have non-zero startIndex; parsing must not assume 0.
        let bytes = Data([0xFF, 0xFF]) + VideoPacket(kind: .delta, timestamp: 42, payload: Data([1, 2, 3])).serialized()
        let slice = bytes.dropFirst(2)
        XCTAssertEqual(VideoPacket.parse(slice)?.payload, Data([1, 2, 3]))
        XCTAssertEqual(VideoPacket.parse(slice)?.timestamp, 42)
    }

    func testRejectsMalformedPackets() {
        XCTAssertNil(VideoPacket.parse(Data([1, 2, 3])))
        XCTAssertNil(VideoPacket.parse(Data([9] + Array(repeating: 0, count: 12))))
    }

    func testDecodesMessages() {
        let config = #"{"type":"config","codec":"avc1.64002A","width":1280,"height":720,"description":"AQID"}"#
        XCTAssertEqual(
            Inbound.decode(Data(config.utf8)),
            .config(StreamConfig(codec: "avc1.64002A", width: 1280, height: 720, description: "AQID"))
        )
        let state = #"{"type":"state","title":"T","site":"youtube.com","paused":false,"currentTime":12.5,"duration":600,"rate":1.5}"#
        XCTAssertEqual(
            Inbound.decode(Data(state.utf8)),
            .state(PlaybackState(title: "T", site: "youtube.com", paused: false, currentTime: 12.5, duration: 600, rate: 1.5))
        )
        let withVolume = #"{"type":"state","title":"T","site":"s","paused":true,"currentTime":0,"duration":0,"rate":1,"volume":0.4,"muted":true}"#
        XCTAssertEqual(
            Inbound.decode(Data(withVolume.utf8)),
            .state(PlaybackState(title: "T", site: "s", paused: true, currentTime: 0, duration: 0, rate: 1, volume: 0.4, muted: true))
        )
        XCTAssertEqual(Inbound.decode(Data(#"{"type":"nope"}"#.utf8)), .unknown(type: "nope"))
        XCTAssertNil(Inbound.decode(Data("not json".utf8)))
    }

    func testEncodesCommands() {
        let json = String(decoding: Outbound.command(.seek, value: -10).encoded(), as: UTF8.self)
        XCTAssertEqual(json, #"{"action":"seek","type":"command","value":-10}"#)
    }
}

final class GeometryTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testSnapsToNearestCorner() {
        let f = PanelGeometry.snapped(CGRect(x: 1000, y: 600, width: 320, height: 180), in: screen)
        XCTAssertEqual(f, CGRect(x: 1440 - 16 - 320, y: 900 - 16 - 180, width: 320, height: 180))
        let g = PanelGeometry.snapped(CGRect(x: 100, y: 50, width: 320, height: 180), in: screen)
        XCTAssertEqual(g.origin, CGPoint(x: 16, y: 16))
    }

    func testStashEdgeDetection() {
        XCTAssertEqual(PanelGeometry.stashEdge(for: CGRect(x: 1400, y: 100, width: 320, height: 180), in: screen), .right)
        XCTAssertEqual(PanelGeometry.stashEdge(for: CGRect(x: -250, y: 100, width: 320, height: 180), in: screen), .left)
        // Half off-screen is a valid resting place, not a stash.
        XCTAssertNil(PanelGeometry.stashEdge(for: CGRect(x: 1280, y: 100, width: 320, height: 180), in: screen))
    }

    func testFreePlacementKeepsAGrabbableStrip() {
        let half = CGRect(x: 1280, y: 100, width: 320, height: 180)
        XCTAssertEqual(PanelGeometry.keptOnScreen(half, in: screen), half)
        let gone = PanelGeometry.keptOnScreen(CGRect(x: 2000, y: -500, width: 320, height: 180), in: screen)
        XCTAssertEqual(gone.minX, 1440 - PanelGeometry.minVisible)
        XCTAssertEqual(gone.maxY, PanelGeometry.minVisible)
    }

    func testCornerResizeKeepsOppositeCorner() {
        let start = CGRect(x: 100, y: 100, width: 320, height: 180)
        let f = PanelGeometry.resized(start, handle: [.top, .right], delta: CGVector(dx: 160, dy: 10), aspect: 16 / 9, maxSize: screen.size)
        XCTAssertEqual(f.origin, start.origin)
        XCTAssertEqual(f.width, 480)
        XCTAssertEqual(f.width / f.height, 16 / 9, accuracy: 0.001)
        let g = PanelGeometry.resized(start, handle: [.bottom, .left], delta: CGVector(dx: 100, dy: 0), aspect: 16 / 9, maxSize: screen.size)
        XCTAssertEqual(g.maxX, start.maxX)
        XCTAssertEqual(g.maxY, start.maxY)
        XCTAssertEqual(g.width, 220)
    }

    func testCornerAndSizePresets() {
        let f = CGRect(x: 1000, y: 600, width: 320, height: 180)
        XCTAssertEqual(PanelGeometry.cornered(f, .bottomLeft, in: screen).origin, CGPoint(x: 16, y: 16))
        // Parked top-right: grows towards the bottom-left, top-right corner fixed.
        let big = PanelGeometry.sized(f, width: 640, aspect: 16 / 9, in: screen)
        XCTAssertEqual(big.maxX, f.maxX)
        XCTAssertEqual(big.maxY, f.maxY)
        XCTAssertEqual(big.width, 640)
        XCTAssertEqual(PanelGeometry.sized(f, width: 10, aspect: 16 / 9, in: screen).width, PanelGeometry.minWidth)
    }

    func testHandleZones() {
        let size = CGSize(width: 400, height: 300)
        func h(_ x: CGFloat, _ y: CGFloat) -> ResizeHandle? { PanelGeometry.handle(at: CGPoint(x: x, y: y), in: size, edge: 6, corner: 16) }
        XCTAssertNil(h(200, 150))              // inside: normal arrow
        XCTAssertNil(h(30, 30))                // near a corner but not in it
        XCTAssertEqual(h(3, 150), .left)
        XCTAssertEqual(h(397, 150), .right)
        XCTAssertEqual(h(200, 2), .top)
        XCTAssertEqual(h(200, 298), .bottom)
        XCTAssertEqual(h(5, 5), [.top, .left])
        XCTAssertEqual(h(395, 295), [.bottom, .right])
        XCTAssertNil(h(-1, 150))               // outside
    }

    func testFreeResize() {
        let start = CGRect(x: 100, y: 100, width: 800, height: 500)
        let min = CGSize(width: 300, height: 200), max = CGSize(width: 1600, height: 1000)
        // Bottom-left corner: right and top edges stay put, shape changes freely.
        let f = PanelGeometry.resizedFree(start, handle: [.bottom, .left], delta: CGVector(dx: -100, dy: -50), minSize: min, maxSize: max)
        XCTAssertEqual(f, CGRect(x: 0, y: 50, width: 900, height: 550))
        let tiny = PanelGeometry.resizedFree(start, handle: [.top, .right], delta: CGVector(dx: -5000, dy: -5000), minSize: min, maxSize: max)
        XCTAssertEqual(tiny.size, min)
        XCTAssertEqual(tiny.origin, start.origin)
        let huge = PanelGeometry.resizedFree(start, handle: .right, delta: CGVector(dx: 5000, dy: 0), minSize: min, maxSize: max)
        XCTAssertEqual(huge.width, 1600)
    }

    func testResizeLimits() {
        let start = CGRect(x: 100, y: 100, width: 320, height: 180)
        let tiny = PanelGeometry.resized(start, handle: .right, delta: CGVector(dx: -1000, dy: 0), aspect: 16 / 9, maxSize: screen.size)
        XCTAssertEqual(tiny.width, PanelGeometry.minWidth)
        let huge = PanelGeometry.resized(start, handle: .top, delta: CGVector(dx: 0, dy: 5000), aspect: 16 / 9, maxSize: screen.size)
        XCTAssertEqual(huge.width, 1440) // the whole screen width
    }

    func testStashedLeavesPeekVisible() {
        let right = PanelGeometry.stashed(CGRect(x: 1000, y: 100, width: 320, height: 180), edge: .right, in: screen)
        XCTAssertEqual(right.minX, 1440 - PanelGeometry.peek)
        let left = PanelGeometry.stashed(CGRect(x: 100, y: 100, width: 320, height: 180), edge: .left, in: screen)
        XCTAssertEqual(left.maxX, PanelGeometry.peek)
    }

    func testScaledKeepsAspectAndLimits() {
        let f = PanelGeometry.scaled(CGRect(x: 100, y: 100, width: 320, height: 180), by: 0.1, aspect: 16 / 9, maxSize: screen.size)
        XCTAssertEqual(f.width, PanelGeometry.minWidth)
        XCTAssertEqual(f.width / f.height, 16 / 9, accuracy: 0.001)
        let big = PanelGeometry.scaled(CGRect(x: 100, y: 100, width: 320, height: 180), by: 100, aspect: 16 / 9, maxSize: screen.size)
        XCTAssertEqual(big.width, 1440, accuracy: 0.001) // up to the full screen
    }

    func testClampShrinksOversizedFrames() {
        let f = PanelGeometry.clamped(CGRect(x: -50, y: -50, width: 2000, height: 1125), in: screen)
        XCTAssertTrue(screen.contains(f))
        XCTAssertEqual(f.width / f.height, 2000 / 1125, accuracy: 0.001)
    }
}
