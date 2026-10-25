import Foundation
import XCTest
@testable import PiPCore

final class UsageCatalogTests: XCTestCase {
    func testNamesAndProps() {
        XCTAssertTrue(UsageCatalog.isValidName("window_closed"))
        XCTAssertFalse(UsageCatalog.isValidName("Window"))
        XCTAssertFalse(UsageCatalog.isValidName("a" + String(repeating: "b", count: 48)))
        let props = UsageCatalog.cleanProps([
            "mode": "video", "ok": true, "n": 3, "x": Double.nan, "Bad": "y",
            "long": String(repeating: "z", count: 100), "a1": 1, "a2": 2, "a3": 3, "a4": 4, "a5": 5,
        ])
        XCTAssertEqual(props.count, 8)
        XCTAssertNil(props["x"])
        XCTAssertNil(props["Bad"])
        XCTAssertEqual((props["long"] as? String)?.count, 64)
    }

    func testBuckets() {
        XCTAssertEqual(UsageCatalog.durationBucket(seconds: 5), "lt10s")
        XCTAssertEqual(UsageCatalog.durationBucket(seconds: 600), "5_15m")
        XCTAssertEqual(UsageCatalog.durationBucket(seconds: 10_000), "2h_plus")
        XCTAssertEqual(UsageCatalog.latencyBucket(ms: 100), "lt250ms")
        XCTAssertEqual(UsageCatalog.latencyBucket(ms: 1500), "1_2s")
        XCTAssertEqual(UsageCatalog.resolutionBucket(height: 720), "720p")
        XCTAssertEqual(UsageCatalog.resolutionBucket(height: 2160), "4k")
        XCTAssertEqual(UsageCatalog.resolutionBucket(height: 0), "unknown")
        XCTAssertEqual(UsageCatalog.fpsBucket(60), "55_plus")
        XCTAssertEqual(UsageCatalog.fpsBucket(30), "25_34")
        XCTAssertEqual(UsageCatalog.countBucket(0), "0")
        XCTAssertEqual(UsageCatalog.countBucket(4), "3_5")
        XCTAssertEqual(UsageCatalog.countBucket(40), "11_plus")
        XCTAssertEqual(UsageCatalog.opacityBucket(0.85), "85")
        XCTAssertEqual(UsageCatalog.opacityBucket(0.6), "other")
        XCTAssertEqual(UsageCatalog.rateBucket(1), "1")
        XCTAssertEqual(UsageCatalog.rateBucket(2.85), "2.85")
        XCTAssertEqual(UsageCatalog.rateBucket(1.1), "other")
    }

    func testFingerprintIsStable() {
        // FNV-1a of "a" is 0xe40c292c: the same on every run, unlike hashValue.
        XCTAssertEqual(UsageCatalog.fingerprint("a"), "e40c292c")
        XCTAssertNotEqual(UsageCatalog.fingerprint("a"), UsageCatalog.fingerprint("b"))
    }

    func testSymbolOnlyDropsAddresses() {
        let a = "3   PiPAnywhere                         0x0000000100a1b2c3 $s11PiPAnywhere3fooyyF + 44"
        let b = "3   PiPAnywhere                         0x0000000102ffffff $s11PiPAnywhere3fooyyF + 44"
        XCTAssertEqual(UsageCatalog.symbolOnly(a), "PiPAnywhere $s11PiPAnywhere3fooyyF")
        XCTAssertEqual(UsageCatalog.symbolOnly(a), UsageCatalog.symbolOnly(b))
    }

    func testSignalNames() {
        XCTAssertEqual(UsageCatalog.signalName(SIGSEGV), "SIGSEGV")
        XCTAssertEqual(UsageCatalog.signalName(SIGTRAP), "SIGTRAP")
    }

    func testStopReasons() {
        XCTAssertEqual(UsageCatalog.stopReason("tab closed"), "tab_closed")
        XCTAssertEqual(UsageCatalog.stopReason("closed in the app"), "closed_in_app")
        XCTAssertEqual(UsageCatalog.stopReason("something with a title in it"), "other")
    }

    func testExtensionItemsAreAllowListed() {
        let items = UsageCatalog.sanitizeExtensionItems([
            ["n": "ext_toggle", "p": ["via": "shortcut"], "c": 3, "d": "2026-10-20"],
            ["n": "ext_toggle", "p": ["via": "https://example.com"], "c": 1],   // value not allowed
            ["n": "ext_toggle", "p": ["url": "shortcut"], "c": 1],               // key not allowed
            ["n": "page_title", "p": [:], "c": 1],                                // name not allowed
            ["n": "ext_script_injected", "c": 999_999, "d": "2099-01-01"],        // clamped, future day dropped
            ["n": "ext_page_reloaded", "c": 0, "d": "yesterday"],
        ], today: "2026-10-26")
        XCTAssertEqual(items, [
            .init(name: "ext_toggle", props: ["via": "shortcut"], count: 3, day: "2026-10-20"),
            .init(name: "ext_script_injected", props: [:], count: 10_000, day: nil),
            .init(name: "ext_page_reloaded", props: [:], count: 1, day: nil),
        ])
    }

    func testDecodesUsageAndHello() {
        let usage = #"{"type":"usage","items":[{"n":"ext_start","p":{"result":"no_video"},"c":2,"d":"2026-01-02"},{"n":"evil","c":1}]}"#
        XCTAssertEqual(Inbound.decode(Data(usage.utf8)),
                       .usage([.init(name: "ext_start", props: ["result": "no_video"], count: 2, day: "2026-01-02")]))
        XCTAssertEqual(Inbound.decode(Data(#"{"type":"hello","version":"1","ext":"0.5.0"}"#.utf8)), .hello(version: "1", ext: "0.5.0"))
        XCTAssertEqual(Inbound.decode(Data(#"{"type":"hello","version":"1","ext":"<script>"}"#.utf8)), .hello(version: "1", ext: nil))
        XCTAssertEqual(Inbound.decode(Data(#"{"type":"hello","version":"1"}"#.utf8)), .hello(version: "1"))
    }
}
