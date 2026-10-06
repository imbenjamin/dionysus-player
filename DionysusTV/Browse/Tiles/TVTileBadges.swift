import SwiftUI

/// Tile sizes from the prototype's `tv.css` (`.poster`, `.poster-s`, `.land`,
/// `.land-s`).
enum TVTileMetrics {
    static let poster = CGSize(width: 250, height: 375)
    /// Six to a row in a collection grid.
    static let gridPoster = CGSize(width: 240, height: 360)
    /// Four to a row in a grid of landscape thumbs, across the six posters'
    /// width: (6 × 240 + 5 × 44 − 3 × 44) / 4, at 16:9.
    static let gridLandscape = CGSize(width: 382, height: 215)
    /// Four to a rail beside the sidebar (Benjamin, 2026-10-06; 500pt showed
    /// three): 200 + 4 × 370 + 3 × 48 = 1824, inside the 80pt safe area on the
    /// right with room for the fourth's focus lift, at 16:9.
    static let landscape = CGSize(width: 370, height: 208)
    static let episode = CGSize(width: 440, height: 248)

    /// How much `.card` grows a focused tile's artwork (measured on the
    /// Simulator: a 375pt poster's bottom edge drops 19pt).
    static let cardLiftScale: CGFloat = 1.1

    /// How far a caption moves down while its tile has focus, so it stays
    /// clear of the lifted artwork: half the growth, the bottom edge's share
    /// (the prototype's `.capt` moves 18pt under a poster).
    static func captionLift(for size: CGSize) -> CGFloat {
        size.height * (cardLiftScale - 1) / 2
    }
}

/// A tile's caption: semibold title over a secondary subtitle, one line
/// each, moving down with the artwork's lift while the tile has focus
/// (Benjamin, 2026-10-04: left where it was, the lifted poster ran over it).
struct TVTileCaptionText: View {
    let title: String
    let subtitle: String?
    let artSize: CGSize
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption.weight(.semibold)).lineLimit(1)
            if let subtitle {
                Text(verbatim: subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: artSize.width, alignment: .leading)
        .offset(y: isFocused ? TVTileMetrics.captionLift(for: artSize) : 0)
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .accessibilityHidden(true)
    }
}

enum TVTileCaption {
    /// Always shown, Home's posters included (Benjamin, 2026-10-05: the
    /// prototype's focus-only `hide-cap` left Home's movie tiles unnamed).
    case always
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
