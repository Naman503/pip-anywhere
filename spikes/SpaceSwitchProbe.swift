// Does the PiP window stay on screen *during* a Space transition?
//
// Run the app first:  "app/build/PiP Anywhere.app/Contents/MacOS/PiPAnywhere" --test-pattern
// Then:               swift spikes/SpaceSwitchProbe.swift
//
// The probe's own window enters native full screen (an animated Space switch, like a
// four-finger swipe) and then leaves it. Throughout both transitions it samples every
// 10 ms whether the PiP window is on screen and where, and reports any gaps.
import AppKit

let bundleID = "local.pipanywhere.PiPAnywhere"
/// Set PIP_PID to measure one specific copy of the app (others may be running).
let onlyPID = ProcessInfo.processInfo.environment["PIP_PID"].flatMap { pid_t($0) }

func isPiP(_ pid: pid_t) -> Bool {
    if let onlyPID { return pid == onlyPID }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID
}

struct Sample {
    let t: Double
    let visible: Bool
    let x: CGFloat
}

func pipWindow() -> CGRect? {
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in all {
        let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
        guard isPiP(pid) else { continue }
        let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        guard (b["Height"] ?? 0) > 100 else { continue }
        return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    }
    return nil
}

final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var samples: [Sample] = []
    var start = Date()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 500),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .systemIndigo
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.transition(entering: true) }
    }

    func transition(entering: Bool) {
        samples = []
        start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [unowned self] _ in
            let frame = pipWindow()
            samples.append(Sample(t: Date().timeIntervalSince(start), visible: frame != nil, x: frame?.minX ?? -1))
        }
        RunLoop.main.add(timer!, forMode: .common)
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.timer?.invalidate()
            self.report(entering ? "enter full screen" : "exit full screen")
            if entering {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.transition(entering: false) }
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    func report(_ name: String) {
        let hidden = samples.filter { !$0.visible }
        let xs = Set(samples.filter(\.visible).map(\.x))
        var gap = "none"
        if let first = hidden.first, let last = hidden.last {
            gap = String(format: "%.0f–%.0f ms (%d of %d samples)", first.t * 1000, last.t * 1000, hidden.count, samples.count)
        }
        print("\(name): hidden \(gap); distinct x positions while visible: \(xs.count)")
    }
}

let app = NSApplication.shared
let probe = Probe()
app.delegate = probe
app.setActivationPolicy(.regular)
app.run()
