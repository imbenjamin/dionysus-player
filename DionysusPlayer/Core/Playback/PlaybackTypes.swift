import CoreGraphics
import Foundation
import SwiftUI

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
    /// The picker row's main line — a provided, genuinely descriptive track
    /// name (e.g. "Director's Commentary") when there is one, otherwise a
    /// user-friendly language name derived from the track's language code
    /// (e.g. "English" rather than "ENG" or "ENG (srt)"). See
    /// `AetherPlaybackEngine.title(for:)` for how the two are told apart.
    var title: String
    /// The picker row's secondary, metadata line — whichever of "Default"/
    /// "Forced"/"Hearing Impaired"/"Commentary"/"External" apply to this
    /// track, already joined and display-ready. `nil` when none apply
    /// (nothing to show under the title).
    var metadata: String?
    var isSelected: Bool

    /// A copy with only `isSelected` changed — `AetherPlaybackEngine`
    /// re-maps its whole track list on every selection/active-index change
    /// just to flip this one field, without disturbing `title`/`metadata`.
    func selected(_ isSelected: Bool) -> PlaybackTrack {
        var copy = self
        copy.isSelected = isSelected
        return copy
    }
}

/// A sidecar subtitle file to register alongside a load — normalized from
/// Jellyfin's `MediaStream` (the `isExternal == true` entries in a
/// `MediaSourceInfo.mediaStreams` list) so `PlaybackEngine` conformers never
/// depend on AetherEngine's own `ExternalSubtitleTrack` directly, matching
/// `PlaybackTrack`/`SubtitleCueDisplay`'s existing role. `AetherPlaybackEngine
/// .load(url:externalSubtitles:)` maps these onto `LoadOptions
/// .externalSubtitles`; AetherEngine then folds each into `$subtitleTracks`
/// with a synthetic id and `isExternal == true`, which the existing track-
/// label normalization already turns into an "External" metadata flag.
struct ExternalSubtitleSource: Equatable {
    var url: URL
    /// The embedded-style track name, if Jellyfin reports one — same
    /// "genuinely descriptive title vs. bare language echo" heuristic in
    /// `AetherPlaybackEngine.descriptiveName(_:)` applies once this reaches
    /// `TrackInfo.name`, so passing `nil` here is fine and just falls
    /// through to a friendly language name.
    var name: String?
    /// BCP-47 / ISO 639 code, same convention as `PlaybackTrack`'s embedded
    /// tracks.
    var language: String?
    var isForced: Bool = false
    var isHearingImpaired: Bool = false
    var isDefault: Bool = false
    /// File-extension override for a `url` whose path doesn't reveal the
    /// subtitle format — Jellyfin's `MediaStream.codec` values ("subrip",
    /// "ass", "webvtt", ...) already match what AetherEngine expects here.
    var formatHint: String?
}

/// A decoded subtitle cue ready for the app's own overlay to paint —
/// normalized from AetherEngine's `SubtitleCue`/`SubtitleTextRun`/
/// `SubtitleTextPlacement`/`SubtitleImage` so `SubtitleOverlayView` never
/// depends on AetherEngine's types directly, matching `PlaybackTrack`'s
/// existing role for the track lists. AetherEngine emits cues; it draws
/// nothing itself — see `AetherPlaybackEngine.observeEngine()` for where
/// this gets populated from `engine.$subtitleCues`.
///
/// `startTime`/`endTime` are in source PTS seconds — filter against
/// `PlayerViewModel.sourceTime`, not `currentTime` (the item/AVPlayer
/// clock), since the two can diverge across producer restarts. The cue
/// list itself covers a window ahead of the playhead rather than just
/// "now," so a cue with no active window simply isn't rendered yet.
struct SubtitleCueDisplay: Identifiable, Equatable {
    var id: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var body: Body
    /// Where the source asked this cue to be drawn (ASS `\an`/`\pos`);
    /// `nil` for the overwhelming majority of cues, which want the
    /// overlay's own default (bottom-center). Text/rich-text cues only —
    /// an image cue carries its own geometry on `Body.image`.
    var placement: Placement?

    enum Body: Equatable {
        case text(String)
        case richText([Run])
        /// `rect`/`canvasSize` are normalized `[0, 1]` against the source
        /// video frame, same contract as `SubtitleImage.position`/
        /// `.canvasSize` — map them onto the on-screen video rect to place
        /// the image where the disc/broadcast authored it. `canvasSize ==
        /// .zero` means "treat canvas == video," per that property's own
        /// doc comment.
        case image(CGImage, rect: CGRect, canvasSize: CGSize)

        static func == (lhs: Body, rhs: Body) -> Bool {
            switch (lhs, rhs) {
            case (.text(let l), .text(let r)): return l == r
            case (.richText(let l), .richText(let r)): return l == r
            case (.image(let li, let lr, let lc), .image(let ri, let rr, let rc)):
                return li === ri && lr == rr && lc == rc
            default: return false
            }
        }
    }

    /// One contiguous same-styling span of a rich-text cue — SRT/WebVTT
    /// inline tags, ASS override tags, and teletext colour all arrive
    /// normalized to this same shape. A run with no attribute set stays
    /// plain `.text` upstream rather than becoming a one-run `.richText`.
    struct Run: Equatable {
        var text: String
        var color: Color?
        var isBold: Bool = false
        var isItalic: Bool = false
        var isUnderlined: Bool = false
        var isStruckThrough: Bool = false
    }

    /// ASS numpad alignment (`\an`: 1 bottom-left through 9 top-right, 5
    /// centred) plus an optional `[0, 1]`-normalized anchor from `\pos`
    /// (y from the top). Either may be present alone.
    struct Placement: Equatable {
        var alignment: Int?
        var position: CGPoint?
    }

    /// Plain text for text and rich-text cues (rich runs concatenated);
    /// `nil` for image cues. Mirrors `SubtitleCue.text`.
    var text: String? {
        switch body {
        case .text(let string): return string
        case .richText(let runs): return runs.map(\.text).joined()
        case .image: return nil
        }
    }
}
