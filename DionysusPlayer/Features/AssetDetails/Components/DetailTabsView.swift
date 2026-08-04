import SwiftUI

/// The tabbed content shown below the Play/Resume row on both detail page
/// layouts (`MovieDetailView`/`ShowDetailView`): synopsis, cast & crew, and
/// technical media details. A segmented `Picker` rather than a `TabView` —
/// this sits inside an outer `ScrollView`, and `TabView` wants a defined
/// size of its own rather than sizing to its content, which fights an outer
/// scroll view; swapping which plain content view is shown avoids that.
struct DetailTabsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case info = "Info"
        case cast = "Cast & Crew"
        case details = "Details"
        var id: String { rawValue }
    }

    let item: MediaItem
    @State private var selectedTab: Tab = .info

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Section", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .tint(.dionysusPrimary)

            switch selectedTab {
            case .info:
                SynopsisView(overview: item.overview)
            case .cast:
                CastCrewGridView(cast: item.cast)
            case .details:
                TechnicalDetailsView(details: item.technicalDetails)
            }
        }
    }
}

private struct SynopsisView: View {
    let overview: String?

    var body: some View {
        if let overview, !overview.isEmpty {
            Text(overview)
                .font(.body)
        } else {
            Text("No synopsis available.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
