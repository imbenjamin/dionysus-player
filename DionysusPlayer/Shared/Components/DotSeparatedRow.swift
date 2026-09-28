import SwiftUI

/// A horizontal row of metadata with a " · " between each item that is
/// actually present, so an optional item (no age rating, no community rating)
/// never leaves a stray separator behind.
///
/// Used by the first line of `InfoMetadataRow` and
/// `DownloadedInfoMetadataRow`, whose second line was already dot-separated
/// ("SD · CC · 26.3 MB") while the first was separated by spacing alone
/// ("1 Oct 2003   9m"). The dots are hidden from VoiceOver; each item carries
/// its own label.
struct DotSeparatedRow<Content: View>: View {
    @ViewBuilder var content: Content

    /// About a space's width either side of the dot, so it matches the badges
    /// line's `" · "` string.
    var body: some View {
        HStack(spacing: 4) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 {
                        Text(verbatim: "\u{00B7}")
                            .accessibilityHidden(true)
                    }
                    subview
                }
            }
        }
    }
}
