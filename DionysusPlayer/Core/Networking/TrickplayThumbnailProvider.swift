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

    /// How many tile-sheet JPEGs a trickplay track is split across — every
    /// sheet fully packed (`tileWidth × tileHeight` stills) except possibly
    /// the last. The live scrub path never needs this (it fetches sheets
    /// on demand as `frame(atSeconds:info:)` names them), but an offline
    /// download has to fetch every sheet up front — see
    /// `DownloadManager.enqueue`'s trickplay section. `0` for the same
    /// degenerate-`info` cases `frame(atSeconds:info:)` itself guards
    /// against.
    static func sheetCount(for info: TrickplayInfo) -> Int {
        let perSheet = info.tileWidth * info.tileHeight
        guard perSheet > 0, info.thumbnailCount > 0 else { return 0 }
        return (info.thumbnailCount + perSheet - 1) / perSheet
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

/// Abstraction over "get me a scrub-preview still for this second" —
/// `TrickplayThumbnailProvider` below (fetches tile sheets over the
/// network) and `OfflineTrickplayThumbnailProvider` (reads sheets already
/// on disk from an offline download) share identical seconds→sheet/tile
/// math (`TrickplayMath`) and differ only in where the sheet bytes come
/// from. `PlayerViewModel.trickplayProvider` is typed against this so
/// `start()`/`startOffline()` can each install whichever conformer applies
/// without the rest of the view model (`supportsScrubThumbnails`,
/// `scrubThumbnail(atSeconds:)`) needing to branch on which. The
/// requirement itself is `@MainActor` — both conformers' `thumbnail(
/// atSeconds:)` is only ever called from `PlayerViewModel` (itself
/// `@MainActor`), and isolating just this method keeps every call a
/// same-actor hop rather than tripping Swift's "sending a non-`Sendable`
/// existential" check on a bare, unisolated `async` requirement.
/// Deliberately *not* `@MainActor` on the protocol itself — that would
/// infer the same isolation onto every conformer's own initializer too
/// (Swift's global-actor-inference-from-conformance rule), which would
/// make `TrickplayThumbnailProvider.init` MainActor-only and break its
/// existing off-actor test construction for no reason this actually needs.
protocol ScrubThumbnailProviding {
    @MainActor func thumbnail(atSeconds seconds: Double) async -> CGImage?
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
struct TrickplayThumbnailProvider: ScrubThumbnailProviding {
    /// A tile sheet decodes to roughly `bytesPerRow × height` in memory —
    /// for the 3200×1800 sheets confirmed live against a real server
    /// (10×10 grid of 320×180 tiles), that's ~23MB *each*, versus
    /// `RemoteImageLoader.defaultTotalCostLimit`'s 150MB shared budget for
    /// every poster/backdrop/logo app-wide. A scrub session touching just a
    /// handful of sheets could otherwise fill that whole shared cache on
    /// its own and evict images the rest of the app depends on for instant
    /// redisplay — confirmed by reading `RemoteImageLoader
    /// .estimatedByteCost(of:)`, which costs by decoded size, not file
    /// size. This budget is deliberately smaller (room for several sheets,
    /// not dozens) and, more importantly, on its own dedicated instance
    /// (see `imageLoader` below) rather than shared at all.
    private static let dedicatedCacheCostLimit = 80 * 1024 * 1024

    let itemID: String
    let info: TrickplayInfo
    let imageURLBuilder: ImageURLBuilder
    /// A dedicated instance, not `RemoteImageLoader.shared` — see
    /// `dedicatedCacheCostLimit`'s doc comment for why sharing the app-wide
    /// poster/backdrop cache is the wrong call for these unusually large
    /// images. Constructed fresh (this is a `var` property default,
    /// re-evaluated per instance) each time `PlayerViewModel.start()`
    /// builds a provider, so it — and whatever it's cached — is scoped to
    /// and released with that player session, rather than lingering under
    /// the shared cache's LRU policy after the player closes. Injectable
    /// for tests (a `MockURLProtocol`-backed instance).
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
