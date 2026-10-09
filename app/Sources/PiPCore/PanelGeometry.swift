import CoreGraphics

public enum StashEdge: String, Sendable, Codable {
    case left, right
}

public enum ScreenCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Which edges a resize handle moves; corners combine two.
public struct ResizeHandle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let left = ResizeHandle(rawValue: 1)
    public static let right = ResizeHandle(rawValue: 2)
    public static let top = ResizeHandle(rawValue: 4)
    public static let bottom = ResizeHandle(rawValue: 8)

    public static let all: [ResizeHandle] = [
        .left, .right, .top, .bottom, [.top, .left], [.top, .right], [.bottom, .left], [.bottom, .right],
    ]
}

/// Window placement math, in AppKit screen coordinates (origin bottom-left).
public enum PanelGeometry {
    /// Gap between a snapped window and the screen edge.
    public static let margin: CGFloat = 16
    /// How much of a stashed window stays visible.
    public static let peek: CGFloat = 24
    /// Fraction of the width that must be past an edge on release to stash. High so
    /// the window can also be parked half off-screen without stashing.
    public static let stashThreshold: CGFloat = 0.7
    /// Smallest window: the hover controls still fit and it can't shrink out of sight.
    public static let minWidth: CGFloat = 200
    /// A window placed freely keeps at least this much on screen, so it can be grabbed.
    public static let minVisible: CGFloat = 48

    /// Moves the frame to the nearest of the four corners of `visible`.
    public static func snapped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let left = frame.midX < visible.midX
        let bottom = frame.midY < visible.midY
        return CGRect(
            x: left ? visible.minX + margin : visible.maxX - margin - frame.width,
            y: bottom ? visible.minY + margin : visible.maxY - margin - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// Puts the frame in a specific corner of `visible`.
    public static func cornered(_ frame: CGRect, _ corner: ScreenCorner, in visible: CGRect) -> CGRect {
        let left = corner == .topLeft || corner == .bottomLeft
        let bottom = corner == .bottomLeft || corner == .bottomRight
        return CGRect(
            x: left ? visible.minX + margin : visible.maxX - margin - frame.width,
            y: bottom ? visible.minY + margin : visible.maxY - margin - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// Changes the width (keeping `aspect`) while the corner of the window nearest to a
    /// screen corner stays put, so a window parked bottom-right grows up and left.
    public static func sized(_ frame: CGRect, width: CGFloat, aspect: CGFloat, in screen: CGRect) -> CGRect {
        let range = widthRange(aspect: aspect, maxSize: screen.size)
        let w = min(max(width, range.lowerBound), range.upperBound)
        let h = w / aspect
        let x = frame.midX > screen.midX ? frame.maxX - w : frame.minX
        let y = frame.midY > screen.midY ? frame.maxY - h : frame.minY
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The edge the window was flicked past on release, if any.
    public static func stashEdge(for frame: CGRect, in visible: CGRect) -> StashEdge? {
        let limit = frame.width * stashThreshold
        if visible.minX - frame.minX > limit { return .left }
        if frame.maxX - visible.maxX > limit { return .right }
        return nil
    }

    /// The closer side for the "stash" button.
    public static func nearestEdge(of frame: CGRect, in visible: CGRect) -> StashEdge {
        frame.midX < visible.midX ? .left : .right
    }

    /// Slides the window off `edge`, leaving `peek` points on screen.
    public static func stashed(_ frame: CGRect, edge: StashEdge, in visible: CGRect) -> CGRect {
        var f = clamped(frame, in: visible)
        f.origin.x = edge == .left ? visible.minX - f.width + peek : visible.maxX - peek
        return f
    }

    /// Keeps the frame fully inside `visible` (shrinking it if it's too big).
    public static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var f = frame
        if f.width > visible.width || f.height > visible.height {
            let scale = min(visible.width / f.width, visible.height / f.height)
            f.size = CGSize(width: f.width * scale, height: f.height * scale)
        }
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    /// Free placement: anywhere, even partly off-screen, as long as `minVisible`
    /// points of it stay on `screen` in both directions.
    public static func keptOnScreen(_ frame: CGRect, in screen: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(max(f.minX, screen.minX - f.width + minVisible), screen.maxX - minVisible)
        f.origin.y = min(max(f.minY, screen.minY - f.height + minVisible), screen.maxY - minVisible)
        return f
    }

    /// Width limits for a given aspect: `minWidth` up to the whole screen.
    private static func widthRange(aspect: CGFloat, maxSize: CGSize) -> ClosedRange<CGFloat> {
        let upper = max(minWidth, min(maxSize.width, maxSize.height * aspect))
        return minWidth...upper
    }

    /// Scales around the centre, keeping `aspect` (width / height). Can grow up to `maxSize`.
    public static func scaled(_ frame: CGRect, by scale: CGFloat, aspect: CGFloat, maxSize: CGSize) -> CGRect {
        let range = widthRange(aspect: aspect, maxSize: maxSize)
        let width = min(max(frame.width * scale, range.lowerBound), range.upperBound)
        let size = CGSize(width: width, height: width / aspect)
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Resizes from an edge or corner by a mouse delta (screen points, y up), keeping
    /// `aspect`. The opposite edge/corner stays put; a side edge grows symmetrically.
    public static func resized(_ start: CGRect, handle: ResizeHandle, delta: CGVector, aspect: CGFloat, maxSize: CGSize) -> CGRect {
        let horizontal = handle.contains(.left) || handle.contains(.right)
        let vertical = handle.contains(.top) || handle.contains(.bottom)
        let dw = handle.contains(.right) ? delta.dx : handle.contains(.left) ? -delta.dx : 0
        let dh = handle.contains(.top) ? delta.dy : handle.contains(.bottom) ? -delta.dy : 0
        // Express both as a width change; a corner follows whichever moved more.
        let byWidth = dw
        let byHeight = dh * aspect
        let change = horizontal && vertical ? (abs(byWidth) >= abs(byHeight) ? byWidth : byHeight)
            : horizontal ? byWidth : byHeight
        let range = widthRange(aspect: aspect, maxSize: maxSize)
        let width = min(max(start.width + change, range.lowerBound), range.upperBound)
        let height = width / aspect
        let x = handle.contains(.left) ? start.maxX - width
            : handle.contains(.right) ? start.minX : start.midX - width / 2
        let y = handle.contains(.bottom) ? start.maxY - height
            : handle.contains(.top) ? start.minY : start.midY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Re-shapes the frame to a new aspect ratio, keeping width and top-left corner.
    public static func fitted(_ frame: CGRect, aspect: CGFloat) -> CGRect {
        let height = frame.width / aspect
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// Default placement: bottom-right corner, 1/4 of the screen width.
    public static func initial(in visible: CGRect, aspect: CGFloat = 16.0 / 9.0) -> CGRect {
        let width = max(minWidth, (visible.width / 4).rounded())
        let frame = CGRect(x: 0, y: 0, width: width, height: (width / aspect).rounded())
        return snapped(frame.offsetBy(dx: visible.maxX, dy: visible.minY), in: visible)
    }
}
