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

    var audioTracks: [PlaybackTrack] { get }
    var subtitleTracks: [PlaybackTrack] { get }
    /// A short description of the detected video format (e.g. "Dolby Vision
    /// P8.1", "HDR10"), for display only. `nil` for SDR or before load.
    var videoFormatDescription: String? { get }

    /// How the video surface returned by `makeSurface()` fills its space.
    /// Settable at any time, including before `load(url:)` — AetherEngine's
    /// own `videoGravity` (what `AetherPlaybackEngine` bridges this to)
    /// applies to whichever render layer is bound, independent of whether a
    /// source is currently loaded.
    var zoomMode: VideoZoomMode { get set }

    func load(url: URL) async throws
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
