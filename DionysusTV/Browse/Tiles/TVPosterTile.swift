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
            .accessibilityIdentifier(identifier)

            if caption != .none {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.railTitle).font(.caption.weight(.semibold)).lineLimit(1)
                    if let subtitle = item.railSubtitle {
                        Text(verbatim: subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: size.width, alignment: .leading)
                .opacity(caption == .always || isFocused ? 1 : 0)
                .accessibilityHidden(true)
            }
        }
    }
}
