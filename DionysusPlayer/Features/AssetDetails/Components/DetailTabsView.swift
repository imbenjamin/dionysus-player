import SwiftUI

/// The tabbed content below the Play/Resume row on both detail layouts:
/// genres/synopsis, cast & crew, and technical media details. A segmented
/// `Picker` rather than a `TabView`, which wants a defined size rather than
/// sizing to its content and so fights the outer `ScrollView`.
struct DetailTabsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case about = "About"
        case cast = "Cast & Crew"
        case details = "Details"
        var id: String { rawValue }
    }

    let item: MediaItem
    @State private var selectedTab: Tab = .about

    /// "About" always shows, applying to every item kind. "Cast & Crew" shows
    /// only once `item.cast` has something, so an uncredited item doesn't get a
    /// tab reading "No cast or crew information available." "Details" shows only
    /// for a playable asset with its own media file: a Show, Season or Collection
    /// always has `item.technicalDetails == nil`.
    ///
    /// `AssetDetailViewModel`'s preloaded item renders this view before `cast` or
    /// `technicalDetails` exist — both come from the same full-item fetch — so
    /// this starts as just "About" and grows once `load()` lands. That growth
    /// relies on `MediaItem.==` being structural; an id-only comparison leaves it
    /// frozen at "About".
    private var availableTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .about: true
            case .cast: !item.cast.isEmpty
            case .details: item.technicalDetails != nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // With only "About" available, the segmented control would be a single
            // dead-looking segment, so it's dropped rather than shown with one
            // option.
            if availableTabs.count > 1 {
                Picker("Section", selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.dionysusPrimary)
            }

            switch selectedTab {
            case .about:
                AboutTabContent(item: item)
            case .cast:
                CastCrewGridView(cast: item.cast)
            case .details:
                TechnicalDetailsView(item: item)
            }
        }
    }
}

/// Genres, then studios, then the tagline, then the synopsis. Studios are
/// unlabeled like genres: `MediaItem.studios` backs both a movie's studio and a
/// show's network (see `CollectionGridView`'s Studio/Network filter), so no single
/// label fits both.
///
/// The tagline is a larger italicized subheader in full-contrast text, bigger
/// than the subheadline genre and studio lines above and the synopsis below: it's
/// the page's one marketing-voice line and should stand out rather than read as
/// metadata or prose.
private struct AboutTabContent: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !item.genres.isEmpty {
                MetadataLine(items: item.genres, accessibilityPrefix: String(localized: "Genres"))
            }

            if !item.studios.isEmpty {
                MetadataLine(items: item.studios, accessibilityPrefix: String(localized: "Studios"))
            }

            if let tagline = item.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.title3.italic())
                    .foregroundStyle(.primary)
                    .accessibilityLabel(String(localized: "Tagline: \(tagline)"))
            }

            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .accessibilityLabel(String(localized: "Synopsis: \(overview)"))
            } else {
                Text("No synopsis available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Synopsis: No synopsis available."))
            }
        }
    }
}

/// A genre or studio metadata line: one line, no wrap, so a long \u{00B7}-joined
/// list scrolls horizontally rather than eating vertical space. `.fixedSize` is
/// what makes that work — without it `Text` sizes to the `ScrollView` viewport
/// and wraps inside it, as if the `ScrollView` weren't there; with it, `Text`
/// lays out at its full unwrapped width, giving the `ScrollView` something wider
/// than its viewport to scroll.
///
/// Not `private`: `DownloadedDetailTabsView`'s About tab reuses it for the same
/// lines, sourced from `DownloadedItemMetadata`.
struct MetadataLine: View {
    let items: [String]
    /// Read by VoiceOver as "Genres: Horror, Comedy" rather than the unlabeled
    /// \u{00B7}-joined visible text, which reads as a list with no indication of
    /// what it lists. A middle dot isn't spoken punctuation, so the accessibility
    /// join uses a comma rather than `text`'s separator.
    let accessibilityPrefix: String

    private var text: String { items.joined(separator: " \u{00B7} ") }

    /// Width of the trailing fade; see `body`.
    private let fadeWidth: CGFloat = 20

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(accessibilityPrefix): \(items.joined(separator: ", "))"))
        // A fixed-width fade at the trailing edge, hinting there's more to scroll
        // rather than letting a long line look cut off. Not conditioned on whether
        // `text` overflows: the mask is sized against this view's container width,
        // not the rendered text, so for a short line the fade zone falls past the
        // text over blank space with no visible effect. `.leading`/`.trailing`,
        // not `.left`/`.right`, so the fade sits at the line's end in both LTR and
        // RTL.
        .mask(
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
            }
        )
    }
}
