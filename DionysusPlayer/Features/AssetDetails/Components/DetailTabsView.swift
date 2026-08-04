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
                TechnicalDetailsView(details: item.technicalDetails)
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
