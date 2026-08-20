import SwiftUI
import UIKit

/// Which tab is showing. Tracked explicitly (rather than leaving `TabView`
/// to manage selection internally, unobserved) purely so `selectedTabBinding`
/// below can tell a re-tap of the already-selected Search tab apart from
/// switching into Search from elsewhere — see its doc comment.
private enum MainTab: Hashable {
    case home
    case search
    case downloads
    case profile
}

/// The signed-in app's root: bottom tab bar for Home, Search, and Profile,
/// each with its own navigation stack.
struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var profileTabIcon: UIImage?
    /// Bound (rather than the plain declarative `NavigationLink(value:)` the
    /// other two tabs use) so `SearchView` can push a result from inside a
    /// `Button` action — the same closure that records it to search
    /// history, guaranteeing both happen together. A `NavigationLink` +
    /// `.simultaneousGesture` combo was tried first and is a known-flaky
    /// pattern for a `List` row (the row's own tap handling can swallow the
    /// simultaneous gesture), which is exactly what caused history to never
    /// actually record.
    @State private var searchPath: [AppRoute] = []
    @State private var selectedTab: MainTab = .home
    /// Bumped whenever the user re-taps the Search tab while already on
    /// it — `SearchView` observes this (as a plain `let`, not a binding;
    /// it only ever needs to react, never write it) to clear its query and
    /// pop back to its landing page. Re-tapping while on a *different* tab
    /// doesn't touch this, so switching back into Search from elsewhere
    /// leaves it exactly as it was.
    @State private var searchResetToken = 0

    /// A hand-rolled `Binding` rather than `$selectedTab` directly: a plain
    /// `@State`-derived binding short-circuits when `TabView` "sets" it to
    /// the value it already holds (which is exactly what happens on a
    /// reselect tap — the tab doesn't change), so `.onChange(of:
    /// selectedTab)` alone could never distinguish a reselect from nothing
    /// happening at all. A hand-rolled `Binding`'s `set` closure has no
    /// such short-circuit — `TabView` calls it on *every* tap regardless of
    /// whether the value differs, which is what makes catching a same-tab
    /// reselect possible here.
    private var selectedTabBinding: Binding<MainTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .search, selectedTab == .search {
                    searchResetToken += 1
                }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
            NavigationStack {
                HomeView()
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .tabItem { Label("Home", image: "DionysusGlyph") }
            .tag(MainTab.home)

            NavigationStack(path: $searchPath) {
                SearchView(path: $searchPath, resetToken: searchResetToken)
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(MainTab.search)

            NavigationStack {
                DownloadsView()
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            // Not "arrow.down.circle" — iOS's tab bar already draws its own
            // filled pill/circle behind the *selected* tab's icon (confirmed
            // live, iOS 26), and a symbol that has its own circular border
            // merges visually with that into what reads as one solid disc
            // rather than a distinct glyph inside a highlight, unlike the
            // other tabs here (Home's custom asset, Search's plain
            // "magnifyingglass", Profile's circular photo) which don't have
            // that same double-circle problem. "square.and.arrow.down.on.square"
            // is square, not circular, so it doesn't hit that issue.
            .tabItem { Label("Downloads", systemImage: "square.and.arrow.down.on.square") }
            .tag(MainTab.downloads)

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
            .tag(MainTab.profile)
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
