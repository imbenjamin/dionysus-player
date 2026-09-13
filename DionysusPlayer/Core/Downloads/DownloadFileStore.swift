import Foundation

/// Where offline downloads live: `Application Support/Downloads/`, excluded
/// from backup so re-fetchable media doesn't bloat one. Not `Library/Caches`,
/// which the OS may purge without warning — wrong for something a user chose to
/// keep offline.
///
/// Video and subtitles are per-item. Images are a shared, content-addressed pool
/// keyed by `(sourceItemID, imageType, tag)` rather than by which downloads
/// reference them, since episodes commonly reuse their series' logo and backdrop
/// — Jellyfin has no per-episode logo — and would otherwise duplicate the file.
///
/// The reference check guarding a shared image's deletion lives on
/// `DownloadStore.isImagePathReferenced(_:excludingItemID:)`: this type knows
/// about files, not which items reference them.
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

    /// Per-item rather than content-addressed: a trickplay sheet belongs to one
    /// item's scrub track, so keying by content identity would dedup nothing.
    /// `width` is the resolution tier and `sheetIndex` the sheet within it, the
    /// two variables `ImageURLBuilder.trickplayTileURL` addresses live. Living
    /// under `<itemID>/`, these are cleaned up by `deleteItemFiles(itemID:)`.
    static func trickplayTileRelativePath(itemID: String, width: Int, sheetIndex: Int) -> String {
        "\(itemID)/trickplay/\(width)/\(sheetIndex).jpg"
    }

    /// Content-addressed, not tied to which downloads reference it.
    static func imageRelativePath(sourceItemID: String, imageType: String, tag: String) -> String {
        "images/\(sanitized(sourceItemID))-\(sanitized(imageType))-\(sanitized(tag)).jpg"
    }

    /// Whether a file already exists for this image identity: the fetch-time half
    /// of the shared-artwork dedup. On a hit, callers skip the fetch and record
    /// the existing path on the new item.
    static func imageAlreadyExists(sourceItemID: String, imageType: String, tag: String) -> Bool {
        FileManager.default.fileExists(
            atPath: url(forRelativePath: imageRelativePath(sourceItemID: sourceItemID, imageType: imageType, tag: tag)).path
        )
    }

    /// Writes `data` to `relativePath`, creating intermediate directories.
    static func write(_ data: Data, toRelativePath relativePath: String) throws {
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    /// Moves a file — a `URLSessionDownloadTask`'s temp location, say — to
    /// `relativePath`, creating intermediate directories and replacing anything
    /// already there.
    static func moveFile(from sourceURL: URL, toRelativePath relativePath: String) throws {
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destination)
    }

    /// Deletes an item's video and subtitle files unconditionally; unlike
    /// images, these are never shared with another item.
    static func deleteItemFiles(itemID: String) {
        try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(itemID, isDirectory: true))
    }

    /// Deletes per-item directories with no corresponding row in `knownItemIDs`,
    /// sweeping files a download left behind when its background session
    /// outlived the row that owned it — the delegate moves a completed file into
    /// permanent storage first and only then checks for a row. Called once per
    /// launch.
    ///
    /// Skips the shared `images/` pool, which is reference-counted by path
    /// rather than by directory name and handled by `deleteImageIfUnreferenced`.
    static func deleteOrphanedItemDirectories(knownItemIDs: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != "images", !knownItemIDs.contains(name) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Unlinks a shared image only when no other `DownloadedItem` row points at
    /// it. Safe with a `nil` path or one whose file is already gone.
    @MainActor
    static func deleteImageIfUnreferenced(relativePath: String?, excludingItemID: String, store: DownloadStore) {
        deleteImageIfUnreferenced(relativePath: relativePath, excludingItemID: excludingItemID, store: store, among: store.allItems())
    }

    /// The same guard against an already-fetched row snapshot, so a caller
    /// checking several paths — `DownloadManager.delete(itemID:)`'s four image
    /// fields — pays one SwiftData fetch rather than N.
    @MainActor
    static func deleteImageIfUnreferenced(relativePath: String?, excludingItemID: String, store: DownloadStore, among items: [DownloadedItem]) {
        guard let relativePath else { return }
        guard !store.isImagePathReferenced(relativePath, excludingItemID: excludingItemID, among: items) else { return }
        try? FileManager.default.removeItem(at: url(forRelativePath: relativePath))
    }

    /// One file's real on-disk size; `nil` when it doesn't exist or can't be
    /// read. Ground truth for `DownloadedAssetDetailView`'s readout, since the
    /// in-flight byte counts are never persisted.
    static func fileSize(forRelativePath relativePath: String) -> Int64? {
        guard let size = try? url(forRelativePath: relativePath).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    /// Total on-disk size under the Downloads root, shown in `ProfileView`'s
    /// Downloads settings.
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

    /// Sanitizes a path component. Jellyfin ids and tags are usually already
    /// alphanumeric; this guards against a stray `/` in a language code.
    private static func sanitized(_ raw: String) -> String {
        String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }
}
