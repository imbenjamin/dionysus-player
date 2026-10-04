import SwiftUI

/// A portrait tile: artwork in a card button, badges over it, and a caption
/// beneath. Selecting one always opens something (a detail page, a grid),
/// never playback.
struct TVPosterTile: View {
    let item: MediaItem
    var size: CGSize = TVTileMetrics.poster
    var caption: TVTileCaption = .onFocus
    let identifier: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: action) {
                AsyncRemoteImage(url: item.primaryImageURL, placeholderSystemImage: item.kind.placeholderSystemImage)
                    .frame(width: size.width, height: size.height)
                    .overlay { TVTileBadges(badges: WatchBadges(item: item)) }
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityValue(TVTileBadges.spokenValue(for: item))
            .accessibilityIdentifier(identifier)

            if caption != .none {
                TVTileCaptionText(title: item.railTitle, subtitle: item.railSubtitle, artSize: size, isFocused: isFocused)
                    .opacity(caption == .always || isFocused ? 1 : 0)
            }
        }
    }
}
