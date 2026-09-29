import SwiftUI

/// The signed-in shell: tvOS 26's sidebar, with Home and Search. A minimal
/// first version, enough to reach any title; the designed sidebar (the user's
/// avatar, Settings) is a later milestone.
struct TVMainView: View {
    let client: JellyfinAPIClient
    let userID: String

    private enum TabID: Hashable { case home, search }
    @State private var selection: TabID = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: TabID.home) {
                TVBrowseLauncher(client: client, userID: userID)
            }
            Tab("Search", systemImage: "magnifyingglass", value: TabID.search) {
                TVSearchView(client: client, userID: userID)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
