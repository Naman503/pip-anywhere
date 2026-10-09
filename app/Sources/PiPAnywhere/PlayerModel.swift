import Foundation
import PiPCore

/// UI state for the floating window. Mutated on the main thread only.
@MainActor
final class PlayerModel: ObservableObject {
    @Published var playback: PlaybackState?
    /// When `playback` arrived, to extrapolate the current time between updates.
    @Published private(set) var playbackReceivedAt = Date()
    @Published var connected = false
    @Published var stats = StreamStats()
    @Published var isStashed = false
    @Published var stashEdge: StashEdge = .right
    @Published var ghost = false
    @Published var hovering = false
    /// True while showing the built-in test pattern instead of a browser stream.
    @Published var testPattern = false
    /// Short feedback shown in the middle of the video ("Volume 40%", "+10 s").
    @Published private(set) var hud: String?
    private var hudTask: Task<Void, Never>?
    private var scrollX: CGFloat = 0

    /// Sends a command to the browser tab.
    var sendCommand: (CommandAction, Double?) -> Void = { _, _ in }

    func update(_ state: PlaybackState) {
        playback = state
        playbackReceivedAt = Date()
    }

    func currentTime(at date: Date = Date()) -> Double {
        guard let p = playback else { return 0 }
        let elapsed = p.paused ? 0 : date.timeIntervalSince(playbackReceivedAt) * p.rate
        return min(p.currentTime + elapsed, p.duration > 0 ? p.duration : .infinity)
    }

    func command(_ action: CommandAction, _ value: Double? = nil) {
        // Optimistic local update so the UI responds before the tab confirms.
        if var p = playback {
            let now = currentTime()
            switch action {
            case .toggle: p.paused.toggle(); p.currentTime = now
            case .play: p.paused = false; p.currentTime = now
            case .pause: p.paused = true; p.currentTime = now
            case .seek: p.currentTime = max(0, now + (value ?? 0))
            case .seekTo: p.currentTime = value ?? now
            case .rate: p.currentTime = now; p.rate = value ?? p.rate
            case .volume: p.volume = value; if (value ?? 0) > 0 { p.muted = false }
            case .mute: p.muted = (value ?? 1) != 0
            default: break
            }
            update(p)
        }
        sendCommand(action, value)
    }

    func showHUD(_ text: String) {
        hud = text
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .seconds(0.9))
            if !Task.isCancelled { hud = nil }
        }
    }

    var volume: Double { playback?.volume ?? 1 }
    var muted: Bool { playback?.muted ?? false }

    func setVolume(_ value: Double) {
        let v = min(1, max(0, (value * 100).rounded() / 100))
        command(.volume, v)
        showHUD(v == 0 ? "Muted" : "Volume \(Int(v * 100))%")
    }

    func toggleMute() {
        command(.mute, muted ? 0 : 1)
        showHUD(muted ? "Muted" : "Volume \(Int(volume * 100))%")
    }

    func seek(by seconds: Double) {
        command(.seek, seconds)
        showHUD(seconds < 0 ? "−\(Int(-seconds)) s" : "+\(Int(seconds)) s")
    }

    /// Two-finger scroll over the window: sideways seeks 5 s per step, up/down changes volume.
    func scroll(dx: CGFloat, dy: CGFloat, precise: Bool) {
        guard playback != nil else { return }
        if abs(dx) > abs(dy) {
            scrollX += precise ? dx : dx * 20
            if abs(scrollX) >= 40 {
                // Fingers moving left (negative dx) = forward, like dragging a timeline.
                seek(by: scrollX < 0 ? 5 : -5)
                scrollX = 0
            }
        } else if dy != 0 {
            setVolume(volume + Double(precise ? dy * 0.004 : dy * 0.05))
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let s = Int(seconds)
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
