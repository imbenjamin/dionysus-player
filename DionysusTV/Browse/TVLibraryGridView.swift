import SwiftUI

/// One library as a poster grid, on the shared `CollectionGridViewModel` with
/// the query iOS's library rail uses. A top-level page of the shell, like
/// Home, with the rail beside it. Movies and episodes play on Select; a
/// series, season or collection needs a detail page, which is Milestone 3, so
/// selecting one does nothing yet. Milestone 3 also brings the prototype's
/// facets and alphabet jump bar.
struct TVLibraryGridView: View {
    let client: JellyfinAPIClient
    let userID: String
    let library: MediaItem
    /// Owned by the shell, so the grid's items outlive its views, which are
    /// torn down whenever another page is chosen or the player covers them.
    let viewModel: CollectionGridViewModel
    /// The tile that last had focus, kept by the shell: back from the player,
    /// focus lands on what was played.
    @Binding var rememberedItemID: String?
    @FocusState private var focusedItemID: String?

    init(client: JellyfinAPIClient, userID: String, library: MediaItem, viewModel: CollectionGridViewModel, rememberedItemID: Binding<String?>) {
        self.client = client
        self.userID = userID
        self.library = library
        self.viewModel = viewModel
        _rememberedItemID = rememberedItemID
    }

    private static let playableKinds: Set<BaseItemKind> = [.movie, .episode]

    var body: some View {
        TVPageScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text(verbatim: library.name)
                        .font(.title2.bold())
                        .accessibilityIdentifier(A11yID.TV.Library.title(library.id))
                    // As many 250pt columns as fit right of the rail.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 48, alignment: .leading)], alignment: .leading, spacing: 60) {
                        ForEach(viewModel.items) { item in
                            Button {
                                guard Self.playableKinds.contains(item.kind) else { return }
                                TVPlayerPresenter.present(item: item, client: client, userID: userID)
                            } label: {
                                AsyncRemoteImage(url: item.primaryImageURL, placeholderSystemImage: item.kind.placeholderSystemImage)
                                    .frame(width: 250, height: 375)
                            }
                            .buttonStyle(.card)
                            .focused($focusedItemID, equals: item.id)
                            .accessibilityLabel(item.railTitle)
                            .accessibilityIdentifier(A11yID.TV.Library.tile(item.id))
                        }
                    }
                }
                .padding(.vertical, 60)
                .padding(.trailing, 80)
            }
            .scrollClipDisabled()
        }
        .task { await viewModel.loadIfNeeded() }
        .tvClaimsFocus($focusedItemID, ids: viewModel.items.map(\.id), remembered: $rememberedItemID)
    }
}
