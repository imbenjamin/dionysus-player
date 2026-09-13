import Foundation

/// App-facing model for one `ChapterInfoDto`, with ticks converted to seconds
/// and the still-frame URL resolved once, so views can compare against
/// `currentTime` and render artwork without re-deriving either.
///
/// Not `PlaybackSegment`: a chapter is navigational, a name to jump to, while a
/// segment is a typed skippable range with auto-skip UI. Nothing here should
/// grow skip behaviour.
struct Chapter: Identifiable, Equatable {
    /// `index` plus start position rather than `index` alone: chapters are
    /// addressed positionally with no server-side id, and the pair keeps a
    /// `ForEach` row's identity stable when the same chapter is rebuilt from a
    /// `DownloadedChapter` snapshot offline.
    let id: String
    /// 0-based position in the item's `Chapters` array: the key Jellyfin's
    /// chapter-image route uses, and the number in an unnamed chapter's
    /// fallback title.
    let index: Int
    let name: String
    let startSeconds: TimeInterval
    /// Kept beside the resolved `imageURL` because the download path needs the
    /// raw tag: it is half the content-addressed identity
    /// `DownloadFileStore.imageRelativePath` stores an offline copy under. `nil`
    /// means the chapter has no image.
    let imageTag: String?
    /// A remote URL for a live item, a `file://` one for a downloaded item, or
    /// `nil` when there is no image. Call sites branch on `isFileURL` to pick
    /// `LocalFileImage` over `AsyncRemoteImage`.
    let imageURL: URL?

    /// `index` is the chapter's position in `BaseItemDto.chapters`, which is both
    /// the image route's key and the fallback name's number. `images`/`itemID`
    /// resolve `imageURL`, and only when `imageTag` is non-nil.
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

    /// Builds from a stored `DownloadedChapter`, as
    /// `PlaybackSegment.init(downloaded:)` does, so `imageURL` resolves to the
    /// downloaded file rather than an unreachable network route. `imageTag`
    /// stays `nil`: it exists only to drive a download.
    init(downloaded: DownloadedChapter) {
        self.id = "\(downloaded.index)-\(downloaded.startSeconds)"
        self.index = downloaded.index
        self.name = Self.displayName(downloaded.name, index: downloaded.index)
        self.startSeconds = downloaded.startSeconds
        self.imageTag = nil
        self.imageURL = downloaded.imageRelativePath.map(DownloadFileStore.url(forRelativePath:))
    }

    /// Enough for the detail page's 220pt landscape tile at 3×, without pulling
    /// a full-resolution still for a small thumbnail.
    private static let imageMaxWidth = 640

    /// Jellyfin normalizes a blank or timestamp-shaped chapter name to
    /// "Chapter N" server-side, so this is defensive — but an older server, or a
    /// remux whose names came through as whitespace, would otherwise render a
    /// blank row with nothing to target by name.
    private static func displayName(_ raw: String?, index: Int) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Chapter \(index + 1)")
        }
        return raw
    }
}

extension Array where Element == Chapter {
    /// The chapter containing `time`: the last starting at or before it, `nil`
    /// with no chapters. `startSeconds` increases monotonically as Jellyfin
    /// returns it, so `last(where:)` suffices.
    func chapter(at time: TimeInterval) -> Chapter? {
        last { $0.startSeconds <= time }
    }
}
