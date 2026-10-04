import CoreGraphics
import Foundation

/// Pure seconds-to-(sheet index, tile rect) lookup for a trickplay track. No
/// I/O, so it is testable offline.
enum TrickplayMath {
    struct Frame: Equatable {
        let sheetIndex: Int
        /// Pixel rect within that sheet, origin top-left, as both
        /// `CGImage.cropping(to:)` and Jellyfin's row-major layout address it.
        let tileRect: CGRect
    }

    /// `nil` for a degenerate `info` with any non-positive field: a corrupt or
    /// partial response shouldn't be trusted to index into anything.
    static func frame(atSeconds seconds: Double, info: TrickplayInfo) -> Frame? {
        guard info.interval > 0, info.thumbnailCount > 0,
              info.tileWidth > 0, info.tileHeight > 0,
              info.width > 0, info.height > 0 else { return nil }
        let rawIndex = Int((seconds * 1000) / Double(info.interval))
        let thumbnailIndex = min(max(0, rawIndex), info.thumbnailCount - 1)
        let perSheet = info.tileWidth * info.tileHeight
        let sheetIndex = thumbnailIndex / perSheet
        let positionInSheet = thumbnailIndex % perSheet
        let column = positionInSheet % info.tileWidth
        let row = positionInSheet / info.tileWidth
        return Frame(
            sheetIndex: sheetIndex,
            tileRect: CGRect(x: column * info.width, y: row * info.height, width: info.width, height: info.height)
        )
    }

    /// How many tile sheets a trickplay track spans, every sheet fully packed
    /// but possibly the last. The live scrub path fetches sheets on demand as
    /// `frame(atSeconds:info:)` names them, but an offline download needs them
    /// all up front. `0` for the degenerate cases that method also guards.
    static func sheetCount(for info: TrickplayInfo) -> Int {
        let perSheet = info.tileWidth * info.tileHeight
        guard perSheet > 0, info.thumbnailCount > 0 else { return 0 }
        return (info.thumbnailCount + perSheet - 1) / perSheet
    }

    /// Picks a resolution when the server offers several: the smallest width at
    /// or above `preferredWidth`, else the largest available. `nil` when this
    /// media source has no trickplay track — unscanned content, or a stale
    /// preference for a version the server no longer has.
    static func bestInfo(
        from trickplay: [String: [String: TrickplayInfo]]?, mediaSourceID: String?, preferredWidth: Int = 320
    ) -> TrickplayInfo? {
        guard let mediaSourceID, let widths = trickplay?[mediaSourceID], !widths.isEmpty else { return nil }
        let sorted = widths.values.sorted { $0.width < $1.width }
        return sorted.first { $0.width >= preferredWidth } ?? sorted.last
    }
}

/// A scrub-preview still for a given second. `TrickplayThumbnailProvider` fetches
/// tile sheets over the network and `OfflineTrickplayThumbnailProvider` reads
/// them from disk; both share `TrickplayMath` and differ only in where the bytes
/// come from, so `PlayerViewModel.start()`/`.startOffline()` install whichever
/// applies.
///
/// `@MainActor` sits on the requirement rather than the protocol: on the
/// protocol it would infer the same isolation onto every conformer's
/// initializer, breaking off-actor construction in tests.
protocol ScrubThumbnailProviding {
    @MainActor func thumbnail(atSeconds seconds: Double) async -> CGImage?
}

/// Fetches and crops one trickplay tile for a scrub position. Replaces
/// AetherEngine's cache-backed scrub stills, which only serve a narrow window of
/// already-decoded segments near the playhead — so every request during a real
/// drag missed, a drag being aimed at a position the user hasn't watched.
/// Trickplay sheets are pre-generated server-side and span the whole item.
///
/// One sheet covers `tileWidth * tileHeight` stills, so after the first, calls
/// within the same sheet are a synchronous crop: `RemoteImageLoader` caches the
/// sheet by URL.
struct TrickplayThumbnailProvider: ScrubThumbnailProviding {
    /// A 3200×1800 sheet — a 10×10 grid of 320×180 tiles — decodes to ~23MB,
    /// against `RemoteImageLoader.defaultTotalCostLimit`'s 150MB shared budget
    /// for every poster and backdrop app-wide. Since that cache costs by decoded
    /// size, a scrub session touching a handful of sheets would fill it and
    /// evict images the rest of the app relies on. This budget holds several
    /// sheets rather than dozens, and lives on its own instance.
    private static let dedicatedCacheCostLimit = 80 * 1024 * 1024

    let itemID: String
    let info: TrickplayInfo
    let imageURLBuilder: ImageURLBuilder
    /// A dedicated instance rather than `RemoteImageLoader.shared`, for the
    /// reason `dedicatedCacheCostLimit` gives. Constructed fresh per provider,
    /// so it and its cache are scoped to one player session rather than
    /// lingering under the shared cache's LRU policy. Injectable for tests.
    var imageLoader: RemoteImageLoader = RemoteImageLoader(totalCostLimit: TrickplayThumbnailProvider.dedicatedCacheCostLimit)

    func thumbnail(atSeconds seconds: Double) async -> CGImage? {
        guard let frame = TrickplayMath.frame(atSeconds: seconds, info: info),
              let url = imageURLBuilder.trickplayTileURL(itemID: itemID, width: info.width, sheetIndex: frame.sheetIndex),
              let sheet = try? await imageLoader.image(for: url),
              let cropped = sheet.cgImage?.cropping(to: frame.tileRect)
        else { return nil }
        return cropped
    }
}
