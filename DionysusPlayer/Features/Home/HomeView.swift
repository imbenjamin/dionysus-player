import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: HomeViewModel?
    @State private var selectedCategory: HomeCategory = .movies

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TopMenuBar(selection: $selectedCategory)
                    .padding(.horizontal)
                    .padding(.top, 8)

                content
            }
            .padding(.bottom, 24)
        }
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
            let visibleRails = (viewModel?.rails ?? []).filter { $0.category == nil || $0.category == selectedCategory }
            if visibleRails.isEmpty {
                ErrorStateView(message: "Nothing here yet.", retry: nil)
                    .frame(height: 200)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(visibleRails) { homeRail in
                        MediaRailView(rail: homeRail.rail)
                    }
                }
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
