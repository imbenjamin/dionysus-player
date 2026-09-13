import CoreGraphics
import UIKit

/// `TrickplayThumbnailProvider`'s offline counterpart: the same `TrickplayMath`,
/// reading sheet JPEGs from `DownloadFileStore` rather than the network.
/// `DownloadManager.enqueue` puts them there, and
/// `DownloadedItem.trickplayInfo` says whether a download has any.
struct OfflineTrickplayThumbnailProvider: ScrubThumbnailProviding {
    let itemID: String
    let info: TrickplayInfo

    /// A scrub session revisits the same sheet repeatedly — 100 stills per sheet
    /// at the usual grid — so re-decoding a multi-megabyte JPEG per tile crop
    /// would be wasteful. `nonisolated(unsafe)` is safe: `NSCache` is
    /// thread-safe. Instance-scoped, so a fresh cache per player session rather
    /// than one pool for the app's lifetime.
    nonisolated(unsafe) private let sheetCache = NSCache<NSURL, UIImage>()

    func thumbnail(atSeconds seconds: Double) async -> CGImage? {
        guard let frame = TrickplayMath.frame(atSeconds: seconds, info: info) else { return nil }
        let relativePath = DownloadFileStore.trickplayTileRelativePath(itemID: itemID, width: info.width, sheetIndex: frame.sheetIndex)
        let url = DownloadFileStore.url(forRelativePath: relativePath)

        let sheet: UIImage?
        if let cached = sheetCache.object(forKey: url as NSURL) {
            sheet = cached
        } else if let decoded = UIImage(contentsOfFile: url.path) {
            sheetCache.setObject(decoded, forKey: url as NSURL)
            sheet = decoded
        } else {
            // A sheet download can fail independently of the rest, so a missing
            // file means no preview for this second — the same keep-showing-the-
            // last-frame fallback the live provider's nil gets.
            sheet = nil
        }
        guard let cgImage = sheet?.cgImage else { return nil }
        return cgImage.cropping(to: frame.tileRect)
    }
}
