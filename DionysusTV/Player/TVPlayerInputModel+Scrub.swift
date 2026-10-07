import Foundation

extension TVPlayerInputModel {
    /// Scrubbing and scanning (Benjamin, 2026-10-06), as the native player
    /// does it. Playing, a hold or a swipe pauses and scans at level 1 in its
    /// direction; each further press or swipe steps the level, -3 to 3, the
    /// opposite way slowing through a stop. Paused, a swipe scrubs freely and
    /// a press steps 10s. Either way the picture stays paused and only the
    /// trickplay preview moves. `nil` when the intent isn't a scrub's.
    static func reduceScrub(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand]? {
        if let scrub = state.scrub {
            return continueScrub(scrub, intent, &state, context: context, now: now)
        }
        guard scrubCanOpen(state, context: context) else {
            switch intent {
            case .swipeBegan, .swipeMoved, .swipeEnded, .holdBegan, .swipeStep: return []
            default: return nil
            }
        }
        let playing = context.playback == .playing
        switch intent {
        case .holdBegan(let direction), .swipeStep(let direction):
            state.chrome = .transport
            state.scrub = .init(
                previewTime: context.currentTime, resumesOnCancel: playing,
                scan: .init(level: direction.step, lastTickAt: now)
            )
            if case .holdBegan = intent { state.heldArrow?.actedAsScan = true }
            return playing ? [.pause] : []
        case .swipeBegan where context.playback == .paused:
            state.chrome = .transport
            state.scrub = .init(previewTime: context.currentTime, resumesOnCancel: false, swipeAnchor: context.currentTime)
            return []
        case .arrow(let direction) where context.playback == .paused && !nextUpHasFocus(state, context: context):
            state.chrome = .transport
            state.scrub = .init(
                previewTime: clamp(context.currentTime + direction.sign * TVPlayerTiming.skipInterval, context),
                resumesOnCancel: false
            )
            return []
        case .swipeBegan, .swipeMoved, .swipeEnded:
            return []
        default:
            return nil
        }
    }

    /// Where a scrub may open: a title with a duration, focus on the
    /// scrubber (always so with the transport hidden), and no panel over it.
    static func scrubCanOpen(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        context.duration > 0 && state.transportFocus == .scrubber && state.panel == nil
    }

    /// Whether a horizontal swipe scrubs freely (`TVSwipeGate`): paused, or
    /// in a free scrub already. Everywhere else a swipe is one step.
    static func swipeScrubs(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        if let scrub = state.scrub { return scrub.scan == nil }
        return scrubCanOpen(state, context: context) && context.playback == .paused
    }

    static func continueScrub(
        _ scrub: TVPlayerInputState.Scrub, _ intent: Intent, _ state: inout TVPlayerInputState,
        context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        var scrub = scrub
        switch intent {
        case .select, .playPause:
            state.scrub = nil
            flash(.play, &state)
            return [.seek(scrub.previewTime), .play]
        case .menu:
            state.scrub = nil
            return scrub.resumesOnCancel ? [.play] : []
        case .arrow(let direction), .swipeStep(let direction):
            if var scan = scrub.scan {
                scan.level = min(max(scan.level + direction.step, -3), 3)
                scrub.scan = scan
            } else {
                scrub.swipeAnchor = nil
                scrub.previewTime = clamp(scrub.previewTime + direction.sign * TVPlayerTiming.skipInterval, context)
            }
        case .holdBegan(let direction):
            scrub.swipeAnchor = nil
            if var scan = scrub.scan {
                scan.level = min(max(scan.level + direction.step, -3), 3)
                scrub.scan = scan
            } else {
                scrub.scan = .init(level: direction.step, lastTickAt: now)
            }
            state.heldArrow?.actedAsScan = true
        case .swipeBegan:
            if scrub.scan == nil { scrub.swipeAnchor = scrub.previewTime }
        case .swipeMoved(let fraction):
            if scrub.scan == nil, let anchor = scrub.swipeAnchor {
                let travel = fraction * context.duration * TVScrubMetrics.fullSwipeFractionOfDuration
                scrub.previewTime = snapped(clamp(anchor + travel, context), context: context)
            }
        case .swipeEnded:
            scrub.swipeAnchor = nil
        case .up, .down:
            break
        }
        state.scrub = scrub
        return []
    }

    /// Signed real-time multiple for a scan level: 8x, 32x, 64x each way.
    static func scanRate(level: Int) -> Double {
        guard level != 0 else { return 0 }
        let index = min(abs(level), TVPlayerTiming.scanRates.count) - 1
        return TVPlayerTiming.scanRates[index] * (level < 0 ? -1 : 1)
    }

    /// Chapters in Scrubber's snap, as iOS's scrubber has it.
    static func snapped(_ time: TimeInterval, context: TVPlayerContext) -> TimeInterval {
        guard context.chaptersInScrubber, context.duration > 0 else { return time }
        let radius = context.duration * TVScrubMetrics.snapFractionOfDuration
        guard let nearest = context.chapterStarts.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) <= radius else { return time }
        return nearest
    }
}
