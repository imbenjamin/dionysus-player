import Foundation
import SwiftUI

/// Everything `PlayerViewModel` needs from a playback engine.
///
/// This sits between the app and AetherEngine so feature code depends on a
/// small, stable surface instead of a third-party library directly — useful
/// both for isolating an unverified API (see `AetherPlaybackEngine`) and for
/// swapping in a fake implementation in SwiftUI previews.
@MainActor
protocol PlaybackEngine: AnyObject {
    var onStateChange: ((PlaybackState) -> Void)? { get set }
    /// Called at the engine's own cadence with `(currentTime, duration)`, in seconds.
    var onTimeUpdate: ((TimeInterval, TimeInterval) -> Void)? { get set }
    /// Called whenever the decoded subtitle cue list changes — see
    /// `SubtitleCueDisplay`'s doc comment. Not filtered to "active now":
    /// the list covers a window ahead of the playhead, so `SubtitleOverlayView`
    /// filters against `onSourceTimeUpdate` itself.
    var onSubtitleCuesChange: (([SubtitleCueDisplay]) -> Void)? { get set }
    /// Called at the engine's own clock cadence with the source-PTS playhead
    /// — the axis subtitle cue `startTime`/`endTime` are stamped in, which
    /// can diverge from `onTimeUpdate`'s item/AVPlayer-axis time across
    /// producer restarts. Kept as its own callback (rather than folded into
    /// `onTimeUpdate`) so subtitle-only observers don't need to unpack a
    /// tuple they'd ignore half of.
    var onSourceTimeUpdate: ((TimeInterval) -> Void)? { get set }

    var audioTracks: [PlaybackTrack] { get }
    var subtitleTracks: [PlaybackTrack] { get }
    /// A short description of the detected video format (e.g. "Dolby Vision
    /// P8.1", "HDR10"), for display only. `nil` for SDR or before load.
    var videoFormatDescription: String? { get }

    /// Coded pixel dimensions of the source video, `nil` before they're
    /// known (still loading, or an audio-only source) — `SubtitleOverlayView`
    /// needs this to work out the actual on-screen picture rect (as opposed
    /// to the surface's own, possibly letterboxed, container) for placing
    /// image cues and `\pos`-anchored text cues. Read on demand rather than
    /// pushed, same treatment as `stats` — it settles once per load and
    /// nothing needs it before the first subtitle cue can possibly arrive.
    var videoNaturalSize: CGSize? { get }

    /// How the video surface returned by `makeSurface()` fills its space.
    /// Settable at any time, including before `load(url:)` — AetherEngine's
    /// own `videoGravity` (what `AetherPlaybackEngine` bridges this to)
    /// applies to whichever render layer is bound, independent of whether a
    /// source is currently loaded.
    var zoomMode: VideoZoomMode { get set }

    /// A fresh diagnostics snapshot, read straight from live engine state —
    /// see `PlaybackStats`. Not cached: callers (`PlaybackStatsOverlay`)
    /// poll this on their own timer rather than this being pushed, so every
    /// read should reflect the engine's current state, not whatever it was
    /// when playback started.
    var stats: PlaybackStats { get }

    /// `externalSubtitles` are sidecar files (Jellyfin's `isExternal ==
    /// true` `MediaStream`s) to register alongside the load, so they show up
    /// in `subtitleTracks` next to the embedded ones — see
    /// `ExternalSubtitleSource`'s doc comment. Pass `[]` when there are
    /// none; the default-argument overload below covers that for callers
    /// that never deal with external subtitles at all (previews, most
    /// tests).
    func load(url: URL, externalSubtitles: [ExternalSubtitleSource]) async throws
    func play()
    func pause()
    func togglePlayPause()
    func seek(to time: TimeInterval) async
    func stop()

    func selectAudioTrack(id: Int)
    /// `nil` disables subtitles.
    func selectSubtitleTrack(id: Int?)

    /// Type-erased SwiftUI surface that renders this engine's video output.
    func makeSurface() -> AnyView
}

extension PlaybackEngine {
    /// Convenience for callers with no external subtitles to register —
    /// protocol requirements can't carry default argument values, so this
    /// covers what would otherwise be every pre-existing `load(url:)` call
    /// site.
    func load(url: URL) async throws {
        try await load(url: url, externalSubtitles: [])
    }
}
