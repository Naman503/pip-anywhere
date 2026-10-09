import AppKit
import PiPCore
import SwiftUI

struct PanelActions {
    var dragChanged: () -> Void
    var dragEnded: () -> Void
    var magnifyChanged: (CGFloat) -> Void
    var magnifyEnded: () -> Void
    var resizeChanged: (ResizeHandle) -> Void
    var resizeEnded: () -> Void
    var toggleStash: () -> Void
    var toggleZoom: () -> Void
    var close: () -> Void
}

/// Video + hover controls + stash handle.
struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    let videoLayer: CALayer
    let actions: PanelActions

    @State private var scrubTime: Double?

    private var showControls: Bool {
        (model.hovering || scrubTime != nil) && !model.isStashed && !model.ghost
    }

    var body: some View {
        ZStack {
            Color.black
            // Slid into the edge: the visible strip must not reveal the video.
            VideoSurface(videoLayer: videoLayer, blurred: model.isStashed)
            if model.isStashed { Color.black.opacity(0.35) }
            if !model.connected && !model.testPattern {
                Text("Waiting for the browser…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if !showControls && !model.isStashed, Settings.showProgressLine, let playback = model.playback,
               playback.duration > 0, playback.duration.isFinite {
                ProgressLine(model: model, duration: playback.duration)
            }
            if let hud = model.hud, !model.isStashed {
                Text(hud)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .transition(.opacity)
            }
            controls
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
                .animation(.easeOut(duration: 0.15), value: showControls)
            if !model.isStashed && !model.ghost {
                ResizeHandles(onChange: actions.resizeChanged, onEnd: actions.resizeEnded)
            }
            if model.isStashed {
                StashHandle(edge: model.stashEdge, playing: !(model.playback?.paused ?? true) || model.testPattern)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: model.isStashed ? 8 : 12, style: .continuous))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: model.hud)
        .onHover { model.hovering = $0 }
        .onTapGesture(count: 2) { if !model.isStashed { actions.toggleZoom() } }
        .onTapGesture { if model.isStashed { actions.toggleStash() } }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in actions.dragChanged() }
                .onEnded { _ in actions.dragEnded() }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { actions.magnifyChanged($0.magnification) }
                .onEnded { _ in actions.magnifyEnded() }
        )
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(model.playback?.title ?? (model.testPattern ? "Test pattern" : ""))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(radius: 2)
                Spacer(minLength: 4)
                IconButton(symbol: model.stashEdge == .left ? "arrow.left.to.line" : "arrow.right.to.line",
                           help: "Slide to the edge (⌃⌥P)", action: actions.toggleStash)
                IconButton(symbol: "xmark", help: "Close", action: actions.close)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))

            Spacer(minLength: 0)

            if let playback = model.playback {
                HStack(spacing: 20) {
                    IconButton(symbol: "gobackward.10", size: 18, help: "Back 10 s (⌃⌥←)") { model.seek(by: -10) }
                    IconButton(symbol: playback.paused ? "play.fill" : "pause.fill", size: 28, help: "Play/pause (⌃⌥Space)") {
                        model.command(.toggle)
                    }
                    IconButton(symbol: "goforward.10", size: 18, help: "Forward 10 s (⌃⌥→)") { model.seek(by: 10) }
                }
                Spacer(minLength: 0)
                bottomBar(playback)
            }
        }
    }

    private func bottomBar(_ playback: PlaybackState) -> some View {
        VStack(spacing: 2) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let time = scrubTime ?? model.currentTime(at: context.date)
                VStack(spacing: 2) {
                    if playback.duration > 0 && playback.duration.isFinite {
                        Scrubber(progress: time / playback.duration) { fraction in
                            scrubTime = fraction * playback.duration
                        } onEnd: {
                            if let t = scrubTime { model.command(.seekTo, t) }
                            scrubTime = nil
                        }
                    }
                    HStack(spacing: 6) {
                        Text(playback.duration.isFinite && playback.duration > 0
                             ? "\(formatTime(time)) / \(formatTime(playback.duration))" : "LIVE")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 0)
                        if playback.volume != nil {
                            IconButton(symbol: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                       size: 11, help: "Mute (scroll up/down over the video for volume)") { model.toggleMute() }
                        }
                        SpeedMenu(rate: playback.rate) { model.command(.rate, $0) }
                        IconButton(symbol: "arrow.up.forward.app", size: 12, help: "Back to the tab (⌃⌥B)") { model.command(.focusTab) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }
}

/// Hosts the AVSampleBufferDisplayLayer. Passes mouse events through to SwiftUI.
private struct VideoSurface: NSViewRepresentable {
    let videoLayer: CALayer
    var blurred = false

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.layer?.addSublayer(videoLayer)
        view.hosted = videoLayer
        return view
    }

    func updateNSView(_ nsView: LayerView, context: Context) {
        nsView.blurred = blurred
    }

    final class LayerView: NSView {
        var hosted: CALayer?
        /// A Core Image blur on the layer that contains the video layer.
        var blurred = false {
            didSet {
                guard blurred != oldValue else { return }
                let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 60])
                layer?.filters = blurred ? blur.map { [$0] } : nil
            }
        }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .frame(width: size + 14, height: size + 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct Scrubber: View {
    let progress: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                Capsule().fill(.white).frame(width: width * min(max(progress, 0), 1), height: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChange(min(max($0.location.x / width, 0), 1)) }
                    .onEnded { _ in onEnd() }
            )
        }
        .frame(height: 12)
    }
}

