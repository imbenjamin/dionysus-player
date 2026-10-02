import SwiftUI

/// The system search layout (keyboard across the top) over a poster grid, on
/// the shared `SearchViewModel`. Every result opens its detail page.
struct TVSearchView: View {
    let client: JellyfinAPIClient
    let userID: String
    /// Owned by the shell, so the query and results outlive Search's views,
    /// which are torn down whenever another page is chosen or the player covers them.
    let viewModel: SearchViewModel
    /// The result that last had focus, kept by the shell, so a rebuilt Search
    /// (back from the player) puts focus back on it.
    @Binding var rememberedResultID: String?
    @FocusState private var focusedResultID: String?
    @Environment(\.tvOpenRoute) private var open
    @Environment(\.tvPageIsOnShow) private var isOnShow
    @State private var restoring = false
    @Environment(\.tvFocusHandoff) private var focusHandoff
    @Environment(\.tvPageClaimedFocus) private var claimedFocus

    init(client: JellyfinAPIClient, userID: String, viewModel: SearchViewModel, rememberedResultID: Binding<String?>) {
        self.client = client
        self.userID = userID
        self.viewModel = viewModel
        _rememberedResultID = rememberedResultID
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        TVPageScaffold {
            // `.searchable` draws its field only inside a navigation container.
            NavigationStack {
                results
                    .searchable(text: $viewModel.query)
            }
        }
        .onChange(of: viewModel.query) { viewModel.queryChanged() }
        .task(id: viewModel.results.count) { await viewModel.loadImagesIfNeeded() }
        // Search's default focus is the system keyboard, a UIKit control no
        // SwiftUI focus target reaches: with the rail held disabled, tvOS puts
        // focus there itself. Only a remembered result is claimed here.
        .onAppear {
            if let rememberedResultID, viewModel.results.contains(where: { $0.id == rememberedResultID }) {
                focusedResultID = rememberedResultID
            }
            releaseRail()
        }
        .onChange(of: focusHandoff) { releaseRail() }
        // Back on show after a detail page is popped: tvOS puts focus on the
        // keyboard as the page is enabled again, so the result is claimed
        // until it holds (as `tvClaimsFocus` does for other pages).
        .onChange(of: isOnShow) { _, onShow in
            guard onShow, let target = rememberedResultID, viewModel.results.contains(where: { $0.id == target }) else { return }
            restoring = true
            Task { @MainActor in
                for _ in 0..<10 {
                    focusedResultID = target
                    try? await Task.sleep(for: .milliseconds(50))
                    if focusedResultID == target { break }
                }
                restoring = false
                claimedFocus()
            }
        }
        .onChange(of: focusedResultID) { _, id in
            if let id, isOnShow, !restoring { rememberedResultID = id }
        }
    }

    /// Lets the shell enable the rail once the keyboard has had its chance at
    /// focus, which it takes as soon as the page is laid out.
    private func releaseRail() {
        guard isOnShow else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            claimedFocus()
        }
    }

    private var results: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 48, alignment: .leading)], alignment: .leading, spacing: 60) {
                ForEach(viewModel.results) { result in
                    VStack(spacing: 16) {
                        Button {
                            viewModel.recordSelection(result)
                            open(.assetDetail(itemID: result.id))
                        } label: {
                            AsyncRemoteImage(
                                url: viewModel.imageURL(for: result),
                                placeholderSystemImage: result.kind?.placeholderSystemImage ?? "film"
                            )
                            .frame(width: 250, height: 375)
                        }
                        .buttonStyle(.card)
                        .focused($focusedResultID, equals: result.id)
                        .accessibilityLabel(result.name)
                        .accessibilityIdentifier(A11yID.TV.Search.result(result.id))

                        Text(result.name)
                            .font(.caption)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.vertical, 60)
            .padding(.trailing, 80)
        }
        .scrollClipDisabled()
    }
}
