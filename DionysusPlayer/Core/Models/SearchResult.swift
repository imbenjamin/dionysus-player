import Foundation

/// One row in `SearchView`'s results, mapped from Jellyfin's `SearchHint`.
/// `/Search/Hints` is fast enough to serve as the results themselves rather than
/// a typeahead dropdown, so there is no full-`BaseItemDto` grid behind it. Thin
/// by design: enough to render a row and navigate to the detail page, which
/// fetches the rest itself.
///
/// `Codable` so `SearchHistoryStore` can persist one as a history entry — a
/// recent search stores the item the user selected, not the query text, letting
/// a history row reuse this type and navigate straight back.
///
/// Holds raw image references rather than resolved URLs.
/// `ImageURLBuilder.url(...)` embeds the current access token, which rotates on
/// every sign-in, so a persisted URL would carry a dead token and 401 forever —
/// burning `RemoteImageLoader`'s retry budget on every history render.
/// `imageURL(images:)` resolves fresh at render time instead.
struct SearchResult: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    /// "2019" for a Movie or Series, "S1:E4 · The Wire" for an Episode with
    /// either half omitted when absent, or "Collection" for a BoxSet, whose name
    /// rarely makes its type obvious. `nil` when there is nothing to show.
    var subtitle: String?
    /// Poster ("Primary") and still ("Thumb") references, both kept rather than
    /// collapsed at init: a `SearchHint` can carry either regardless of kind —
    /// a movie can have a `ThumbImageTag` — and which one a render wants depends
    /// on where it renders. The `.compact` list wants each item's natural-kind
    /// image; the `.regular` grid wants whichever matches the grid's single
    /// shape decision. See `imageURL(images:preferLandscape:)`.
    var primaryImageReference: ImageReference?
    var thumbImageReference: ImageReference?
    /// Drives `SearchResultRow`'s placeholder glyph. `Optional` rather than
    /// defaulted: this type is persisted by `SearchHistoryStore`, and a
    /// synthesized `Decodable` throws on a missing key for a non-optional even
    /// with a default, so entries written before this field existed would fail
    /// to decode instead of falling back to a generic glyph.
    var kind: BaseItemKind?

    /// Migrates a history entry written under the pre-split schema, which had a
    /// single `imageReference` key; without this every on-disk entry would
    /// silently lose its thumbnail. Routes the legacy value into whichever new
    /// field matches its own `type`.
    private enum LegacyCodingKeys: String, CodingKey {
        case imageReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        kind = try container.decodeIfPresent(BaseItemKind.self, forKey: .kind)
        primaryImageReference = try container.decodeIfPresent(ImageReference.self, forKey: .primaryImageReference)
        thumbImageReference = try container.decodeIfPresent(ImageReference.self, forKey: .thumbImageReference)

        if primaryImageReference == nil, thumbImageReference == nil {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let legacy = try legacyContainer.decodeIfPresent(ImageReference.self, forKey: .imageReference) {
                if legacy.type == "Thumb" {
                    thumbImageReference = legacy
                } else {
                    primaryImageReference = legacy
                }
            }
        }
    }

    /// The stable pieces needed to rebuild an image URL: item id, type and tag,
    /// none of which expire the way an access token does.
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
            // "S1:E4", as in `MediaItem.episodeLabel`. Omitted entirely rather
            // than half-filled when either number is missing, as for specials.
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

        primaryImageReference = hint.primaryImageTag.map { ImageReference(itemID: hint.id, type: "Primary", tag: $0) }
        // `thumbImageItemId` can differ from `hint.id` for an episode, since
        // Jellyfin backfills a missing episode thumb with its series' own. This
        // may therefore resolve to the show's title card rather than a
        // per-episode still — `/Search/Hints`' documented behaviour, accepted.
        thumbImageReference = {
            guard let tag = hint.thumbImageTag, let itemID = hint.thumbImageItemId else { return nil }
            return ImageReference(itemID: itemID, type: "Thumb", tag: tag)
        }()
    }

    /// Whether this counts as episode- or series-like for a landscape-versus-
    /// portrait shape decision, mirroring `MediaCollectionRail.usesLandscapeTiles`.
    ///
    /// Prefers `kind`, falling back to `subtitle`'s shape when it is `nil` —
    /// which long-lived history entries written before that field existed still
    /// are, and a bare `kind == .episode` check would silently vote portrait for
    /// a whole mixed list. Only the `.episode` subtitle joins two parts with
    /// `" · "`; a bare year or `"Collection"` never contains that separator, so
    /// it stands in reliably.
    var isLandscapeShaped: Bool {
        if let kind { return kind == .episode || kind == .series }
        return subtitle?.contains(" \u{00B7} ") == true
    }

    /// The image a `.compact`-list row wants: each item's natural-kind
    /// preference, so episodes and series favour `Thumb` as
    /// `LandscapeMediaCard` does and everything else favours `Primary`. Call
    /// with the current `ImageURLBuilder` and never store the result.
    func imageURL(images: ImageURLBuilder) -> URL? {
        imageURL(images: images, preferLandscape: isLandscapeShaped)
    }

    /// The image a `.regular`-grid tile wants. `preferLandscape` is the grid's
    /// single shape decision for every tile, following
    /// `MediaCollectionRail.usesLandscapeTiles`' whole-rail rule, not this
    /// item's own kind. A movie in an episode-heavy landscape grid uses its own
    /// `Thumb` if it has one, else `Primary` cropped to fill rather than no
    /// image; the reverse for an episode in a portrait grid.
    func imageURL(images: ImageURLBuilder, preferLandscape: Bool) -> URL? {
        let ref = preferLandscape
            ? (thumbImageReference ?? primaryImageReference)
            : (primaryImageReference ?? thumbImageReference)
        guard let ref else { return nil }
        return images.url(itemID: ref.itemID, imageType: ref.type, tag: ref.tag, maxWidth: 200)
    }

    /// `MediaItem.accessibilityDescription`'s `"name, subtitle"` composition, for
    /// `SearchResultGridCard`'s explicit label. `SearchResultRow` predates that
    /// pattern and doesn't use this.
    var accessibilityDescription: String {
        guard let subtitle else { return name }
        return "\(name), \(subtitle)"
    }
}
