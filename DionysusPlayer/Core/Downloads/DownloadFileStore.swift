import Foundation

/// Where offline downloads live on disk — `Application Support/Downloads/`,
/// marked excluded from backup (large, re-fetchable media has no business
/// bloating an iCloud/iTunes backup) — chosen over `Library/Caches`
/// deliberately: `Caches` is free for the OS to purge under storage
/// pressure with zero warning, which is exactly wrong for something a user
/// explicitly chose to keep for offline viewing.
///
/// Video/subtitles are per-item (`<itemID>/video.mp4`,
/// `<itemID>/subs/<index>-<lang>.<ext>`); images are a **shared,
/// content-addressed pool** (`images/<sourceItemID>-<imageType>-<tag>.jpg`)
/// keyed by identity, not by which download(s) reference it — episode
/// downloads commonly reuse their series' own logo/backdrop (Jellyfin has
/// no per-episode logo), so two episodes of the same show resolve to the
/// same on-disk file rather than duplicating it. See the offline-downloads
/// plan's "Shared artwork dedup" and "Delete semantics" sections; the
/// reference check that guards deleting a shared image lives on
/// `DownloadStore.isImagePathReferenced(_:excludingItemID:)`, not here —
/// this type only knows about files, not which items reference them.
enum DownloadFileStore {
    private static let rootDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var root = appSupport.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root
    }()

    static func url(forRelativePath relativePath: String) -> URL {
        rootDirectory.appendingPathComponent(relativePath)
    }

    static func videoRelativePath(itemID: String) -> String {
        "\(itemID)/video.mp4"
    }

    static func subtitleRelativePath(itemID: String, index: Int, language: String?, fileExtension: String) -> String {
        "\(itemID)/subs/\(index)-\(sanitized(language ?? "und")).\(fileExtension)"
    }

    /// Content-addressed, not tied to which download(s) reference it — see
    /// this type's own doc comment.
    static func imageRelativePath(sourceItemID: String, imageType: String, tag: String) -> String {
        "images/\(sanitized(sourceItemID))-\(sanitized(imageType))-\(sanitized(tag)).jpg"
    }

    /// True if a file already exists for this exact image identity — the
    /// fetch-time half of the shared-artwork dedup: callers check this
    /// before downloading and skip the fetch entirely on a hit, just
    /// recording the existing relative path on the new item instead of
    /// re-fetching and re-storing a duplicate.
    static func imageAlreadyExists(sourceItemID: String, imageType: String, tag: String) -> Bool {
        FileManager.default.fileExists(
            atPath: url(forRelativePath: imageRelativePath(sourceItemID: sourceItemID, imageType: imageType, tag: tag)).path
        )
    }

    /// Writes `data` to `relativePath`, creating any needed intermediate
    /// directories first.
    static func write(_ data: Data, toRelativePath relativePath: String) throws {
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    /// Moves a file (e.g. a `URLSessionDownloadTask`'s temp location) into
    /// place at `relativePath`, creating any needed intermediate
    /// directories first and replacing anything already there.
    static func moveFile(from sourceURL: URL, toRelativePath relativePath: String) throws {
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destination)
    }

    /// Deletes an item's video + subtitle files unconditionally — never
    /// shared with another item, unlike images (see
    /// `deleteImageIfUnreferenced(relativePath:excludingItemID:store:)`).
    static func deleteItemFiles(itemID: String) {
        try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(itemID, isDirectory: true))
    }

    /// Unlinks a shared image file from disk only if no other
    /// `DownloadedItem` row still points at it (`store`'s own reference
    /// check) — see the offline-downloads plan's "Delete semantics"
    /// section. Safe to call with a `nil` path (nothing to do) or a path
    /// whose file is already gone.
    @MainActor
    static func deleteImageIfUnreferenced(relativePath: String?, excludingItemID: String, store: DownloadStore) {
        guard let relativePath else { return }
        guard !store.isImagePathReferenced(relativePath, excludingItemID: excludingItemID) else { return }
        try? FileManager.default.removeItem(at: url(forRelativePath: relativePath))
    }

    /// Actual on-disk size of one file, in bytes — `nil` if it doesn't
    /// exist (e.g. still downloading) or can't be read. Ground truth for
    /// `DownloadedAssetDetailView`'s file-size readout, rather than
    /// trusting `DownloadedItem.bytesDownloaded`/`totalBytesExpected`
    /// (which this app never actually persists — see `DownloadProgress`'s
    /// own doc comment for why that stays in-memory only).
    static func fileSize(forRelativePath relativePath: String) -> Int64? {
        guard let size = try? url(forRelativePath: relativePath).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    /// Total on-disk size of everything under the Downloads root, in bytes
    /// — surfaced in `ProfileView`'s Downloads settings section.
    static func totalSizeOnDisk() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Sanitizes a path component for filesystem safety — Jellyfin item
    /// ids/tags are typically already alphanumeric, but this guards against
    /// any stray path-hostile character (e.g. a `/` in a language code)
    /// regardless.
    private static func sanitized(_ raw: String) -> String {
        String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }
}
