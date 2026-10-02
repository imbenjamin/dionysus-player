import SwiftUI

/// A titled horizontal rail. The row is a focus section, so Down from
/// anything above lands in it even where no tile sits directly below.
struct TVRail<Content: View>: View {
    let title: String
    var titleIdentifier: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier ?? "")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) { content }
                    .padding(.vertical, 30)
                    .padding(.trailing, 80)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }
}
