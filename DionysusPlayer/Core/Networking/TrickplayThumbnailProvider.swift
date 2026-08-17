import CoreGraphics
import Foundation

/// Pure seconds → (sheet index, tile rect) lookup for a Jellyfin trickplay
/// track — no I/O, testable offline (same "kept separate and pure so the
/// gate is testable" shape AetherEngine's own `MasterFallbackDecision`
/// uses).
enum TrickplayMath {
    struct Frame: Equatable {
        let sheetIndex: Int
        /// Pixel rect within that sheet — origin top-left, matching how
        /// `CGImage.cropping(to:)` and Jellyfin's own row-major tile layout
        /// both address a sheet.
        let tileRect: CGRect
    }

    /// `nil` for a degenerate `info` (any non-positive field) — shouldn't
    /// happen against a real server, but a corrupt/partial response
    /// shouldn't be trusted to index into anything.
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

    /// Picks which resolution to use when a server offers more than one —
    /// the smallest width that's still `>= preferredWidth`, falling back to
    /// the largest available if none clears that bar. `nil` when this
    /// media source has no trickplay track at all (older/un-scanned
    /// content, or `mediaSourceID` not present as a key — e.g. a stale
    /// preference for a version the server no longer has).
    static func bestInfo(
        from trickplay: [String: [String: TrickplayInfo]]?, mediaSourceID: String?, preferredWidth: Int = 320
    ) -> TrickplayInfo? {
        guard let mediaSourceID, let widths = trickplay?[mediaSourceID], !widths.isEmpty else { return nil }
        let sorted = widths.values.sorted { $0.width < $1.width }
        return sorted.first { $0.width >= preferredWidth } ?? sorted.last
    }
}

/// Fetches + crops a single trickplay tile for a scrub position — the
/// Jellyfin-provided replacement for AetherEngine's cache-backed scrub
/// stills, which turned out to only serve a narrow window of already-
/// decoded segments near the current playhead (confirmed live 2026-08-17:
/// every request during a real scrub-bar drag missed, since a drag is
/// aimed at a position the user hasn't watched yet). Trickplay tile sheets
/// are pre-generated server-side and span the item's entire duration,
/// which is what a scrubber-drag preview actually needs.
///
/// One sheet JPEG covers `tileWidth * tileHeight` stills (100 for a 10×10
/// sheet spanning ~1000s at a 10s interval), so repeated calls within the
/// same sheet after the first are a synchronous crop — `RemoteImageLoader`
/// caches the whole sheet by URL, no repeat fetch.
struct TrickplayThumbnailProvider {
    let itemID: String
    let info: TrickplayInfo
    let imageURLBuilder: ImageURLBuilder
    /// Injectable for tests (a `MockURLProtocol`-backed instance); defaults
    /// to the app-wide singleton every other image fetch in the app uses.
    var imageLoader: RemoteImageLoader = .shared

    func thumbnail(atSeconds seconds: Double) async -> CGImage? {
        guard let frame = TrickplayMath.frame(atSeconds: seconds, info: info),
              let url = imageURLBuilder.trickplayTileURL(itemID: itemID, width: info.width, sheetIndex: frame.sheetIndex),
              let sheet = try? await imageLoader.image(for: url),
              let cropped = sheet.cgImage?.cropping(to: frame.tileRect)
        else { return nil }
        return cropped
    }
}
