// Prints the PiP window's bounds (top-left origin) and the main screen size.
import AppKit

let bundleID = "local.pipanywhere.PiPAnywhere"
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for info in all {
    let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
    guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID else { continue }
    let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    guard (b["Height"] ?? 0) > 100 else { continue }
    print("window x=\(b["X"]!) y=\(b["Y"]!) w=\(b["Width"]!) h=\(b["Height"]!) alpha=\(info[kCGWindowAlpha as String] ?? 1)")
}
let s = NSScreen.main!.frame
print("screen w=\(s.width) h=\(s.height)")
