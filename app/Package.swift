// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiPAnywhere",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (protocol parsing, window geometry), unit-tested.
        .target(name: "PiPCore"),
        // Objective-C wrapper over the private CGVirtualDisplay API (Live Apps stage).
        .target(name: "CVirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        // The menu-bar app. scripts/bundle.sh wraps the binary into PiP Anywhere.app.
        .executableTarget(name: "PiPAnywhere", dependencies: ["PiPCore", "CVirtualDisplay"]),
        .testTarget(name: "PiPAnywhereTests", dependencies: ["PiPCore"]),
    ],
    swiftLanguageModes: [.v5]
)
