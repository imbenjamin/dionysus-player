import Foundation

/// Holds libass back after a seek on a server transcode, until the engine's
/// `sourceTime` can be trusted to be on the picture again.
///
/// **Why the playhead is wrong there at all.** A transcode plays Jellyfin's HLS
/// through AVPlayer. After a seek Jellyfin restarts its transcode at the source
/// keyframe at or before the requested segment, so that segment's media
/// timestamps begin *earlier* than its slot in the playlist. AVPlayer anchors
/// its item timeline to the first segment it loads after the seek, so item time
/// runs ahead of the picture by that segment's slot minus its keyframe —
/// measured anywhere from 0.8s to 8.3s across the scrubs of one film.
///
/// **What corrects it.** Since AetherEngine 7.15.2 (our AetherEngine#616) the
/// engine does: it matches each line AVPlayer presents from the WebVTT
/// rendition it injected for the track back to the cue it wrote, and publishes
/// `sourceTime` as item time minus that measured lead. The rendition has to be
/// selected and presenting for that, which is why `AetherPlaybackEngine` keeps
/// it selected with its drawing suppressed rather than deselecting it.
///
/// **What it leaves to the host.** The engine re-measures only when a line
/// starts. Between a seek landing and that line, `sourceTime` still carries the
/// previous seek's lead, so libass would draw on it — late when the new lead is
/// smaller, early when it is larger (off by up to 1.8s on device). So after a
/// seek `renderTime(for:)` returns `nil` until a line starts, and the overlay
/// paints nothing — a wrong-time line is worse than a missing one for the
/// second or two it lasts. It gives up waiting after `holdTimeout` of playback,
/// and renders on whatever `sourceTime` says.
///
/// **Seeks are detected on item time**, the engine's `currentTime`, never on
/// `sourceTime`: the latter jumps by the size of the correction whenever the
/// engine re-measures, which would read as another seek the moment the hold
/// lifted. Item time is also the axis AVPlayer stamps presented lines with.
///
/// A plain value type with no clock of its own: every input is an engine time,
/// so tests drive it directly.
struct ASSSeekHold {
    /// A line delivered this soon after a seek was already on screen when the
    /// playhead landed. Its delivery time is the landing time, not its start,
    /// so the engine measures nothing from it and neither does this.
    static let carryoverWindow: TimeInterval = 0.5
    /// How long after a seek to keep waiting for a line before rendering
    /// anyway.
    static let holdTimeout: TimeInterval = 5
    /// A playhead moving backwards by more than this, or forwards by more than
    /// `forwardJumpThreshold` between two observations, is a seek or a reload
    /// rather than playback.
    static let backwardJumpThreshold: TimeInterval = 0.5
    static let forwardJumpThreshold: TimeInterval = 2

    private enum Phase: Equatable {
        /// Nothing observed yet, so no way to tell a line already on screen
        /// from one just starting.
        case awaitingPlayhead
        /// The playhead jumped to `since`, and no line has started since.
        /// `skipsNextDelivery` mirrors the engine, which ignores the first
        /// delivery after AVPlayer reports a time jump.
        case holding(since: TimeInterval, skipsNextDelivery: Bool)
        /// Rendering: a line started, or the hold timed out.
        case released
    }

    private var phase: Phase = .awaitingPlayhead
    private var lastItemTime: TimeInterval?
    private var previousTexts: Set<String> = []
    /// Lines presented before this item time may have been on screen already,
    /// re-delivered rather than starting. See `carryoverWindow`.
    private var measurableFrom: TimeInterval = 0

    /// Where libass should render for the engine's `sourceTime`, or `nil` while
    /// it can't be trusted and nothing should be painted.
    func renderTime(for sourceTime: TimeInterval) -> TimeInterval? {
        phase == .released ? sourceTime : nil
    }

    /// Feed every item-time tick (the engine's `currentTime`). Detects seeks
    /// and reloads, and ends the hold after `holdTimeout`.
    mutating func observeItemTime(_ time: TimeInterval) {
        defer { lastItemTime = time }
        if let last = lastItemTime,
           time < last - Self.backwardJumpThreshold || time > last + Self.forwardJumpThreshold {
            phase = .holding(since: time, skipsNextDelivery: true)
            previousTexts = []
            measurableFrom = time + Self.carryoverWindow
            return
        }
        switch phase {
        case .awaitingPlayhead:
            phase = .holding(since: time, skipsNextDelivery: false)
            measurableFrom = time + Self.carryoverWindow
        case .holding(let since, _) where time >= since + Self.holdTimeout:
            phase = .released
        default:
            break
        }
    }

    /// AVPlayer is about to re-deliver whatever is on screen as though it had
    /// just started, because its output was (re)attached. Keeps rendering.
    mutating func ignoreLinesAlreadyShowing() {
        previousTexts = []
        measurableFrom = (lastItemTime ?? 0) + Self.carryoverWindow
    }

    /// Feed every set of lines AVPlayer presents, with the item time it
    /// presents them at. An empty `texts` is a line ending.
    mutating func observeCues(_ texts: [String], at itemTime: TimeInterval) {
        // Delivered on the same axis as the ticks, and possibly ahead of the
        // tick that would reveal a seek. Checking here first stops a line
        // carried over the seek from being read as one that just started.
        observeItemTime(itemTime)
        let current = Set(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        defer { previousTexts = current }
        guard case .holding(let since, let skipsNextDelivery) = phase else { return }
        if skipsNextDelivery {
            phase = .holding(since: since, skipsNextDelivery: false)
            return
        }
        // AVPlayer re-delivers every line still showing whenever a new one
        // starts, and those carry the new line's time, not their own.
        guard !current.subtracting(previousTexts).isEmpty, itemTime >= measurableFrom else { return }
        phase = .released
    }
}
