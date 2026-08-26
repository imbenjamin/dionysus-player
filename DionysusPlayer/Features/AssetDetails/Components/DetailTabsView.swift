import SwiftUI

/// The tabbed content shown below the Play/Resume row on both detail page
/// layouts (`MovieDetailView`/`ShowDetailView`): genres/synopsis, cast &
/// crew, and technical media details. A segmented `Picker` rather than a
/// `TabView` — this sits inside an outer `ScrollView`, and `TabView` wants a
/// defined size of its own rather than sizing to its content, which fights
/// an outer scroll view; swapping which plain content view is shown avoids
/// that.
struct DetailTabsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case about = "About"
        case cast = "Cast & Crew"
        case details = "Details"
        var id: String { rawValue }
    }

    let item: MediaItem
    @State private var selectedTab: Tab = .about

    /// "About" always shows (genres/synopsis apply to every item kind, even
    /// with nothing in either of the other two). "Cast & Crew" only shows
    /// once `item.cast` actually has something in it — a Collection, or any
    /// item nobody bothered crediting, doesn't get a tab that just says "No
    /// cast or crew information available." "Details" only shows for a real
    /// playable asset (movie, episode) with its own media file — a Show,
    /// Season, or Collection has `item.technicalDetails == nil` always,
    /// having no media file of its own (only its children do).
    ///
    /// `AssetDetailViewModel`'s preloaded item (see its doc comment) renders
    /// this view before either `cast` or `technicalDetails` exist — both are
    /// only populated by the same `Fields=People,MediaSources,...` full-item
    /// fetch, so they always arrive together — so this starts as a 1-element
    /// array (just "About") and grows once `load()`'s full item lands.
    /// `MovieDetailView`/`ShowDetailView`/`CollectionDetailView` key
    /// `DetailTabsView`'s identity to `technicalDetails == nil` (see their
    /// call sites), which is required for that transition to actually show
    /// up — since `cast` becomes known at the exact same moment, that one
    /// key covers both. Confirmed via a temporary runtime probe (prints in
    /// this view's `body` and in `MovieDetailView`'s) that without that
    /// `.id()`, `MovieDetailView.body` re-ran a second time once `load()`
    /// landed the full item (it reads the `@Observable` `viewModel.item`
    /// directly, so it's a tracked dependency) but *this* view's `body` —
    /// holding `item` as a plain, non-`Equatable`, non-tracked `let` under
    /// an otherwise-unchanged view identity (same type/position,
    /// `selectedTab`'s `@State` box intact) — never fired again, so
    /// `availableTabs` stayed frozen at whatever it was the first time this
    /// view ever rendered. Forcing a fresh identity via `.id()` on the
    /// change that matters is what actually gets this view's `body` invoked
    /// again; relying on the parent alone re-running did not, for whatever
    /// reason, propagate down to this specific view in practice.
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
            // Nothing to switch between with only "About" available (e.g. a
            // Collection, or any item with neither cast/crew credits nor its
            // own technical details) — the segmented control itself would
            // just be a single dead-looking segment, so it's dropped
            // entirely rather than shown with one option.
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

/// Genres, then studios (unlabeled, same treatment as genres — `MediaItem
/// .studios` is the one field backing both a movie's studio and a show's
/// network, per `CollectionGridView`'s own Studio/Network filter, so no
/// single label here would be right for both), then the marketing tagline
/// (if any), then the synopsis — genres moved here from `InfoMetadataRow`,
/// which used to show them inline with year/rating/duration on every page.
/// The tagline is styled as a larger italicized subheader in full-contrast
/// text — bigger than both the plain-subheadline genre/studio lines above
/// it and the synopsis below, since it's the one marketing-voice line on
/// the page and is meant to stand out at a glance, not read as ordinary
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

/// A genre/studio metadata line's shared presentation: single line, no
/// wrap — a long \u{00B7}-joined list (many genres, several co-production
/// studios) instead scrolls horizontally rather than eating multiple lines
/// of vertical space the way a wrapping `Text` would. `.fixedSize` is what
/// makes that possible: without it, `Text` sizes itself to the `ScrollView`
/// viewport's width and wraps *inside* that, same as if the `ScrollView`
/// weren't there at all; `.fixedSize` lets it instead measure and lay out
/// at its own full unwrapped width, which is what actually gives the
/// `ScrollView` content wider than its viewport to scroll through.
///
/// Not `private` — `DownloadedDetailTabsView`'s own About tab reuses this
/// exact presentation for the same genre/studio lines, sourced from
/// `DownloadedItemMetadata` instead of a live `MediaItem`.
struct MetadataLine: View {
    let items: [String]
    /// Read by VoiceOver as "<accessibilityPrefix>: <item>, <item>, ..." —
    /// e.g. "Genres: Horror, Comedy" — rather than the bare, unlabeled
    /// \u{00B7}-joined visible text. Confirmed live this line otherwise reads
    /// as an ambiguous list with no indication of what kind of list it is.
    /// A middle dot isn't natural spoken punctuation, so the accessibility
    /// join uses a plain comma instead of `text`'s own separator.
    let accessibilityPrefix: String

    private var text: String { items.joined(separator: " \u{00B7} ") }

    /// Width of the trailing fade below — see `body`'s comment.
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
        // A small fixed-width fade at the trailing edge, hinting there's
        // more to scroll to rather than letting a long line just look cut
        // off. Deliberately not conditioned on whether `text` actually
        // overflows — the mask is sized against this view's own (container)
        // width, not `text`'s rendered width, so for a short line that
        // already fits, the fade zone falls entirely past the visible text
        // over blank space and has no visible effect. That's what makes it
        // safe to always apply rather than having to measure first.
        // `.leading`/`.trailing`, not `.left`/`.right`, so the fade sits at
        // the *end* of the line in both LTR and RTL layouts.
        .mask(
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
            }
        )
    }
}
