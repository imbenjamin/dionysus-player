import CoreGraphics
import Foundation
import SwiftUI

/// Playback state as the app sees it, smaller than AetherEngine's own so
/// feature code isn't coupled to it.
enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    /// Frames stopped advancing on a buffer underrun over a healthy
    /// connection. Bridged from `PlaybackPhase.rebuffering`, which AetherEngine
    /// reports while its own `state` is still `.playing` — so watching `state`
    /// alone misses it, and a seek landing somewhere that needs to rebuffer
    /// looks silently paused with no spinner.
    case buffering
    /// Frames stopped advancing because the source connection dropped and
    /// AetherEngine is retrying. Distinct from `.buffering` so the UI can show
    /// "Reconnecting…", and so a following `.failed` reads as the reconnect
    /// giving up. Bridged from `PlaybackPhase.stalled(reconnecting:)`.
    case reconnecting
    case ended
    case failed(PlaybackFailure)
}

/// The app's shape for a playback failure, from AetherEngine or from an HTTP or
/// decode error raised before the engine sees the load. Keeps AetherEngine's
/// types off the `PlaybackEngine` boundary, as `PlaybackTrack` does.
struct PlaybackFailure: Equatable {
    /// What recovery, if any, makes sense. Mirrors the distinction
    /// AetherEngine recommends branching on — `sourceRateLimited` versus
    /// `sourceRefused` — plus a catch-all.
    enum Category: Equatable {
        /// An access, format or hardware problem retrying can't fix.
        /// `PlayerView` offers Close only.
        case refused
        /// Origin metering (HTTP 429/503/509), expected to recover, so Retry
        /// stays offered with no Close.
        case rateLimited
        /// Engine-internal or otherwise recoverable by retry.
        case transient
    }

    var message: String
    var category: Category = .transient
}

/// Thrown by `AetherPlaybackEngine.load(...)` in place of the raw AetherEngine
/// error, so `PlayerViewModel`'s `LocalizedError` idiom still yields the
/// message while `category` carries the Retry-versus-Close choice.
struct PlaybackLoadFailure: Error, LocalizedError, Equatable {
    var failure: PlaybackFailure
    var errorDescription: String? { failure.message }
}

/// How the video surface fills its space; `PlayerView`'s landscape pinch and
/// double-tap gestures toggle it.
enum VideoZoomMode: Equatable {
    /// The whole frame, letterboxed or pillarboxed on an aspect mismatch. The
    /// default, and the only mode used in portrait.
    case fit
    /// Fills the screen, cropping whatever doesn't fit.
    case fill

    var toggled: VideoZoomMode { self == .fit ? .fill : .fit }
}

/// Engine and session diagnostics for `PlaybackStatsOverlay`, polled on a timer
/// while it is visible rather than pushed. Every field is display-ready, or nil
/// when not yet known, so the overlay stays a thin text layout.
struct PlaybackStats: Equatable {
    /// Source pixel dimensions, "1920×804". `nil` while loading and for
    /// audio-only sources.
    var videoSize: String?
    var frameRate: String?
    var bitrate: String?
    /// The dynamic-range format in the file, independent of whether this panel
    /// can present it.
    var sourceColorFormat: String
    /// What reaches the display after panel clamping — a Dolby Vision source
    /// tone-mapped to HDR10, say. Differs from `sourceColorFormat` exactly when
    /// clamping happens.
    var displayColorFormat: String
    var videoDecoder: String?
    var audioDecoder: String?
    /// The active audio track's channel layout ("5.1", or "Atmos" for a
    /// JOC-profile EAC3 track), not the output device's channel count, which
    /// the overlay shows separately. `nil` before a track is known.
    var audioChannels: String?
    /// AetherEngine's rendering backend: "Native", "Software", "Audio", "None".
    var backend: String
    /// `AetherEngine.videoRoute`: which pipeline is serving the session.
    /// Separate from `backend`, which cannot distinguish `.remoteBypass`
    /// (AVPlayer on the origin URL) from `.loopback` (AetherEngine's local
    /// demux and remux) — both collapse to `.native`. This also reflects the
    /// reroutes AetherEngine makes mid-session on its own findings, such as a
    /// misdeclared HLS carriage.
    var route: String
    /// Seconds fetched ahead of the playhead: the margin before playback would
    /// rebuffer. `nil` off the native backend, where `bufferedPosition` means
    /// "newest demuxed PTS since session start" and tracks the playhead rather
    /// than any read-ahead — reporting that would read as a stuck "0.0s",
    /// indistinguishable from a stall.
    var bufferedSeconds: Double?
    /// Resident size of the segment cache `bufferedSeconds` measures; `nil` in
    /// the same case.
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
    /// The picker row's main line: a descriptive track name where one exists,
    /// else a friendly language name ("English", not "ENG (srt)"). See
    /// `AetherPlaybackEngine.title(for:)`.
    var title: String
    /// The picker row's metadata line: whichever of "Default", "Forced",
    /// "Hearing Impaired", "Commentary" and "External" apply, joined and
    /// display-ready. Audio tracks also carry format, an additive "Atmos" flag,
    /// and channel layout. `nil` when nothing applies.
    var metadata: String?
    var isSelected: Bool

