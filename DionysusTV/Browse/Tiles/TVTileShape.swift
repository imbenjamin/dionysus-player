import SwiftUI

/// The one tile shape a rail or grid uses, decided as iOS does
/// (`MediaCollectionRail.usesLandscapeTiles`; Benjamin, 2026-10-05): posters
/// when every item is movie-like, landscape thumbs when any is a show or an
/// episode. Per rail, never per item, so a mix (Continue Watching) reads as
/// one shape; landscape is the one that degrades well, a movie's thumb or its
/// poster cropped to fill.
enum TVTileShape: Equatable {
    case poster
    case landscape

    init(items: [MediaItem]) {
        self = items.contains(where: \.usesLandscapeRailTile) ? .landscape : .poster
    }

    init(results: [SearchResult]) {
        self = results.contains(where: \.isLandscapeShaped) ? .landscape : .poster
    }

    /// A rail tile's artwork.
    var railSize: CGSize { self == .poster ? TVTileMetrics.poster : TVTileMetrics.landscape }

    /// A grid tile's artwork: six posters to a row, or four thumbs.
    var gridSize: CGSize { self == .poster ? TVTileMetrics.gridPoster : TVTileMetrics.gridLandscape }
    var gridColumns: Int { self == .poster ? 6 : 4 }
}

/// A tile in the shape its rail or grid chose (`TVTileShape`): a poster, or a
/// landscape thumb captioned with the item's rail title and subtitle.
struct TVShapedTile: View {
    let item: MediaItem
    let shape: TVTileShape
    var posterSize: CGSize = TVTileMetrics.poster
    var landscapeSize: CGSize = TVTileMetrics.landscape
    var posterCaption: TVTileCaption = .always
    let identifier: String
    let action: () -> Void

    var body: some View {
        switch shape {
        case .poster:
            TVPosterTile(item: item, size: posterSize, caption: posterCaption, identifier: identifier, action: action)
        case .landscape:
            TVLandscapeTile(
                item: item, size: landscapeSize,
                title: item.railTitle, subtitle: item.railSubtitle,
                identifier: identifier, action: action
            )
        }
    }
}

/// The show's logo an episode tile carries bottom-left, as iOS's
/// `episodeLogoOverlay` does (Benjamin, 2026-10-05): an episode's still says
/// nothing of which show it is. Only episodes, and only when Jellyfin names a
/// logo up the chain (season, then series); no text stands in, since the
/// caption already names it.
enum TVEpisodeLogo {
    static func url(for item: MediaItem) -> URL? {
        item.kind == .episode ? item.logoImageURL : nil
    }
}

/// iOS's `episodeLogoOverlay` at Apple TV size: a bottom gradient for
/// contrast with the show's logo bottom-left over it, raised clear of the
/// progress bar while the episode is part-watched. Nothing for any other
/// tile, or an episode with no logo up the chain.
struct TVEpisodeLogoOverlay: View {
    let item: MediaItem
    let tileSize: CGSize

    var body: some View {
        if let url = TVEpisodeLogo.url(for: item) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                LogoImageView(url: url, fallback: EmptyView())
                    .frame(maxWidth: tileSize.width * 0.4, maxHeight: tileSize.height * 0.22, alignment: .bottomLeading)
                    .padding(.leading, 18)
                    .padding(.bottom, WatchBadges(item: item).progress == nil ? 16 : 34)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
