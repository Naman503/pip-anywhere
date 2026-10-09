// Spike S2: is the PiP panel visible over another app's native full-screen Space?
//
// Run the app first:  "app/build/PiP Anywhere.app/Contents/MacOS/PiPAnywhere" --test-pattern
// Then:               swift spikes/FullscreenProbe.swift
//
// The probe puts its own window into native full screen (a new Space), switches the
// app's window level through `defaults` + a distributed notification, and asks the
// window server which PiPAnywhere windows are on screen. Window owner names and
// on-screen flags don't need Screen Recording permission.
import AppKit

let bundleID = "local.pipanywhere.PiPAnywhere"
/// Set PIP_PID to measure one specific copy of the app (others may be running).
let onlyPID = ProcessInfo.processInfo.environment["PIP_PID"].flatMap { pid_t($0) }

func isPiP(_ pid: pid_t) -> Bool {
    if let onlyPID { return pid == onlyPID }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID
}
let levels = ["floating", "statusBar", "screenSaver"]

func pipWindowsOnScreen() -> [[String: Any]] {
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return all.filter { info in
        // Owner name is the bundle display name ("PiP Anywhere"); match the process instead.
        let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
        guard isPiP(pid) else { return false }
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return (bounds["Height"] ?? 0) > 100 // skip the menu-bar item
    }
}

/// True if the PiP window is in front of this probe's (full-screen) window.
/// The window server lists on-screen windows front to back.
func pipInFrontOfProbe() -> Bool {
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let me = ProcessInfo.processInfo.processIdentifier
    var sawPiP = false
    for info in all {
        let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        guard (bounds["Height"] ?? 0) > 100 else { continue }
        if isPiP(pid) { sawPiP = true }
        if pid == me { return sawPiP }
    }
    return false
}

func setLevel(_ level: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["write", bundleID, "level", level]
    try? task.run()
    task.waitUntilExit()
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("local.pipanywhere.reload"), object: nil, userInfo: nil, deliverImmediately: true)
}

final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var results: [String: Bool] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("before full screen: \(pipWindowsOnScreen().count) PiP window(s) on screen")
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Fullscreen probe"
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .systemIndigo
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.check(0) }
        }
    }

    func check(_ index: Int) {
        guard index < levels.count else { return finish() }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        setLevel(levels[index])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let visible = !pipWindowsOnScreen().isEmpty
            self.results[levels[index]] = visible
            let front = pipInFrontOfProbe()
            print("probe full screen: \(isFullScreen) · level \(levels[index]): PiP \(visible ? "VISIBLE" : "not visible"), \(front ? "in front of" : "BEHIND") the full-screen window")
            self.check(index + 1)
        }
    }

    func finish() {
        setLevel("statusBar")
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let probe = Probe()
app.delegate = probe
app.setActivationPolicy(.regular)
app.run()
