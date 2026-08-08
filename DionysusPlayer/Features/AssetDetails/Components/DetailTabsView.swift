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

    /// A Show or Season has no media file of its own — only its episodes
    /// do — so `item.technicalDetails` is always `nil` for them; only real
    /// playable assets (movies, episodes) have a "Details" tab worth
    /// showing at all.
    ///
    /// `AssetDetailViewModel`'s preloaded item (see its doc comment) renders
    /// this view before `technicalDetails` exists, so this starts as a
    /// 2-element array and grows to 3 once `load()`'s full item lands —
    /// `MovieDetailView`/`ShowDetailView` key `DetailTabsView`'s identity to
    /// this same condition (see their call sites), which is required for
    /// that transition to actually show up. Confirmed via a temporary
    /// runtime probe (prints in this view's `body` and in `MovieDetailView`
    /// 's) that without that `.id()`, `MovieDetailView.body` re-ran a
    /// second time once `load()` landed the full item (it reads the
    /// `@Observable` `viewModel.item` directly, so it's a tracked
    /// dependency) but *this* view's `body` — holding `item` as a plain,
    /// non-`Equatable`, non-tracked `let` under an otherwise-unchanged view
    /// identity (same type/position, `selectedTab`'s `@State` box intact)
    /// — never fired again, so `availableTabs` stayed frozen at whatever it
    /// was the first time this view ever rendered. Forcing a fresh identity
    /// via `.id()` on the change that matters is what actually gets this
    /// view's `body` invoked again; relying on the parent alone re-running
    /// did not, for whatever reason, propagate down to this specific view
    /// in practice.
    private var availableTabs: [Tab] {
        item.technicalDetails == nil ? Tab.allCases.filter { $0 != .details } : Tab.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Section", selection: $selectedTab) {
                ForEach(availableTabs) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .tint(.dionysusPrimary)

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

/// Genres above the synopsis — moved here from `InfoMetadataRow`, which
/// used to show genres inline with year/rating/duration on every page.
private struct AboutTabContent: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !item.genres.isEmpty {
                Text(item.genres.joined(separator: " \u{00B7} "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
            } else {
                Text("No synopsis available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
