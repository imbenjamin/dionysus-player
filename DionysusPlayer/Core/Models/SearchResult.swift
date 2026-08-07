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
struct SearchResult: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    /// e.g. "2019" for a Movie/Series, the parent series' name for an
    /// Episode, or `nil` when there's nothing worth showing.
    var subtitle: String?
    var imageURL: URL?

    init(hint: SearchHint, images: ImageURLBuilder) {
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
            imageURL = images.url(itemID: itemID, imageType: "Thumb", tag: tag, maxWidth: 200)
        } else if let tag = hint.primaryImageTag {
            imageURL = images.url(itemID: hint.id, imageType: "Primary", tag: tag, maxWidth: 200)
        } else {
            imageURL = nil
        }
    }
}
