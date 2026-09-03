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
    /// Poster-shaped ("Primary") and still-shaped ("Thumb") image
    /// references, kept *both* rather than collapsing to one at init time
    /// — a `SearchHint` can carry either regardless of item kind (a movie
    /// can have a `ThumbImageTag` too; confirmed against Jellyfin's actual
    /// `SearchHint.cs`), and which one a given render actually wants
    /// depends on *where* it's rendering, not just the item's own kind:
    /// `SearchResultRow` (the `.compact` list) wants each item's own
    /// natural-kind image, but `SearchResultGridCard` (the `.regular` grid)
    /// wants whichever type matches the *grid's* one shape decision for
    /// every tile — including a movie mixed into an otherwise
    /// episode-heavy, landscape-shaped grid. See `imageURL(images:
    /// preferLandscape:)`.
    var primaryImageReference: ImageReference?
    var thumbImageReference: ImageReference?
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

    /// Decodes `primaryImageReference`/`thumbImageReference` as normal, but
    /// also migrates a history entry persisted under the old, pre-split
    /// schema (a single `imageReference` key, before the 2026-09-03 grid
    /// work) — without this, every already-on-disk history entry would
    /// silently lose its thumbnail (both new fields simply absent from that
    /// old JSON) the moment this ships, same class of concern `kind`'s own
    /// doc comment describes. Routes the legacy value into whichever new
    /// field matches its own `type` rather than guessing.
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

        primaryImageReference = hint.primaryImageTag.map { ImageReference(itemID: hint.id, type: "Primary", tag: $0) }
        // `thumbImageItemId` can legitimately differ from `hint.id` for an
        // episode — Jellyfin backfills a missing episode thumb with its
        // series' own (see that property's doc comment) — which means this
        // can resolve to the show's generic title card instead of a real
        // per-episode still when the server has no dedicated one.
        // Deliberately accepted as-is per a direct 2026-09-03 decision:
        // this is `/Search/Hints`' own documented behavior, not a bug to
        // route around.
        thumbImageReference = {
            guard let tag = hint.thumbImageTag, let itemID = hint.thumbImageItemId else { return nil }
            return ImageReference(itemID: itemID, type: "Thumb", tag: tag)
        }()
    }

    /// Resolves whichever image a `.compact`-list row wants: each item's
    /// own natural-kind preference (episode/series favor `Thumb`, matching
    /// `LandscapeMediaCard`'s `thumbImageURL ?? primaryImageURL`;
    /// everything else favors `Primary` alone, matching `PosterCard`) —
    /// call with whatever `ImageURLBuilder` is current at render time
    /// (never store the result; see this type's own doc comment on why).
    func imageURL(images: ImageURLBuilder) -> URL? {
        imageURL(images: images, preferLandscape: kind == .episode || kind == .series)
    }

    /// Resolves whichever image a `.regular`-grid tile wants — `preferLandscape`
    /// is the *grid's* one shape decision for every tile it contains
    /// (`SearchView.grid`'s `isLandscape`, mirroring `MediaCollectionRail
    /// .usesLandscapeTiles`'s "whole rail, not per item" rule), not
    /// necessarily this item's own natural kind. A movie mixed into an
    /// otherwise episode-heavy, landscape-shaped grid gets its own `Thumb`
    /// here if it has one (confirmed live, 2026-09-03: some movies do,
    /// e.g. a backdrop-style crop) — falling back to `Primary` cropped to
    /// fill, same as `LandscapeMediaCard`'s own fallback for exactly this
    /// case, rather than no image at all. Same fallback shape in reverse
    /// for a series/episode forced into a portrait-shaped grid.
    func imageURL(images: ImageURLBuilder, preferLandscape: Bool) -> URL? {
        let ref = preferLandscape
            ? (thumbImageReference ?? primaryImageReference)
            : (primaryImageReference ?? thumbImageReference)
        guard let ref else { return nil }
        return images.url(itemID: ref.itemID, imageType: ref.type, tag: ref.tag, maxWidth: 200)
    }

    /// Same `"name, subtitle"` composition as `MediaItem.accessibilityDescription`
    /// — used by `SearchResultGridCard` (the `.regular`-size-class grid
    /// tile), which follows the same house pattern every other card view
    /// does (`.accessibilityElement(children: .ignore)` + an explicit
    /// label). `SearchResultRow`, the existing `.compact` list row, predates
    /// that pattern and is left as-is here — out of scope for this change.
    var accessibilityDescription: String {
        guard let subtitle else { return name }
        return "\(name), \(subtitle)"
    }
}
