import Foundation

/// App-facing model for a `MediaSegmentDto`, with ticks converted to seconds
/// once so `PlayerViewModel` and its overlays compare directly against
/// `currentTime` without re-deriving that at each call site.
struct PlaybackSegment: Identifiable, Equatable {
    enum Kind: Equatable {
        case intro, outro, recap, preview, commercial

        /// The floating button's label, following jellyfin-web's "Skip X"
        /// convention, including "Skip Credits" for an `.outro` segment. A
        /// model-layer string, hence `String(localized:)`.
        var skipButtonTitle: String {
            switch self {
            case .intro: return String(localized: "Skip Intro")
            case .outro: return String(localized: "Skip Credits")
            case .recap: return String(localized: "Skip Recap")
            case .preview: return String(localized: "Skip Preview")
            case .commercial: return String(localized: "Skip Commercial")
            }
        }

        fileprivate init?(dtoType: MediaSegmentType) {
            switch dtoType {
            case .intro: self = .intro
            case .outro: self = .outro
            case .recap: self = .recap
            case .preview: self = .preview
            case .commercial: self = .commercial
            case .unknown: return nil
            }
        }
    }

    let id: String
    let kind: Kind
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval

    /// `nil` for an `.unknown`-typed segment, which has no sensible skip button,
    /// rather than failing the fetch; `loadMediaSegments(for:)` drops those with
    /// a `compactMap`.
    init?(dto: MediaSegmentDto) {
        guard let kind = Kind(dtoType: dto.type) else { return nil }
        self.id = dto.id
        self.kind = kind
        self.startSeconds = Double(dto.startTicks) / 10_000_000
        self.endSeconds = Double(dto.endTicks) / 10_000_000
    }

    /// Builds from a stored `DownloadedSegment`, which offline playback seeds
    /// `PlayerViewModel.mediaSegments` from instead of a live fetch. There is no
    /// server-assigned `id` to reuse, so kind and start stand in. Not failable
    /// like `init?(dto:)`: `DownloadedSegment.Kind` has no `.unknown` case.
    init(downloaded: DownloadedSegment) {
        self.id = "\(downloaded.kind.rawValue)-\(downloaded.startSeconds)"
        self.kind = Kind(downloadedKind: downloaded.kind)
        self.startSeconds = downloaded.startSeconds
        self.endSeconds = downloaded.endSeconds
    }
}

private extension PlaybackSegment.Kind {
    init(downloadedKind: DownloadedSegment.Kind) {
        switch downloadedKind {
        case .intro: self = .intro
        case .outro: self = .outro
        case .recap: self = .recap
        case .preview: self = .preview
        case .commercial: self = .commercial
        }
    }
}