    /// A copy with only `isSelected` changed. `AetherPlaybackEngine` re-maps
    /// its whole track list on every selection change to flip this one field.
    func selected(_ isSelected: Bool) -> PlaybackTrack {
        var copy = self
        copy.isSelected = isSelected
        return copy
    }
}

/// A sidecar subtitle file to register alongside a load, normalized from
/// Jellyfin's `isExternal` `MediaStream`s so conformers don't depend on
/// AetherEngine's `ExternalSubtitleTrack`. AetherEngine folds each into
/// `$subtitleTracks` with a synthetic id and `isExternal == true`, which track
/// normalization turns into an "External" metadata flag.
struct ExternalSubtitleSource: Equatable {
    var url: URL
    /// The track name Jellyfin reports, if any. `descriptiveName(_:)`'s
    /// heuristic applies once this reaches `TrackInfo.name`, so `nil` simply
    /// falls through to a friendly language name.
    var name: String?
    /// BCP-47 or ISO 639, as for embedded tracks.
    var language: String?
    var isForced: Bool = false
    var isHearingImpaired: Bool = false
    var isDefault: Bool = false
    /// Format override for a `url` whose path doesn't reveal it. Jellyfin's
    /// `MediaStream.codec` values already match what AetherEngine expects.
    var formatHint: String?
}

/// A decoded subtitle cue for the app's overlay to paint, normalized from
/// AetherEngine's subtitle types so `SubtitleOverlayView` doesn't depend on
/// them. AetherEngine emits cues and draws nothing itself.
///
/// `startTime`/`endTime` are source PTS seconds: filter against
/// `PlayerViewModel.sourceTime`, not `currentTime`, since the two diverge
/// across producer restarts. The list covers a window ahead of the playhead, so
/// a cue outside its active window simply isn't rendered yet.
struct SubtitleCueDisplay: Identifiable, Equatable {
    var id: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var body: Body
    /// Where the source asked this cue to be drawn (ASS `\an`/`\pos`); `nil`
    /// for most cues, which take the overlay's bottom-center default. Text cues
    /// only — an image cue carries its geometry on `Body.image`.
    var placement: Placement?

    enum Body: Equatable {
        case text(String)
        case richText([Run])
        /// `rect`/`canvasSize` are normalized `[0, 1]` against the source frame,
        /// as `SubtitleImage.position` is: map them onto the on-screen video
        /// rect to place the image where it was authored. A `.zero`
        /// `canvasSize` means the canvas equals the video.
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

    /// One contiguous same-styling span of a rich-text cue. SRT/WebVTT inline
    /// tags, ASS override tags and teletext colour all normalize to this shape.
    /// A cue with no attributes stays plain `.text` rather than one-run
    /// `.richText`.
    struct Run: Equatable {
        var text: String
        var color: Color?
        var isBold: Bool = false
        var isItalic: Bool = false
        var isUnderlined: Bool = false
        var isStruckThrough: Bool = false
    }

    /// ASS numpad alignment (`\an`: 1 bottom-left to 9 top-right, 5 centred)
    /// plus an optional normalized `\pos` anchor, y from the top. Either may
    /// appear alone.
    struct Placement: Equatable {
        var alignment: Int?
        var position: CGPoint?
    }

    /// Plain text, with rich runs concatenated; `nil` for image cues.
    var text: String? {
        switch body {
        case .text(let string): return string
        case .richText(let runs): return runs.map(\.text).joined()
        case .image: return nil
        }
    }
}
