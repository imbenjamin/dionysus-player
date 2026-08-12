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
