import SwiftUI

/// A plain vertical stack of `HomeViewModel`'s rails; each tile opens its
/// detail page. Milestone 3 replaces it with the prototype's Home.
struct TVBrowseLauncher: View {
    let client: JellyfinAPIClient
    let userID: String
    /// Owned by the shell, so Home's data outlives its views: Home is torn
    /// down whenever another page is chosen or the player covers the shell.
    let viewModel: HomeViewModel
    /// The tile that last had focus, kept by the shell, so a rebuilt Home
    /// (back from the player, say) puts focus back where it was.
    @Binding var rememberedTileKey: String?
    /// Rail and item together: the same item can sit in two rails (a
    /// part-watched movie in Continue Watching and Recently Added).
    @FocusState private var focusedTileKey: String?
    @Environment(\.tvOpenRoute) private var open

    init(client: JellyfinAPIClient, userID: String, viewModel: HomeViewModel, rememberedTileKey: Binding<String?>) {
        self.client = client
        self.userID = userID
        self.viewModel = viewModel
        _rememberedTileKey = rememberedTileKey
    }

    var body: some View {
        TVPageScaffold {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 50) {
                    ForEach(Array(viewModel.rails.enumerated()), id: \.element.id) { index, rail in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(rail.title).font(.headline)
                                .accessibilityIdentifier(index == 0 ? A11yID.TV.Main.root : "")
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 48) {
                                    ForEach(rail.items) { item in
                                        tile(item, focusKey: Self.focusKey(rail: rail.id, item: item.id))
                                    }
                                }
                                .padding(.vertical, 30)
                            }
                            .scrollClipDisabled()
                        }
                        .focusSection()
                    }
                }
                .padding(.vertical, 60)
            }
            .scrollClipDisabled()
        }
        .task { await viewModel.loadIfNeeded() }
        .tvClaimsFocus($focusedTileKey, ids: tileKeys, remembered: $rememberedTileKey)
    }

    /// Every tile, top rail first, left to right.
    private var tileKeys: [String] {
        viewModel.rails.flatMap { rail in rail.items.map { Self.focusKey(rail: rail.id, item: $0.id) } }
    }

    private static func focusKey(rail: UUID, item: String) -> String { "\(rail.uuidString)/\(item)" }

    private func tile(_ item: MediaItem, focusKey: String) -> some View {
        Button {
            open(.assetDetail(itemID: item.id, preloadedItem: item))
        } label: {
            AsyncRemoteImage(url: item.primaryImageURL, placeholderSystemImage: item.kind.placeholderSystemImage)
                .frame(width: 250, height: 375)
        }
        .buttonStyle(.card)
        .focused($focusedTileKey, equals: focusKey)
        .accessibilityLabel(item.railTitle)
        .accessibilityIdentifier(A11yID.TV.Main.tile(item.id))
    }
}
