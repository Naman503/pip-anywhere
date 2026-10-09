// Lists online displays: id, name, bounds (global points, top-left origin), main flag.
import AppKit

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)
for id in ids.prefix(Int(count)) {
    let b = CGDisplayBounds(id)
    let name = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }?.localizedName ?? "?"
    print("display \(id) '\(name)' \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height))\(CGDisplayIsMain(id) != 0 ? " MAIN" : "")")
}
