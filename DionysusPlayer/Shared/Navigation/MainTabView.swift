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
    /// Bound (unlike before) so `HomeView` can observe it to detect the
    /// user popping back to Home's own root — see `HomeView`'s `path`
    /// property and its `.onChange` for why that triggers a soft refresh.
    @State private var homePath: [AppRoute] = []
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
            NavigationStack(path: $homePath) {
                // `isActiveTab` lets `HeroRailView`'s auto-advance timer
                // stop doing real work while another tab is showing,
                // instead of ticking once a second for the app's entire
                // lifetime regardless — see `HomeView.isActiveTab`'s doc
                // comment. `path` is bound (rather than left implicit, as
                // this used to be) so `HomeView` can observe pops back to
                // its own root — see `HomeView.path`'s doc comment.
                HomeView(isActiveTab: selectedTab == .home, path: $homePath)
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
            // Not "arrow.down.circle" — iOS's tab bar draws its own filled
            // pill/circle behind the selected tab's icon, and a symbol
            // with its own circular border merges visually with that into
            // one solid disc rather than a distinct glyph inside a
            // highlight. "square.and.arrow.down.on.square" is square, so
            // it doesn't hit that issue.
            .tabItem { Label("Downloads", systemImage: "square.and.arrow.down.on.square") }
            .tag(MainTab.downloads)
            // Small pending/downloading count — `0` hides the badge
            // entirely (SwiftUI's own behavior for `.badge(Int)`), so
            // there's nothing to gate here beyond reading the live count.
            .badge(appState.downloadManager.pendingOrActiveDownloadsCount)

            // The only tab not wrapped in a `NavigationStack` here:
            // `ProfileView` owns its own container because that container
            // differs by device — a `NavigationSplitView` on iPad, a
            // `NavigationStack` elsewhere — and a split view nested
            // inside a stack isn't a supported arrangement. It applies
            // the same `.navigationDestination(for: AppRoute.self)` in
            // both of its layouts, so nothing is lost here.
            ProfileView()
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
                // The visible label is deliberately the signed-in user's
                // own name (a personal touch, not a generic tab title —
                // see this tab's own icon fetch above), but that reads as
                // just a name to VoiceOver with no indication of what the
                // tab actually is. Override with what the tab does, not
                // who's using it.
                .accessibilityLabel(String(localized: "Profile & Settings"))
            }
            .tag(MainTab.profile)
        }
        // Selected-item tint tracks the brand primary (burgundy in light,
        // amber in dark). Without this, the tab bar inherits the app-wide
        // `AccentColor` asset, which is a static burgundy and doesn't adapt
        // to theme changes.
        .tint(Color.dionysusPrimary)
        .task(id: appState.currentUser?.id) { await loadProfileTabIcon() }
        // Cold launch can reach `.main` with `currentUser` still `nil` —
        // resumed from a cached session because the server was
        // unreachable at launch (see `AppState.start()`). The Profile tab
        // already tolerates that (falls back to a generic label/icon), but
        // once real connectivity returns, quietly upgrade to a real sign-in
        // so the tab picks up the user's actual name/avatar without them
        // having to do anything — same "catch the reconnect transition"
        // idea as `HomeView`'s dynamic-rail retry.
        .onChange(of: ConnectivityMonitor.shared.isOffline) { wasOffline, isOffline in
            guard wasOffline, !isOffline, appState.currentUser == nil,
                  let credentials = appState.sessionStore.credentials else { return }
            Task { try? await appState.signIn(username: credentials.username, password: credentials.password ?? "") }
        }
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
            // `RemoteImageLoader.shared`, not a hand-rolled
            // `URLSession.shared` fetch (this used to be one) — this
            // avatar gets the same retry-with-backoff and shared in-memory
            // cache as every other image in the app for essentially free,
            // rather than silently going permanently blank on a single
            // transient failure with nothing else in the app any wiser.
            let raw = try await RemoteImageLoader.shared.image(for: url)
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
