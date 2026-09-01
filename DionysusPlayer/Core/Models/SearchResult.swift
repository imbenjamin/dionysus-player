import Foundation

/// One row in `SearchView`'s results list — mapped from Jellyfin's
/// `SearchHint`, the sole data source `SearchViewModel` uses (there's no
/// separate full-`BaseItemDto` results grid; `/Search/Hints` is fast enough
/// to serve as the results themselves, not just a typeahead dropdown).
/// Kept intentionally thin: just enough to render a row and navigate to the
/// item's detail page on tap, which fetches everything else itself (see
/// `AppRoute.assetDetail`'s doc comment on `preloadedItem`).
///
/// `Codable` so `SearchHistoryStore` can persist one directly as a history
/// entry — a "recent search" is stored as the actual item the user
/// selected, not just the query text, so a history row can reuse this same
/// type/row view and navigate straight back to that item.
///
/// Deliberately holds `imageReference` (the raw item id/type/tag), not a
/// resolved `URL` — `ImageURLBuilder.url(...)` embeds the *current* access
/// token in the query string, and a token rotates on every fresh sign-in.
/// A resolved URL persisted to disk today would have a dead token baked
/// into it after the next sign-in, 401/403-ing forever and burning several
/// wasted retries per entry on every history render (`RemoteImageLoader`
/// retries transient/5xx failures with backoff). `imageURL(images:)`
/// resolves fresh at render time instead, using whichever `ImageURLBuilder`
/// is live right now — the same "never cache a resolved, token-bearing URL"
/// approach the rest of the app already follows (`MediaItem` never persists
/// one either).
struct SearchResult: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    /// e.g. "2019" for a Movie/Series, "S1:E4 · The Wire" for an Episode
    /// (either half omitted if that data isn't present), "Collection" for
    /// a BoxSet (its own name usually doesn't make the type obvious the
    /// way a year or episode number does for the others), or `nil` when
    /// there's nothing worth showing.
    var subtitle: String?
    var imageReference: ImageReference?
    /// Drives `SearchResultRow`'s placeholder glyph while its thumbnail is
    /// loading or has failed. Optional, not a non-optional with a default
    /// value — `SearchResult` is `Codable` and persisted to disk via
    /// `SearchHistoryStore`, and Swift's synthesized `Decodable` only
    /// treats a missing key as "use the default" for `Optional` properties;
    /// a non-optional property with a default value still throws on a
    /// missing key. An optional lets history entries persisted before this
    /// field existed decode as `nil` (falling back to a generic glyph)
    /// instead of failing to decode at all.
    var kind: BaseItemKind?

    /// The stable pieces needed to (re)build a poster/thumbnail URL — an
    /// item id, image type, and tag, none of which expire the way an
    /// access token does.
    struct ImageReference: Hashable, Codable {
        var itemID: String
        var type: String
        var tag: String
    }

    init(hint: SearchHint) {
        id = hint.id
        name = hint.name
        kind = hint.type

        switch hint.type {
        case .episode:
            // "S1:E4", same format as MediaItem.episodeLabel, omitted
            // entirely (not just half-filled) if either number is missing
            // — Jellyfin doesn't always have both for every episode (e.g.
            // specials).
            let episodeLabel: String? = {
                guard let season = hint.parentIndexNumber, let episode = hint.indexNumber else { return nil }
                return "S\(season):E\(episode)"
            }()
            let parts = [episodeLabel, hint.series].compactMap { $0 }
            subtitle = parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
        case .movie, .series:
            subtitle = hint.productionYear.map(String.init)
        case .boxSet:
            subtitle = String(localized: "Collection")
        default:
            subtitle = nil
        }

        if let tag = hint.thumbImageTag, let itemID = hint.thumbImageItemId {
            imageReference = ImageReference(itemID: itemID, type: "Thumb", tag: tag)
        } else if let tag = hint.primaryImageTag {
            imageReference = ImageReference(itemID: hint.id, type: "Primary", tag: tag)
        } else {
            imageReference = nil
        }
    }

    /// Resolves `imageReference` into a real URL against `images` — call
    /// with whatever `ImageURLBuilder` is current at render time (never
    /// store the result).
    func imageURL(images: ImageURLBuilder) -> URL? {
        guard let ref = imageReference else { return nil }
        return images.url(itemID: ref.itemID, imageType: ref.type, tag: ref.tag, maxWidth: 200)
    }
}
