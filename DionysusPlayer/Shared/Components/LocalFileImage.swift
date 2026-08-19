import SwiftUI
import UIKit

/// Renders an image from a local file — offline-downloaded artwork.
/// Deliberately not `AsyncRemoteImage`/`RemoteImageLoader`: those are
/// inherently network-shaped (retry-with-backoff, an `NSCache` +
/// `URLCache`-backed session tuned for flaky/slow HTTP), and — the actual
/// bug this exists to fix, confirmed live (2026-08-19) — `RemoteImageLoader
/// .fetchWithRetry` casts the response to `HTTPURLResponse` to check its
/// status code; a `file://` URL's response is a plain `URLResponse` with no
/// HTTP status at all, so that cast fails unconditionally and every local
/// image load through that path threw every time, regardless of whether
/// the file existed and was perfectly valid. Local disk reads need none of
/// that machinery anyway — no network flakiness to retry, no need for a
/// second cache layer on top of the filesystem — so this just reads the
/// file directly.
struct LocalFileImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill

    private let image: UIImage?

    /// Synchronous, not `.task`-deferred — local disk reads are fast
    /// enough not to need async loading. Cached (a small dedicated
    /// `NSCache`, checked/populated right here) since this can sit next to
    /// a live-ticking download-progress view re-rendering several times a
    /// second, and re-decoding the same JPEG from disk on every one of
    /// those would be wasteful — same "seed synchronously from whatever's
    /// already cached" shape `AsyncRemoteImage.init` uses for its own
    /// (network) cache.
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        guard let url else {
            image = nil
            return
        }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
        } else if let decoded = UIImage(contentsOfFile: url.path) {
            Self.cache.setObject(decoded, forKey: url as NSURL)
            image = decoded
        } else {
            image = nil
        }
    }

    private static let cache = NSCache<NSURL, UIImage>()

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
        } else {
            Rectangle().fill(Color.gray.opacity(0.2))
        }
    }
}
