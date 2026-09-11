import Foundation
import SwiftUI
import UIKit

/// Everything `PlayerViewModel` needs from a playback engine.
///
/// Sits between the app and AetherEngine so feature code depends on a small,
/// stable surface rather than a third-party library, and so a fake can be
/// swapped in for SwiftUI previews.
@MainActor
protocol PlaybackEngine: AnyObject {
    var onStateChange: ((PlaybackState) -> Void)? { get set }
    /// Called at the engine's own cadence with `(currentTime, duration)`, in seconds.
    var onTimeUpdate: ((TimeInterval, TimeInterval) -> Void)? { get set }
    /// Called whenever the decoded subtitle cue list changes. Not filtered to
    /// the current moment — the list covers a window ahead of the playhead, and
    /// `SubtitleOverlayView` filters it against `onSourceTimeUpdate`.
    var onSubtitleCuesChange: (([SubtitleCueDisplay]) -> Void)? { get set }
    /// The source-PTS playhead, at the engine's clock cadence. Subtitle cue
    /// times are stamped on this axis, which diverges from `onTimeUpdate`'s
    /// AVPlayer axis across producer restarts. Its own callback so subtitle
    /// observers don't unpack a tuple they half ignore.
    var onSourceTimeUpdate: ((TimeInterval) -> Void)? { get set }
    /// Mirrors `AVPictureInPictureController.isPictureInPicturePossible`,
    /// driving the PiP button's enabled state. Permanently `false` on
    /// AetherEngine's software route, which has no native player layer for
    /// `AVPictureInPictureController(playerLayer:)` — enough to make the button
    /// self-disable with no separate route check.
    var onPictureInPicturePossibleChange: ((Bool) -> Void)? { get set }
    /// Whether a PiP window is showing this session's video. `PlayerView` swaps
    /// the video surface for a placeholder while it is `true`.
    var onPictureInPictureActiveChange: ((Bool) -> Void)? { get set }

    var audioTracks: [PlaybackTrack] { get }
    var subtitleTracks: [PlaybackTrack] { get }
    /// The detected video format ("Dolby Vision P8.1", "HDR10"), for display.
    /// `nil` for SDR and before load.
    var videoFormatDescription: String? { get }

    /// Coded pixel dimensions of the source video; `nil` while loading and for
    /// audio-only sources. `SubtitleOverlayView` needs it to derive the
    /// on-screen picture rect, as opposed to the surface's possibly letterboxed
    /// container, when placing image and `\pos`-anchored cues. Pulled rather
    /// than pushed: it settles once per load, before the first cue can arrive.
    var videoNaturalSize: CGSize? { get }

    /// How `makeSurface()`'s surface fills its space. Settable at any time,
    /// including before `load(url:)`: the underlying `videoGravity` applies to
    /// whichever render layer is bound, loaded or not.
    var zoomMode: VideoZoomMode { get set }

    /// A diagnostics snapshot read from live engine state. Not cached —
    /// `PlaybackStatsOverlay` polls it on its own timer, so every read must
    /// reflect the engine now rather than at playback start.
    var stats: PlaybackStats { get }

    /// `externalSubtitles` are sidecar files to register alongside the load, so
    /// they appear in `subtitleTracks` beside the embedded ones.
    ///
    /// `knownAtmosAudioTrackIndices` are track indices Jellyfin's
    /// `MediaStream.audioSpatialFormat` already identified as carrying Atmos.
    /// AetherEngine's `TrackInfo.isAtmos` fires only for the EAC3 JOC profile
    /// marker and has no equivalent for TrueHD's MAT 2.0 extension, so a
    /// TrueHD/Atmos track is flagged only via this server-reported hint.
    ///
    /// `isRemoteHLS` is `true` only for a server-chosen HLS transcode, which
    /// maps to `LoadOptions.nativeRemoteHLS` and hands the playlist to AVPlayer
    /// instead of AetherEngine's FFmpeg demuxer. `false` for every other load,
    /// including offline.
    ///
    /// The overloads below default the arguments callers may have nothing to
    /// pass for.
    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>, isRemoteHLS: Bool) async throws
    func play()
    func pause()
    func togglePlayPause()
    func seek(to time: TimeInterval) async
    func stop()

    func selectAudioTrack(id: Int)
    /// `nil` disables subtitles.
    func selectSubtitleTrack(id: Int?)

    /// A no-op when PiP isn't possible, so callers need no guard of their own.
    func startPictureInPicture()
    func stopPictureInPicture()

    /// Populates the system Now Playing info for this session.
    ///
    /// `artwork` is used as-is: this layer loads no images, so a caller wanting
    /// artwork fetches it (see `RemoteImageLoader`) and passes the result.
    /// Elapsed time and duration are not parameters — the system session merges
    /// those from the player. Safe before or after `load()`, and harmless on a
    /// route with no Now-Playing session.
    func setNowPlayingInfo(title: String, subtitle: String?, artwork: UIImage?)

    /// Type-erased SwiftUI surface that renders this engine's video output.
    func makeSurface() -> AnyView
}

extension PlaybackEngine {
    /// Protocol requirements can't carry default arguments, so these overloads
    /// stand in for them.
    func load(url: URL) async throws {
        try await load(url: url, externalSubtitles: [], knownAtmosAudioTrackIndices: [], isRemoteHLS: false)
    }

    /// External subtitles, no Atmos hints.
    func load(url: URL, externalSubtitles: [ExternalSubtitleSource]) async throws {
        try await load(url: url, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: [], isRemoteHLS: false)
    }

    /// No server-transcode hint: offline playback, and tests not exercising the
    /// transcode path.
    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>) async throws {
        try await load(url: url, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: knownAtmosAudioTrackIndices, isRemoteHLS: false)
    }
}
