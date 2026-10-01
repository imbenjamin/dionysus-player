import SwiftUI

/// The system search layout (keyboard across the top) over a poster grid, on
/// the shared `SearchViewModel`. Lists only what plays directly (movies and
/// episodes): a series or a
/// collection needs a detail page to choose from, which is a later milestone.
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
    @Environment(\.tvFocusHandoff) private var focusHandoff
    @Environment(\.tvPageClaimedFocus) private var claimedFocus

    init(client: JellyfinAPIClient, userID: String, viewModel: SearchViewModel, rememberedResultID: Binding<String?>) {
        self.client = client
        self.userID = userID
        self.viewModel = viewModel
        _rememberedResultID = rememberedResultID
    }

    private static let playableKinds: Set<BaseItemKind> = [.movie, .episode]

    private var playableResults: [SearchResult] {
        viewModel.results.filter { $0.kind.map(Self.playableKinds.contains) ?? false }
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
            if let rememberedResultID, playableResults.contains(where: { $0.id == rememberedResultID }) {
                focusedResultID = rememberedResultID
            }
            releaseRail()
        }
        .onChange(of: focusHandoff) { releaseRail() }
        .onChange(of: focusedResultID) { _, id in
            if let id { rememberedResultID = id }
        }
    }

    /// Lets the shell enable the rail once the keyboard has had its chance at
    /// focus, which it takes as soon as the page is laid out.
    private func releaseRail() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            claimedFocus()
        }
    }

    private var results: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 48, alignment: .leading)], alignment: .leading, spacing: 60) {
                ForEach(playableResults) { result in
                    VStack(spacing: 16) {
                        Button {
                            viewModel.recordSelection(result)
                            TVPlayerPresenter.present(itemID: result.id, client: client, userID: userID)
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
