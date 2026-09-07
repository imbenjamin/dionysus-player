import CoreGraphics
import UIKit

/// Offline counterpart to `TrickplayThumbnailProvider` — same seconds→
/// sheet/tile math (`TrickplayMath`), but reads sheet JPEGs straight from
/// `DownloadFileStore` instead of fetching them over the network. See
/// `DownloadManager.enqueue`'s trickplay section for how the sheets get onto
/// disk in the first place, and `DownloadedItem.trickplayInfo` for how
/// `PlayerViewModel.startOffline` knows whether this download has any to
/// read.
struct OfflineTrickplayThumbnailProvider: ScrubThumbnailProviding {
    let itemID: String
    let info: TrickplayInfo

    /// Same reasoning as `RemoteImageLoader.memoryCache` — a scrub session
    /// revisits the same sheet repeatedly (100 stills/sheet at the usual
    /// 10×10 grid), and re-decoding a multi-megabyte JPEG from disk on
    /// every tile crop would be wasteful. `nonisolated(unsafe)`, same as
    /// that property: `NSCache` is documented thread-safe for concurrent
    /// access from multiple threads, so the compiler's actor-isolation
    /// check here is stricter than the actual safety guarantee. Instance-,
    /// not type-scoped — a fresh provider (and cache) per player session,
    /// same lifetime `TrickplayThumbnailProvider.imageLoader` already uses,
    /// rather than one pool shared for the app's whole lifetime.
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
            // A sheet download can fail independently of the rest (see
            // `DownloadManager.enqueue`'s best-effort trickplay fetch) — a
            // missing file here just means no preview for this second,
            // same "keep showing whatever was last shown" fallback the
            // live provider's own nil already gets from
            // `PlayerControlsOverlay`.
            sheet = nil
        }
        guard let cgImage = sheet?.cgImage else { return nil }
        return cgImage.cropping(to: frame.tileRect)
    }
}
