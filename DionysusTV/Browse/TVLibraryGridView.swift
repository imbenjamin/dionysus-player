import SwiftUI

/// A library, or a See All query, as a poster grid on the shared
/// `CollectionGridViewModel`. Every tile opens its detail page. The
/// prototype's facets and alphabet jump bar replace this in M3's grid PR.
struct TVLibraryGridView: View {
    let title: String
    let titleIdentifier: String
    /// Owned by the shell, so the grid's items outlive its views, which are
    /// torn down whenever another page is chosen or the player covers them.
    let viewModel: CollectionGridViewModel
    /// The tile that last had focus, kept by the shell: back from the player,
    /// focus lands on what was played.
    @Binding var rememberedItemID: String?
    @FocusState private var focusedItemID: String?

    @Environment(\.tvOpenRoute) private var open

    var body: some View {
        TVPageScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text(verbatim: title)
                        .font(.title2.bold())
                        .accessibilityIdentifier(titleIdentifier)
                    // As many 250pt columns as fit right of the rail.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 48, alignment: .leading)], alignment: .leading, spacing: 60) {
                        ForEach(viewModel.items) { item in
                            Button {
                                open(.assetDetail(itemID: item.id, preloadedItem: item))
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
