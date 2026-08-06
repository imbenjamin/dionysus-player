import SwiftUI

/// Home is a single scrolling page of rails: a full-bleed hero banner, the
/// user's libraries (replacing the old top-menu category picker), then
/// Continue Watching / Recently Added Movies / Recently Added Shows.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: HomeViewModel?

    var body: some View {
        ScrollView {
            content
        }
        // Lets `HeroRailView` bleed up under the status bar/notch at rest —
        // a `ScrollView` clips its content to its own bounds, so a child
        // declaring `.ignoresSafeArea` on itself has nothing to bleed into
        // unless the `ScrollView` containing it extends there too (same
        // mechanism `MovieDetailView`/`ShowDetailView` use for their own
        // hero header, just without their compensating top padding, since
        // here the bleed is the whole point rather than something to avoid
        // at rest).
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task { await setUpIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel?.loadState ?? .loading {
        case .idle, .loading:
            LoadingView().frame(height: 300)
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await viewModel?.load() }
            }
            .frame(height: 300)
        case .loaded:
            let heroItems = viewModel?.heroItems ?? []
            let libraries = viewModel?.libraries ?? []
            let rails = viewModel?.rails ?? []
            if heroItems.isEmpty && libraries.isEmpty && rails.isEmpty {
                ErrorStateView(message: "Nothing here yet.", retry: nil)
                    .frame(height: 200)
            } else {
                // `LazyVStack`, not `VStack` — with dynamic genre/studio
                // rails potentially pushing the rail count well past the
                // curated set, this avoids constructing every rail's view
                // hierarchy up front, and gives the trailing sentinel below
                // a natural "about to scroll into view" trigger point.
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !heroItems.isEmpty {
                        HeroRailView(items: heroItems)
                    }
                    if !libraries.isEmpty {
                        LibraryRailView(libraries: libraries)
                    }
                    ForEach(rails) { rail in
                        MediaRailView(rail: rail)
                    }

                    if viewModel?.isLoadingMoreDynamicRails == true {
                        LoadingView().frame(height: 150)
                    }

                    // Near-invisible trigger for the next batch of dynamic
                    // rails — `.onAppear` fires once this scrolls near the
                    // bottom of the visible area, before the user actually
                    // reaches the true end of the content, which is what
                    // makes it read as "more rails just keep appearing"
                    // rather than a hard stop-and-wait. Only present while
                    // `hasMoreDynamicRails` is true, so it can't keep
                    // re-triggering once genres/studios are exhausted.
                    if viewModel?.hasMoreDynamicRails == true {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await viewModel?.loadMoreDynamicRails() }
                            }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func setUpIfNeeded() async {
        guard viewModel == nil, let client = appState.apiClient, let userID = appState.currentUser?.id else { return }
        let newViewModel = HomeViewModel(client: client, userID: userID)
        viewModel = newViewModel
        await newViewModel.loadIfNeeded()
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environment(AppState())
}
