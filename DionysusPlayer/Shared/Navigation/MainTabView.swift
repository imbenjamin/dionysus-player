import SwiftUI

/// The signed-in app's root: bottom tab bar for Home, Search, and Profile,
/// each with its own navigation stack.
struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack {
                SearchView()
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack {
                ProfileView()
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
