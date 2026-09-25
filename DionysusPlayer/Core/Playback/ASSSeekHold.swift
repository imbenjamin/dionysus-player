import Foundation

/// Holds libass back after a seek on a server transcode, until the engine's
/// `sourceTime` is on the picture again.
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
/// starts. Between a time jump and that line, `sourceTime` still carries the
/// previous seek's lead — late when the new lead is smaller, early when it is
/// larger (off by up to 1.8s on device). Since 7.16.0 the engine says so:
/// `sourceTimeFollowsPicture` is false from every time jump until a line has
/// re-measured. While it is, `renderTime(for:)` returns `nil` and the overlay
/// paints nothing — a wrong-time line is worse than a missing one for the
/// second or two it lasts.
///
/// It gives up waiting after `holdTimeout` of *playback* and renders on
/// whatever `sourceTime` says, because the flag only turns true on a line the
/// rendition carries, and libass can have things to draw that it doesn't. That
/// time is summed from item-time steps small enough to be playback, so a pause
/// never releases the hold and a seek never counts towards it.
///
/// A plain value type with no clock of its own: tests drive it directly.
struct ASSSeekHold {
    /// How much playback, with the engine still unsure, before rendering
    /// anyway.
    static let holdTimeout: TimeInterval = 5
    /// An item-time step larger than this is a seek, not playback.
    static let maxPlaybackStep: TimeInterval = 1

    private var followsPicture: Bool
    private var heldPlayback: TimeInterval = 0
    private var lastItemTime: TimeInterval?

    /// - Parameter followsPicture: the engine's `sourceTimeFollowsPicture` at
    ///   the moment libass takes over.
    init(followsPicture: Bool) {
        self.followsPicture = followsPicture
    }

    /// Where libass should render for the engine's `sourceTime`, or `nil` while
    /// it can't be trusted and nothing should be painted.
    func renderTime(for sourceTime: TimeInterval) -> TimeInterval? {
        followsPicture || heldPlayback >= Self.holdTimeout ? sourceTime : nil
    }

    /// Feed every value the engine publishes for `sourceTimeFollowsPicture`,
    /// including a repeated `false`: that is another time jump, and restarts
    /// the wait.
    mutating func observeFollowsPicture(_ follows: Bool) {
        followsPicture = follows
        if !follows { heldPlayback = 0 }
    }

    /// Feed every item-time tick (the engine's `currentTime`), which is what
    /// the timeout counts playback on.
    mutating func observeItemTime(_ time: TimeInterval) {
        defer { lastItemTime = time }
        guard !followsPicture, let last = lastItemTime else { return }
        let step = time - last
        if step > 0, step <= Self.maxPlaybackStep { heldPlayback += step }
    }
}
