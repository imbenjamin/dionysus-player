import Foundation

/// A titled row of items on the Home screen (e.g. "Continue Watching",
/// "Recently Added Movies").
///
/// Rail *selection* — which collections/queries actually populate the home
/// screen — is deliberately minimal for now; the set of rails is expected
/// to be redefined later.
struct MediaCollectionRail: Identifiable {
    var id: String { title }
    var title: String
    var items: [MediaItem]
    /// When set, the rail shows a "See All" link pushing a `CollectionGridView`
    /// scoped to this query.
    var seeAllQuery: CollectionQuery? = nil

    /// Whole-rail tile style, consulted by `MediaRailView`: landscape
    /// (`LandscapeMediaCard`) if *any* item is series/episode-like
    /// (`MediaItem.usesLandscapeRailTile`), portrait (`PosterCard`) only
    /// when every item is movie-like. Deliberately a per-*rail* decision,
    /// not per-item — "Continue Watching" can genuinely mix a movie and an
    /// in-progress episode, and that read far worse as a jumble of two
    /// tile shapes side by side than as one consistent shape throughout.
    /// Landscape is the one that degrades gracefully onto content it
    /// wasn't designed for (a movie's landscape tile just crops its poster
    /// to fill the frame, via `LandscapeMediaCard`'s fallback), which is
    /// why a mix leans landscape rather than portrait.
    var usesLandscapeTiles: Bool {
        items.contains(where: \.usesLandscapeRailTile)
    }
}
