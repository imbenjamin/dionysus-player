import CoreGraphics

/// Turns one touch-surface pan into what it means to the player.
///
/// Horizontal while paused: a free scrub, once the swipe has moved 40pt and
/// is going at least 200pt/s, so a resting thumb's drift does nothing.
/// Horizontal elsewhere: one step per swipe after 150pt at 400pt/s, which
/// enters or steps a scan, or moves focus. Vertical: one Up or Down. Sodalite's measured thresholds
/// (`PlayerHostController.handlePan`); indirect touches over-report
/// translation, so these are larger than they look.
struct TVSwipeGate {
    static let axisCommitDistance: CGFloat = 40
    static let scrubCommitVelocity: CGFloat = 200
    static let stepDistance: CGFloat = 150
    static let stepVelocity: CGFloat = 400

    private enum Phase { case undecided, horizontal, vertical, scrubbing, done }
    private var phase: Phase = .undecided
    private var scrubOriginX: CGFloat = 0

    mutating func began() {
        phase = .undecided
    }

    mutating func changed(translation t: CGPoint, velocity v: CGPoint, width: CGFloat, scrubs: Bool) -> [TVRemoteInput] {
        if phase == .undecided {
            guard max(abs(t.x), abs(t.y)) >= Self.axisCommitDistance else { return [] }
            phase = abs(t.x) > abs(t.y) ? .horizontal : .vertical
        }
        switch phase {
        case .horizontal where scrubs:
            guard abs(v.x) >= Self.scrubCommitVelocity else { return [] }
            phase = .scrubbing
            scrubOriginX = t.x
            return [.swipeBegan]
        case .horizontal:
            guard abs(t.x) >= Self.stepDistance, abs(v.x) >= Self.stepVelocity else { return [] }
            phase = .done
            return [.swipeStep(t.x < 0 ? .left : .right)]
        case .vertical:
            guard abs(t.y) >= Self.stepDistance, abs(v.y) >= Self.stepVelocity else { return [] }
            phase = .done
            return [t.y < 0 ? .up : .down]
        case .scrubbing:
            return [.swipeMoved(fraction: Double((t.x - scrubOriginX) / max(width, 1)))]
        case .undecided, .done:
            return []
        }
    }

    mutating func ended() -> [TVRemoteInput] {
        defer { phase = .undecided }
        return phase == .scrubbing ? [.swipeEnded] : []
    }
}
