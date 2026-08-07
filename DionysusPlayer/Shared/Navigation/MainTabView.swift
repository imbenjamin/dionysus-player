import SwiftUI
import UIKit

/// The signed-in app's root: bottom tab bar for Home, Search, and Profile,
/// each with its own navigation stack.
struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var profileTabIcon: UIImage?

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .tabItem { Label("Home", image: "DionysusGlyph") }

            NavigationStack {
                SearchView()
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack {
                ProfileView()
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .tabItem {
                Label {
                    Text(appState.currentUser?.name ?? String(localized: "Profile"))
                } icon: {
                    if let profileTabIcon {
                        Image(uiImage: profileTabIcon)
                    } else {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        }
        // Selected-item tint tracks the brand primary (burgundy in light,
        // amber in dark). Without this, the tab bar inherits the app-wide
        // `AccentColor` asset, which is a static burgundy and doesn't adapt
        // to theme changes.
        .tint(Color.dionysusPrimary)
        .task(id: appState.currentUser?.id) { await loadProfileTabIcon() }
    }

    private func loadProfileTabIcon() async {
        guard let user = appState.currentUser,
              let tag = user.primaryImageTag,
              let client = appState.apiClient else {
            profileTabIcon = nil
            return
        }
        let builder = await client.makeImageURLBuilder()
        guard let url = builder.userImageURL(userID: user.id, tag: tag, maxWidth: 96) else {
            profileTabIcon = nil
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let raw = UIImage(data: data) else {
                profileTabIcon = nil
                return
            }
            profileTabIcon = raw.circularTabIcon()
        } catch {
            profileTabIcon = nil
        }
    }
}

private extension UIImage {
    /// Renders this image as a circular tab-bar icon.
    ///
    /// The result is marked `.alwaysOriginal` so UIKit doesn't tint it with the
    /// tab bar's tint color — a profile photo should show its actual colours,
    /// not a monochrome silhouette. Sized to the standard 25pt tab icon.
    func circularTabIcon(size: CGFloat = 25) -> UIImage {
        let dimension = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: dimension)
        let rendered = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: dimension)
            UIBezierPath(ovalIn: rect).addClip()
            draw(in: rect)
        }
        return rendered.withRenderingMode(.alwaysOriginal)
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
