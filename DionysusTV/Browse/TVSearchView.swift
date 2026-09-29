import SwiftUI

/// The system search layout (keyboard across the top) over a poster grid, on
/// the shared `SearchViewModel`. Lists only what plays directly (movies and
/// episodes): a series or a
/// collection needs a detail page to choose from, which is a later milestone.
struct TVSearchView: View {
    let client: JellyfinAPIClient
    let userID: String
    @State private var viewModel: SearchViewModel

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
        _viewModel = State(initialValue: SearchViewModel(client: client, userID: userID))
    }

    private static let playableKinds: Set<BaseItemKind> = [.movie, .episode]

    private var playableResults: [SearchResult] {
        viewModel.results.filter { $0.kind.map(Self.playableKinds.contains) ?? false }
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 48), count: 6), spacing: 60) {
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
                        .accessibilityLabel(result.name)
                        .accessibilityIdentifier(A11yID.TV.Search.result(result.id))

                        Text(result.name)
                            .font(.caption)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(60)
        }
        .searchable(text: $viewModel.query)
        .onChange(of: viewModel.query) { viewModel.queryChanged() }
        .task(id: viewModel.results.count) { await viewModel.loadImagesIfNeeded() }
    }
}
