import Foundation

/// Playback state as the rest of the app sees it — deliberately smaller
/// than AetherEngine's own state so feature code isn't coupled to it.
enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    /// Frames have stopped advancing for a reason that isn't a user-driven
    /// seek — a mid-playback buffer underrun on an otherwise-healthy
    /// connection, or the source connection itself dropping and retrying.
    /// Bridged from AetherEngine's `PlaybackPhase.rebuffering` and
    /// `.stalled(reconnecting:)` — see `AetherPlaybackEngine.observeEngine()`
    /// — both of which AetherEngine can report while its own underlying
    /// `state` is still `.playing`, so watching `state` alone (as this app
    /// briefly did) missed them entirely: a scrub-seek landing into a spot
    /// that then needs to rebuffer looked like it had silently paused, with
    /// no spinner, rather than reading as still loading. Collapsed into one
    /// case here since the UI treats both the same way (a spinner); nothing
    /// downstream currently needs to distinguish "buffering" from "network
    /// retrying".
    case buffering
    case ended
    case failed(String)
}

/// How the video surface fills its available space — the landscape
/// "pinch/double-tap to zoom" affordance in `PlayerView` toggles this.
enum VideoZoomMode: Equatable {
    /// The whole frame is visible, letterboxed/pillarboxed if its aspect
    /// ratio doesn't match the screen's. The default, and the only mode
    /// used in portrait — see `PlayerView.isLandscape`'s doc comment.
    case fit
    /// The frame fills the screen with no letterboxing, cropping whatever
    /// doesn't fit — the standard streaming-app "zoomed in" look.
    case fill

    var toggled: VideoZoomMode { self == .fit ? .fill : .fit }
}

/// A snapshot of engine/session diagnostics for the "stats for nerds"
/// overlay (`PlaybackStatsOverlay`) — polled on a timer while that overlay is
/// visible rather than pushed, since none of this is needed at normal UI
/// cadence. Every field is already display-ready (formatted, or nil when the
/// underlying value genuinely isn't known yet) so the overlay stays a thin
/// text layout with no formatting logic of its own.
struct PlaybackStats: Equatable {
    /// Source pixel dimensions, e.g. "1920×804". `nil` before the video
    /// track is known (still loading, or an audio-only source).
    var videoSize: String?
    var frameRate: String?
    var bitrate: String?
    /// The source file's own dynamic-range format (e.g. "Dolby Vision
    /// (Profile 5)") — what's actually in the file, independent of whether
    /// this device's panel can present it.
    var sourceColorFormat: String
    /// What's actually being handed to the display after any panel
    /// clamping (e.g. a Dolby Vision source tone-mapped down to HDR10 on a
    /// panel that can't accept DV) — differs from `sourceColorFormat`
    /// exactly when that clamping happens.
    var displayColorFormat: String
    var videoDecoder: String?
    var audioDecoder: String?
    /// The active audio track's channel layout (e.g. "2.0", "5.1", "7.1",
    /// or "Atmos" for a JOC-profile EAC3 track) — not the output device's
    /// own channel count, which the overlay shows separately alongside the
    /// audio route. `nil` before a track is known.
    var audioChannels: String?
    /// "Native", "Software", "Audio", or "None" — AetherEngine's internal
    /// rendering backend, surfaced read-only for diagnostics like this.
    var backend: String
    /// Seconds of video already fetched/decoded ahead of the playhead —
    /// the safety margin before playback would need to pause and
    /// rebuffer. `nil` when the backend isn't `.native`: AetherEngine's
    /// `bufferedPosition` is only a genuine read-ahead measure on the
    /// native AVPlayer path, backed by its segment cache. On the software
    /// decode path it's defined as "newest demuxed PTS since session
    /// start," which tracks the playhead itself rather than any real
    /// look-ahead — reporting that as a buffered amount would just read as
    /// a permanently-stuck "0.0s" (indistinguishable from a genuine stall)
    /// rather than the "not available on this backend" it actually is.
    var bufferedSeconds: Double?
    /// Resident size, in bytes, of the same segment cache `bufferedSeconds`
    /// measures — `nil` in exactly the same case (backend isn't `.native`),
    /// for the same reason.
    var bufferedBytes: Int64?
    var currentTime: TimeInterval
    var duration: TimeInterval
}

/// A selectable audio or subtitle track, normalized from whatever track
/// type the playback engine exposes.
struct PlaybackTrack: Identifiable, Hashable {
    enum Kind: Hashable {
        case audio
        case subtitle
    }

    var id: Int
    var kind: Kind
    var displayTitle: String
    var isSelected: Bool
}
