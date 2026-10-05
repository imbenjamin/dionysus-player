import SwiftUI

/// A 16:9 tile with its caption always shown: Continue Watching, Next Up,
/// episodes and playlist rows. The caller supplies the caption, since an
/// episode reads differently on Home ("Pioneer One" / "S1:E3 · Alone in the
/// Night") and on its show's page ("3. Alone in the Night" / "S1:E3 · 31 min").
struct TVLandscapeTile: View {
    let item: MediaItem
    var size: CGSize = TVTileMetrics.landscape
    let title: String
    let subtitle: String?
    let identifier: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: action) {
                AsyncRemoteImage(
                    url: item.thumbImageURL ?? item.primaryImageURL,
                    placeholderSystemImage: item.kind.placeholderSystemImage
                )
                .frame(width: size.width, height: size.height)
                .overlay { TVEpisodeLogoOverlay(item: item, tileSize: size) }
                .overlay { TVTileBadges(badges: WatchBadges(item: item)) }
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityValue(TVTileBadges.spokenValue(for: item))
            .accessibilityIdentifier(identifier)

            TVTileCaptionText(title: title, subtitle: subtitle, artSize: size, isFocused: isFocused)
        }
    }
}
