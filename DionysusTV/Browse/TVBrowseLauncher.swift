import SwiftUI

/// A plain vertical stack of `HomeViewModel`'s rails, enough to reach playback
/// from the remote. Milestone 3 replaces it with the prototype's Home.
struct TVBrowseLauncher: View {
    let client: JellyfinAPIClient
    let userID: String
    @State private var viewModel: HomeViewModel
    /// Rail and item together: the same item can sit in two rails (a
    /// part-watched movie in Continue Watching and Recently Added).
    @FocusState private var focusedTileKey: String?
    @State private var userMovedFocus = false

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
        _viewModel = State(initialValue: HomeViewModel(client: client, userID: userID))
    }

    var body: some View {
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
        }
        .task { await viewModel.loadIfNeeded() }
        // The sidebar takes the first focus pass, before any rail exists, so
        // focus moves to the first tile when it arrives, as the Apple TV app
        // opens in its content. Not once the user has moved it themselves.
        .onChange(of: firstTileKey, initial: true) { _, firstKey in
            guard !userMovedFocus, focusedTileKey == nil, let firstKey else { return }
            focusedTileKey = firstKey
        }
        .onMoveCommand { _ in userMovedFocus = true }
    }

    private var firstTileKey: String? {
        guard let rail = viewModel.rails.first, let item = rail.items.first else { return nil }
        return Self.focusKey(rail: rail.id, item: item.id)
    }

    private static func focusKey(rail: UUID, item: String) -> String { "\(rail.uuidString)/\(item)" }

    private func tile(_ item: MediaItem, focusKey: String) -> some View {
        Button {
            TVPlayerPresenter.present(item: item, client: client, userID: userID)
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
