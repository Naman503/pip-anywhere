// Renders the app icon at 1024×1024 (macOS icon grid: an 824 pt tile with a soft
// shadow): a dimmed "desktop" window with a vivid picture-in-picture window floating
// above it. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let canvas = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let white = { (a: CGFloat) in CGColor(gray: 1, alpha: a) }
let black = { (a: CGFloat) in CGColor(gray: 0, alpha: a) }

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let g = context.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func fillGradient(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    g.saveGState()
    g.addPath(path)
    g.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    g.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    g.restoreGState()
}

// ── Tile ─────────────────────────────────────────────────────────────
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 186)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: black(0.35))
g.addPath(tilePath)
g.setFillColor(rgb(0x1A2146))
g.fillPath()
g.restoreGState()
fillGradient(tilePath, [rgb(0x4152A0), rgb(0x232B5E), rgb(0x10142E)], from: CGPoint(x: 300, y: 924), to: CGPoint(x: 724, y: 100))
// Soft light from the top-left.
g.saveGState()
g.addPath(tilePath)
g.clip()
let glow = CGGradient(colorsSpace: space, colors: [white(0.22), white(0)] as CFArray, locations: nil)!
g.drawRadialGradient(glow, startCenter: CGPoint(x: 280, y: 900), startRadius: 0, endCenter: CGPoint(x: 280, y: 900), endRadius: 620, options: [])
g.restoreGState()
// Thin inner rim.
g.addPath(rounded(tile.insetBy(dx: 2, dy: 2), 184))
g.setStrokeColor(white(0.10))
g.setLineWidth(4)
g.strokePath()

// ── The desktop app window behind ────────────────────────────────────
let back = CGRect(x: 190, y: 352, width: 580, height: 410)
let backPath = rounded(back, 46)
g.addPath(backPath)
g.setFillColor(white(0.09))
g.fillPath()
g.addPath(backPath)
g.setStrokeColor(white(0.22))
g.setLineWidth(6)
g.strokePath()
// Title bar: separator and traffic lights.
g.setFillColor(white(0.12))
g.fill(CGRect(x: back.minX + 3, y: back.maxY - 78, width: back.width - 6, height: 3))
for (i, color) in [rgb(0xFF5F57, 0.9), rgb(0xFEBC2E, 0.9), rgb(0x28C840, 0.9)].enumerated() {
    g.setFillColor(color)
    g.fillEllipse(in: CGRect(x: back.minX + 40 + CGFloat(i) * 42, y: back.maxY - 53, width: 26, height: 26))
}
// Content lines.
for (i, width) in [330.0, 410, 260].enumerated() {
    g.addPath(rounded(CGRect(x: back.minX + 46, y: back.maxY - 140 - CGFloat(i) * 56, width: width, height: 24), 12))
    g.setFillColor(white(0.17))
    g.fillPath()
}

// ── The floating picture-in-picture window ───────────────────────────
let pip = CGRect(x: 420, y: 196, width: 430, height: 282)
let pipPath = rounded(pip, 50)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -26), blur: 56, color: black(0.6))
g.addPath(pipPath)
g.setFillColor(rgb(0xF0566E))
g.fillPath()
g.restoreGState()
fillGradient(pipPath, [rgb(0xFF8A5B), rgb(0xF5566C), rgb(0xD63C8E)], from: CGPoint(x: pip.minX, y: pip.maxY), to: CGPoint(x: pip.maxX, y: pip.minY))
// Glass highlight across the top.
g.saveGState()
g.addPath(pipPath)
g.clip()
let sheen = CGGradient(colorsSpace: space, colors: [white(0.38), white(0.0)] as CFArray, locations: nil)!
g.drawLinearGradient(sheen, start: CGPoint(x: 0, y: pip.maxY), end: CGPoint(x: 0, y: pip.midY + 20), options: [])
g.restoreGState()
g.addPath(rounded(pip.insetBy(dx: 2, dy: 2), 48))
g.setStrokeColor(white(0.4))
g.setLineWidth(4)
g.strokePath()

// Play symbol with rounded corners.
let center = CGPoint(x: pip.midX + 6, y: pip.midY + 14)
let triangle = CGMutablePath()
triangle.move(to: CGPoint(x: center.x - 34, y: center.y + 50))
triangle.addLine(to: CGPoint(x: center.x - 34, y: center.y - 50))
triangle.addLine(to: CGPoint(x: center.x + 52, y: center.y))
triangle.closeSubpath()
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: black(0.25))
// One transparency layer, so the shadow is cast by the finished shape, not onto itself.
g.beginTransparencyLayer(auxiliaryInfo: nil)
g.addPath(triangle)
g.setFillColor(white(1))
g.setStrokeColor(white(1))
g.setLineWidth(22)
g.setLineJoin(.round)
g.drawPath(using: .fillStroke)
g.endTransparencyLayer()
g.restoreGState()

// Progress bar.
let track = CGRect(x: pip.minX + 44, y: pip.minY + 36, width: pip.width - 88, height: 12)
g.addPath(rounded(track, 6))
g.setFillColor(white(0.35))
g.fillPath()
g.addPath(rounded(CGRect(x: track.minX, y: track.minY, width: track.width * 0.42, height: track.height), 6))
g.setFillColor(white(0.95))
g.fillPath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
