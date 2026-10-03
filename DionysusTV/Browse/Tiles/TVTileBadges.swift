import SwiftUI

/// Tile sizes from the prototype's `tv.css` (`.poster`, `.poster-s`, `.land`,
/// `.land-s`).
enum TVTileMetrics {
    static let poster = CGSize(width: 250, height: 375)
    /// Six to a row in a collection grid.
    static let gridPoster = CGSize(width: 240, height: 360)
    static let landscape = CGSize(width: 500, height: 281)
    static let episode = CGSize(width: 440, height: 248)
}

enum TVTileCaption {
    case always
    /// Posters on Home and in grids: the caption appears under the focused
    /// tile only, as the prototype's `hide-cap`.
    case onFocus
    case none
}

/// iOS's corner badges over a tile's artwork: a heart top-left, an eye
/// top-right, a progress bar along the bottom while part-watched. Never a
/// tick for watched.
struct TVTileBadges: View {
    let badges: WatchBadges

    /// What the badges say, for VoiceOver: they are drawn, not read.
    static func spokenValue(for item: MediaItem) -> String {
        let badges = WatchBadges(item: item)
        return [
            badges.showsWatched ? String(localized: "Watched") : nil,
            badges.showsFavorite ? String(localized: "Favorite") : nil
        ].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        ZStack {
            if badges.showsFavorite {
                Image(systemName: "heart.circle.fill")
                    .foregroundStyle(Color.white, Color.dionysusFavorite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if badges.showsWatched {
                Image(systemName: "eye.circle.fill")
                    .foregroundStyle(Color.white, Color.dionysusWatched)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let progress = badges.progress {
                ProgressView(value: progress)
                    .tint(.dionysusHighlight)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .font(.system(size: 34))
        .padding(12)
        .accessibilityHidden(true)
    }
}
