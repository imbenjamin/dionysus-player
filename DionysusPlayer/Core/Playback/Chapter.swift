import Foundation

/// App-facing model for one Jellyfin `ChapterInfoDto` (see
/// `BaseItemDto.chapters`) — ticks converted to seconds once up front (the
/// same `/10_000_000` math `PlaybackSegment` and `MediaItem
/// .resumePositionSeconds` already use) and the still-frame URL resolved
/// once, so `MediaItem`/`PlayerViewModel` and their views can compare
/// against `currentTime`/`duration` and render artwork without re-deriving
/// either at every call site.
///
/// Deliberately *not* `PlaybackSegment`: a chapter is purely navigational
/// (a name the user can jump to), while a segment is a typed, skippable
/// range with its own auto-skip UI. Nothing here should ever grow skip
/// behavior — see `BaseItemDto.chapters`' doc comment.
struct Chapter: Identifiable, Equatable {
    /// `index` plus the start position rather than `index` alone — an
    /// item's chapters are addressed positionally by the server (there's no
    /// chapter id to reuse), and pairing the two keeps a `ForEach` row's
    /// identity stable across the online → offline model swap, where the
    /// same chapter is rebuilt from a `DownloadedChapter` snapshot instead.
    let id: String
    /// 0-based position in the item's own `Chapters` array — the value
    /// Jellyfin's chapter-image route is keyed by, and what
    /// `"Chapter \(index + 1)"` falls back to for an unnamed chapter.
    let index: Int
    let name: String
    let startSeconds: TimeInterval
    /// Kept alongside the already-resolved `imageURL` because the download
    /// path needs the raw tag itself, not a URL — it's half the
    /// content-addressed identity `DownloadFileStore
    /// .imageRelativePath(sourceItemID:imageType:tag:)` stores an offline
    /// copy under. `nil` means this chapter genuinely has no image.
    let imageTag: String?
    /// A remote `https://` image URL for a live item, a local `file://` one
    /// for a downloaded item (see `init(downloaded:)`), or `nil` when
    /// there's no image either way. Call sites branch on `isFileURL` to pick
    /// `LocalFileImage` over `AsyncRemoteImage`, per CLAUDE.md's
    /// image-loading split — same shape `PlayerControlsOverlay.titleRow`
    /// already uses for the offline logo.
    let imageURL: URL?

    /// Built from the item's DTO — `index` is the chapter's position in
    /// `BaseItemDto.chapters`, which is both the image route's key and the
    /// fallback name's number. `images`/`itemID` are only used to resolve
    /// `imageURL`, and only when `imageTag` is non-nil.
    init(dto: ChapterInfoDto, index: Int, itemID: String, images: ImageURLBuilder) {
        self.id = "\(index)-\(dto.startPositionTicks)"
        self.index = index
        self.name = Self.displayName(dto.name, index: index)
        self.startSeconds = Double(dto.startPositionTicks) / 10_000_000
        self.imageTag = dto.imageTag
        self.imageURL = dto.imageTag.flatMap {
            images.chapterImageURL(itemID: itemID, chapterIndex: index, tag: $0, maxWidth: Self.imageMaxWidth)
        }
    }

    /// Builds directly from a locally stored `DownloadedChapter` snapshot,
    /// mirroring `PlaybackSegment.init(downloaded:)` — offline playback and
    /// the offline detail page seed their chapters from this instead of a
    /// live DTO, so `imageURL` resolves to the already-downloaded file on
    /// disk rather than a network route that isn't reachable offline.
    /// `imageTag` stays `nil` here: it only exists to *drive* a download,
    /// and this side of the boundary is already past that.
    init(downloaded: DownloadedChapter) {
        self.id = "\(downloaded.index)-\(downloaded.startSeconds)"
        self.index = downloaded.index
        self.name = Self.displayName(downloaded.name, index: downloaded.index)
        self.startSeconds = downloaded.startSeconds
        self.imageTag = nil
        self.imageURL = downloaded.imageRelativePath.map(DownloadFileStore.url(forRelativePath:))
    }

    /// Wide enough for the detail page's landscape chapter tile (220pt at
    /// 3× ≈ 660px) without pulling a full-resolution still for what's only
    /// ever shown as a small thumbnail here and in the player's picker.
    private static let imageMaxWidth = 640

    /// Jellyfin normally normalizes a blank or timestamp-looking chapter
    /// name to "Chapter N" server-side already
    /// (`FFProbeVideoInfo.NormalizeChapterNames`), so this is defensive
    /// rather than load-bearing — but an older/unpatched server, or a
    /// remuxed file whose chapter names came through as whitespace, would
    /// otherwise render a blank row with nothing to tap-target by name.
    private static func displayName(_ raw: String?, index: Int) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Chapter \(index + 1)")
        }
        return raw
    }
}

extension Array where Element == Chapter {
    /// The chapter containing `time` — the last one starting at or before it
    /// — or `nil` when there are no chapters at all. The same "last item ≤
    /// time" lookup the player's current-chapter button, picker highlight,
    /// and scrub label all need; `startSeconds` is monotonically increasing
    /// as Jellyfin returns it, so `last(where:)` is enough.
    func chapter(at time: TimeInterval) -> Chapter? {
        last { $0.startSeconds <= time }
    }
}
