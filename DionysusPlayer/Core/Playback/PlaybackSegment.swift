import Foundation

/// App-facing model for a Jellyfin `MediaSegmentDto` (see
/// `JellyfinAPIClient.mediaSegments(itemID:)`) — ticks converted to seconds
/// once up front (same `/10_000_000` math `PlayerViewModel.stop()`/
/// `MediaItem.resumePositionSeconds` already use) so `PlayerViewModel` and
/// its overlays can compare directly against `currentTime`/`duration`
/// without re-deriving that conversion at every call site.
struct PlaybackSegment: Identifiable, Equatable {
    enum Kind: Equatable {
        case intro, outro, recap, preview, commercial

        /// The floating button's label for this segment type — matches the
        /// "Skip X" convention Jellyfin's own web client uses, including
        /// calling an `.outro` segment "Skip Credits" rather than "Skip
        /// Outro". A model-layer string, so `String(localized:)` rather
        /// than a `Text` literal — see CLAUDE.md's localization rules.
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

    /// `nil` for a `.unknown`-typed segment — nothing sensible to show a
    /// skip button for — rather than failing the whole fetch;
    /// `PlayerViewModel.loadMediaSegments(for:)` drops those with a
    /// `compactMap` rather than propagating a per-segment failure.
    init?(dto: MediaSegmentDto) {
        guard let kind = Kind(dtoType: dto.type) else { return nil }
        self.id = dto.id
        self.kind = kind
        self.startSeconds = Double(dto.startTicks) / 10_000_000
        self.endSeconds = Double(dto.endTicks) / 10_000_000
    }

    /// Builds directly from a locally stored `DownloadedSegment` snapshot —
    /// offline playback seeds `PlayerViewModel.mediaSegments` from this
    /// instead of a live `mediaSegments(itemID:)` fetch (see the
    /// offline-downloads plan's "Offline playback wiring" section), so
    /// there's no server-assigned `id` to reuse; kind+start is stable and
    /// unique enough per item to stand in for one. Always succeeds —
    /// `DownloadedSegment.Kind` has no `.unknown` case to reject, unlike
    /// the live DTO's `MediaSegmentType` — so this isn't failable the way
    /// `init?(dto:)` is.
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
