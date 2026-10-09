import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: LaunchOptions(CommandLine.arguments))
    app.delegate = delegate
    // Accessory = menu-bar only, no Dock icon.
    app.setActivationPolicy(.accessory)
    app.run()
}