private struct SpeedMenu: View {
    let rate: Double
    let onSelect: (Double) -> Void
    private let rates: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 2.85, 3]

    var body: some View {
        Menu {
            ForEach(rates, id: \.self) { r in
                Button { onSelect(r) } label: {
                    Text(label(r)) + Text(r == rate ? "  ✓" : "")
                }
            }
        } label: {
            Text(label(rate))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }

    private func label(_ r: Double) -> String {
        (r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)) + "×"
    }
}

/// Invisible grab zones along the edges and corners for resizing (aspect kept).
private struct ResizeHandles: View {
    let onChange: (ResizeHandle) -> Void
    let onEnd: () -> Void

    private let edge: CGFloat = 8
    private let corner: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ForEach(ResizeHandle.all, id: \.rawValue) { handle in
                let isCorner = (handle.contains(.left) || handle.contains(.right)) && (handle.contains(.top) || handle.contains(.bottom))
                let size = CGSize(
                    width: isCorner || handle.contains(.left) || handle.contains(.right) ? (isCorner ? corner : edge) : max(0, w - 2 * corner),
                    height: isCorner || handle.contains(.top) || handle.contains(.bottom) ? (isCorner ? corner : edge) : max(0, h - 2 * corner)
                )
                let x = handle.contains(.left) ? size.width / 2 : handle.contains(.right) ? w - size.width / 2 : w / 2
                let y = handle.contains(.top) ? size.height / 2 : handle.contains(.bottom) ? h - size.height / 2 : h / 2
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: size.width, height: size.height)
                    .position(x: x, y: y)
                    // Set (not push/pop) on every move: AppKit resets the cursor as the
                    // mouse moves over the rest of the window.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: cursor(for: handle).set()
                        case .ended: NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { _ in
                                cursor(for: handle).set()
                                onChange(handle)
                            }
                            .onEnded { _ in onEnd() }
                    )
            }
        }
    }

    private func cursor(for handle: ResizeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch handle {
            case [.top, .left]: .topLeft
            case [.top, .right]: .topRight
            case [.bottom, .left]: .bottomLeft
            case [.bottom, .right]: .bottomRight
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            default: .right
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if handle == .left || handle == .right { return .resizeLeftRight }
        if handle == .top || handle == .bottom { return .resizeUpDown }
        return .crosshair
    }
}

/// Thin progress bar along the bottom while the hover controls are hidden.
private struct ProgressLine: View {
    @ObservedObject var model: PlayerModel
    let duration: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            GeometryReader { geo in
                let fraction = min(max(model.currentTime(at: context.date) / duration, 0), 1)
                VStack {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * fraction, height: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The strip left visible when the window is slid into a screen edge.
private struct StashHandle: View {
    let edge: StashEdge
    let playing: Bool

    var body: some View {
        HStack(spacing: 0) {
            if edge == .left { Spacer(minLength: 0) }
            VStack(spacing: 10) {
                Image(systemName: edge == .right ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 16, weight: .bold))
                Circle()
                    .fill(playing ? Color.red : Color.gray)
                    .frame(width: 6, height: 6)
            }
            .foregroundStyle(.white)
            .frame(width: PanelGeometry.peek)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.55))
            .help("Click to bring the video back (⌃⌥P)")
            if edge == .right { Spacer(minLength: 0) }
        }
    }
}
