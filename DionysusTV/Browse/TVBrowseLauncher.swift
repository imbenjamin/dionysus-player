import SwiftUI

/// A plain vertical stack of `HomeViewModel`'s rails, enough to reach playback
/// from the remote. Milestone 3 replaces it with the prototype's Home.
struct TVBrowseLauncher: View {
    let client: JellyfinAPIClient
    let userID: String
    @State private var viewModel: HomeViewModel

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
                                    tile(item)
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
    }

    private func tile(_ item: MediaItem) -> some View {
        Button {
            TVPlayerPresenter.present(item: item, client: client, userID: userID)
        } label: {
            AsyncRemoteImage(url: item.primaryImageURL, placeholderSystemImage: item.kind.placeholderSystemImage)
                .frame(width: 250, height: 375)
        }
        .buttonStyle(.card)
        .accessibilityLabel(item.railTitle)
        .accessibilityIdentifier(A11yID.TV.Main.tile(item.id))
    }
}

/// Stand-in until the player host lands (Task 6), which replaces it.
enum TVPlayerPresenter {
    static func present(item: MediaItem, client: JellyfinAPIClient, userID: String) {}
}
