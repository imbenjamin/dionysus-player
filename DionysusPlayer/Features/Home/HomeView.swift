import SwiftUI

/// Home is a single scrolling page of rails: a full-bleed hero banner, the
/// user's libraries (replacing the old top-menu category picker), then
/// Continue Watching / Recently Added Movies / Recently Added Shows.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: HomeViewModel?

    var body: some View {
        ScrollView {
            // `VStack`, not just `content` directly — the bottom marker
            // (see below) has to sit *outside* `content`'s `LazyVStack`,
            // as a sibling rather than one of its children, or its
            // `GeometryReader`'s preference value never propagates out to
            // `onPreferenceChange` below at all. This is a known SwiftUI
            // limitation: `LazyVStack`/`List` use specialized internal
            // rendering for their lazy children that doesn't reliably
            // participate in the normal bottom-up preference-aggregation
            // tree the way a plain `VStack`'s children do — confirmed here
            // by temporary debug logging showing the preference value never
            // leaving its default even once `content` had fully loaded and
            // the marker's `if` condition was true, regardless of whether
            // the marker was a background on the whole `LazyVStack` or one
            // of its own children.
            VStack(spacing: 0) {
                content

                if viewModel?.hasMoreDynamicRails == true {
                    Color.clear
                        .frame(height: 1)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BottomMarkerOffsetKey.self,
                                    value: proxy.frame(in: .named("homeScroll")).minY
                                )
                            }
                        }
                }
            }
        }
        .coordinateSpace(name: "homeScroll")
        // Loads more dynamic rails once the bottom marker above comes
        // within one screen height of the visible viewport — i.e. tracks
        // real scroll position, not any rail's own appear/disappear
        // lifecycle. Two earlier versions of this used per-row `.onAppear`
        // (a thin `Color.clear` sentinel, then the last real rail card
        // itself) and both proved unreliable in practice: inside a
        // `LazyVStack`, `.onAppear` only fires once per genuine
        // appear/disappear cycle, and whether a given row actually got
        // that cycle at the right moment turned out to depend on
        // `LazyVStack`'s own buffering in ways that weren't consistent.
        .onPreferenceChange(BottomMarkerOffsetKey.self) { markerY in
            guard markerY < screenHeight * 2, viewModel?.hasMoreDynamicRails == true else { return }
            Task { await viewModel?.loadMoreDynamicRails() }
        }
        // Lets `HeroRailView` bleed up under the status bar/notch at rest —
        // a `ScrollView` clips its content to its own bounds, so a child
        // declaring `.ignoresSafeArea` on itself has nothing to bleed into
        // unless the `ScrollView` containing it extends there too (same
        // mechanism `MovieDetailView`/`ShowDetailView` use for their own
        // hero header, just without their compensating top padding, since
        // here the bleed is the whole point rather than something to avoid
        // at rest).
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task { await setUpIfNeeded() }
    }

    /// Deliberately the key window's own bounds, not `UIScreen.main` (soft
    /// deprecated, and doesn't reflect a resized scene under iPadOS Stage
    /// Manager) — same reasoning as `HeroRailView.screenHeight`/
    /// `HeroHeaderView.statusBarInset`. Only used here as a rough "how close
    /// to the bottom counts as near" threshold, so the same approximation
    /// those views already rely on is more than precise enough.
    private var screenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)?
            .bounds.height ?? 800
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel?.loadState ?? .loading {
        case .idle, .loading:
            LoadingView().frame(height: 300)
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await viewModel?.load() }
            }
            .frame(height: 300)
        case .loaded:
            let heroItems = viewModel?.heroItems ?? []
            let libraries = viewModel?.libraries ?? []
            let rails = viewModel?.rails ?? []
            if heroItems.isEmpty && libraries.isEmpty && rails.isEmpty {
                ErrorStateView(message: "Nothing here yet.", retry: nil)
                    .frame(height: 200)
            } else {
                // `LazyVStack`, not `VStack` — with dynamic rails
                // potentially pushing the rail count well past the curated
                // set, this avoids constructing every rail's view hierarchy
                // up front.
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !heroItems.isEmpty {
                        HeroRailView(items: heroItems)
                    }
                    if !libraries.isEmpty {
                        LibraryRailView(libraries: libraries)
                    }
                    ForEach(rails) { rail in
                        MediaRailView(rail: rail)
                    }

                    if viewModel?.isLoadingMoreDynamicRails == true {
                        LoadingView().frame(height: 150)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func setUpIfNeeded() async {
        guard viewModel == nil, let client = appState.apiClient, let userID = appState.currentUser?.id else { return }
        let newViewModel = HomeViewModel(client: client, userID: userID)
        viewModel = newViewModel
        await newViewModel.loadIfNeeded()
    }
}

/// The bottom marker's own top-edge Y position within `HomeView`'s
/// "homeScroll" coordinate space — see `HomeView.body`'s
/// `onPreferenceChange` for why this drives dynamic-rail lazy loading.
/// Standard "last write wins" reduction: there's only ever one publisher
/// (the marker's own `GeometryReader`), so `nextValue()` always simply
/// replaces `value`.
private struct BottomMarkerOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environment(AppState())
}
