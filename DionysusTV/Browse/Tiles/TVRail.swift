import SwiftUI

/// A titled horizontal rail. The row is a focus section, so Down from
/// anything above lands in it even where no tile sits directly below.
struct TVRail<Content: View>: View {
    let title: String
    var titleIdentifier: String?
    var groupIdentifier: String?
    /// Every tile built at once, for a rail that scrolls under the sidebar
    /// (Home): lazily, a tile scrolled past the row's leading edge, under the
    /// sidebar, was torn down once scrolling stopped. The row itself keeps
    /// its bounds, so tvOS still keeps the focused tile clear of the
    /// sidebar: widened to the screen's edge, focus scrolled under it.
    var buildsEveryTile = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier ?? "")
            ScrollView(.horizontal) {
                Group {
                    if buildsEveryTile {
                        HStack(alignment: .top, spacing: 48) { content }
                    } else {
                        LazyHStack(alignment: .top, spacing: 48) { content }
                    }
                }
                .padding(.vertical, 30)
                .padding(.trailing, 80)
            }
            .scrollClipDisabled()
            .focusSection()
        }
        // One container named for the heading, so VoiceOver says it as focus
        // enters the rail; a heading beside the row wasn't read (M5).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityIdentifier(groupIdentifier ?? "")
    }
}
