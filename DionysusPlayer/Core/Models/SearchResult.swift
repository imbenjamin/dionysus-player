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
    /// e.g. "2019" for a Movie/Series, the parent series' name for an
    /// Episode, or `nil` when there's nothing worth showing.
    var subtitle: String?
    var imageReference: ImageReference?

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

        switch hint.type {
        case .episode:
            subtitle = hint.series
        case .movie, .series:
            subtitle = hint.productionYear.map(String.init)
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
