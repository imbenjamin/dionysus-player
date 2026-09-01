import ImageIO
import SwiftUI
import UIKit

/// Renders an image from a local file — offline-downloaded artwork.
/// Deliberately not `AsyncRemoteImage`/`RemoteImageLoader`: those are
/// inherently network-shaped (retry-with-backoff, an `NSCache` +
/// `URLCache`-backed session tuned for flaky/slow HTTP) and, worse, broken
/// for this case — `RemoteImageLoader.fetchWithRetry` casts the response
/// to `HTTPURLResponse` to check its status code, but a `file://` URL's
/// response is a plain `URLResponse` with no HTTP status at all, so that
/// cast fails unconditionally regardless of whether the file is valid.
/// Local disk reads need none of that machinery anyway, so this just reads
/// the file directly.
struct LocalFileImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    /// The SF Symbol `MediaPlaceholderBox` shows when `url` is `nil` or
    /// fails to decode — see `AsyncRemoteImage.placeholderSystemImage`'s
    /// doc comment for the same reasoning.
    var placeholderSystemImage: String = "photo"
    var glyphSize: CGFloat = 28

    private let image: UIImage?

    /// Synchronous, not `.task`-deferred — local disk reads are fast
    /// enough not to need async loading. Cached (a small dedicated
    /// `NSCache`, checked/populated right here) since this can sit next to
    /// a live-ticking download-progress view re-rendering several times a
    /// second, and re-decoding the same JPEG from disk on every one of
    /// those would be wasteful — same "seed synchronously from whatever's
    /// already cached" shape `AsyncRemoteImage.init` uses for its own
    /// (network) cache.
    ///
    /// `targetSize` (in points — converted to pixels internally via the
    /// device's display scale) downsamples the decode to roughly that
    /// footprint via `ImageIO`'s thumbnail-generation API, instead of
    /// decoding the source at full resolution and only shrinking it for
    /// display afterward — bounds the cache's memory to the actual
    /// on-screen pixel count for a small, fixed-size row thumbnail rather
    /// than the source image's own resolution. `nil` (the default) keeps
    /// the original full-resolution decode — the right choice for the
    /// hero backdrop/logo call sites, which need most of their frame's
    /// actual pixel budget, not a small fixed thumbnail size.
    init(
        url: URL?,
        contentMode: ContentMode = .fill,
        targetSize: CGSize? = nil,
        placeholderSystemImage: String = "photo",
        glyphSize: CGFloat = 28
    ) {
        self.url = url
        self.contentMode = contentMode
        self.placeholderSystemImage = placeholderSystemImage
        self.glyphSize = glyphSize
        guard let url else {
            image = nil
            return
        }
        let cacheKey = Self.cacheKey(url: url, targetSize: targetSize)
        if let cached = Self.cache.object(forKey: cacheKey) {
            image = cached
        } else if let decoded = Self.decode(url: url, targetSize: targetSize) {
            Self.cache.setObject(decoded, forKey: cacheKey, cost: Self.cost(of: decoded))
            image = decoded
        } else {
            image = nil
        }
    }

    /// Distinct cache slots per `(url, targetSize)` pair — a plain
    /// `url`-only key (this file's original scheme) would otherwise let a
    /// full-resolution decode cached by one caller get handed back to a
    /// different caller that asked for a small downsampled thumbnail of
    /// the same file (or vice versa), silently defeating the point of
    /// downsampling for whichever caller lost that race.
    private static func cacheKey(url: URL, targetSize: CGSize?) -> NSString {
        guard let targetSize else { return url.path as NSString }
        return "\(url.path)#\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
    }

    private static func decode(url: URL, targetSize: CGSize?) -> UIImage? {
        guard let targetSize else { return UIImage(contentsOfFile: url.path) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixelSize = max(targetSize.width, targetSize.height) * displayScale
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Roughly the decoded RGBA byte footprint — doesn't need to be exact,
    /// just proportional, so `cache.totalCostLimit` below actually bounds
    /// real memory rather than just entry count.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.width * cgImage.height * 4
    }

    /// Same "key window's own screen, not `UIScreen.main`" reasoning as
    /// `HeroHeaderView.screenHeight`'s own doc comment (`UIScreen.main` is
    /// soft-deprecated and doesn't necessarily reflect the right screen
    /// under iPadOS Stage Manager's multi-scene support) — display *scale*
    /// specifically doesn't actually vary with Stage Manager resizing a
    /// window the way bounds does, but there's no reason to reach for the
    /// soft-deprecated API when the scene-based one is just as easy here.
    private static var displayScale: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.scale ?? 3
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // 64 MB — generous for a handful of on-screen thumbnails/hero
        // images at once, but no longer unbounded the way a plain
        // `NSCache` with no cost limit effectively is.
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
        } else {
            // Always settled, never shimmering — this type's decode is
            // synchronous, so there's no "still loading" window to
            // distinguish from a genuine failure.
            MediaPlaceholderBox(systemImage: placeholderSystemImage, glyphSize: glyphSize, isSettled: true)
        }
    }
}
