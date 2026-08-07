import SwiftUI
import UIKit

/// Home is a single scrolling page of rails: a full-bleed hero banner, the
/// user's libraries (replacing the old top-menu category picker), then
/// Continue Watching / Recently Added Movies / Recently Added Shows.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: HomeViewModel?

    var body: some View {
        ScrollView {
            content
                // Loads more dynamic rails once the scroll view's own
                // content offset comes within one screen height of the
                // bottom — see `ScrollBottomObserver`'s doc comment for why
                // this is the third design tried here, and what was wrong
                // with each of the first two.
                .background {
                    ScrollBottomObserver {
                        guard viewModel?.hasMoreDynamicRails == true else { return }
                        Task { await viewModel?.loadMoreDynamicRails() }
                    }
                }
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
                ErrorStateView(message: String(localized: "Nothing here yet."), retry: nil)
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
                    // `rails.indices`, not `Array(rails.enumerated())` —
                    // same reasoning as `HeroRailView.loopedItems`'s
                    // `ForEach`: avoids allocating a fresh array of tuples
                    // every time this recomputes.
                    ForEach(rails.indices, id: \.self) { index in
                        MediaRailView(rail: rails[index])
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

/// Calls `onNearBottom` whenever the enclosing `ScrollView`'s own content
/// offset comes within one screen height of its bottom — the mechanism
/// behind Home's "load more dynamic rails as the user scrolls" behavior.
/// Third design tried here, after two others each had a real, confirmed
/// problem:
/// - `GeometryReader`/`PreferenceKey` measuring a synthetic marker view's
///   position in a named coordinate space: correctly tracked real scroll
///   position, but that coordinate-space conversion turned out to scale
///   badly with how much view tree it had to walk through — a live CPU
///   sample during a reported freeze (after scrolling through several dozen
///   loaded-in rails) showed the main thread pegged inside `GeometryReader
///   .Child.updateValue()`, refiring on every scroll frame against an
///   increasingly large tree.
/// - `.onAppear` on the last few rail rows: cheap (no geometry conversion
///   at all), but unreliable — confirmed by reproducing it: scrolling
///   straight to the bottom in one motion sometimes never fired it, though
///   scrolling up a little and back down did. `LazyVStack` doesn't
///   guarantee it materializes (and thus fires `.onAppear` for) every row
///   a fast scroll passes through; a row that's never actually built never
///   gets the callback that would have triggered the load.
///
/// This sidesteps both: reading `UIScrollView.contentOffset` directly (via
/// KVO, not the `.delegate` slot — see `Coordinator.attachIfNeeded()`'s doc
/// comment for why that distinction matters) needs no coordinate-space
/// conversion at all, just a few property reads, so it can't reproduce the
/// first problem; and it observes the *scroll view itself*, not any lazily-
/// rendered child row's lifecycle, so it can't reproduce the second either
/// — the scroll view's own `contentOffset` is authoritative and always
/// up to date regardless of what `LazyVStack` has or hasn't materialized.
private struct ScrollBottomObserver: UIViewRepresentable {
    var onNearBottom: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNearBottom: onNearBottom)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Never itself part of hit-testing — exists only to give the
        // coordinator a starting point to walk up from.
        view.isUserInteractionEnabled = false
        context.coordinator.hostView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onNearBottom = onNearBottom
        context.coordinator.attachIfNeeded()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// `@MainActor`, not left inferred — needed to form a KVO key path to
    /// `UIScrollView.contentOffset`, which this SDK marks
    /// `@MainActor`-isolated; correct anyway, since a `UIScrollView` and
    /// everything else this touches only ever exists/mutates on the main
    /// thread regardless.
    @MainActor
    final class Coordinator: NSObject {
        var onNearBottom: () -> Void
        weak var hostView: UIView?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        init(onNearBottom: @escaping () -> Void) {
            self.onNearBottom = onNearBottom
        }

        /// Finds the enclosing `ScrollView`'s own backing `UIScrollView` —
        /// same "walk up from a `.background` marker until the first
        /// `UIScrollView` ancestor" technique `HeroRailView`'s
        /// `RegionTouchObserver` uses, for the same reason: robust to
        /// SwiftUI changing exactly how many wrapper views it inserts
        /// between them, across versions.
        ///
        /// Observes `contentOffset` via KVO, deliberately *not* by becoming
        /// this scroll view's `UIScrollViewDelegate` — that's a single slot,
        /// and SwiftUI's own `ScrollView` already occupies it internally to
        /// implement its own scrolling/bounce/paging behavior; claiming it
        /// here would silently replace that and break the real `ScrollView`.
        /// KVO observers don't compete for a single slot the way delegates
        /// do, so this coexists with whatever SwiftUI itself is already
        /// observing.
        func attachIfNeeded() {
            guard observation == nil, let scrollView = nearestScrollViewAncestor() else { return }
            self.scrollView = scrollView
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                self?.checkNearBottom(scrollView)
            }
            // Also check once immediately — content shorter than one
            // screen (nothing to scroll at all) would otherwise never
            // trigger a `contentOffset` change to check from.
            checkNearBottom(scrollView)
        }

        private func nearestScrollViewAncestor() -> UIScrollView? {
            var candidate = hostView?.superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView { return scrollView }
                candidate = view.superview
            }
            return nil
        }

        private func checkNearBottom(_ scrollView: UIScrollView) {
            let distanceFromBottom = scrollView.contentSize.height
                - (scrollView.contentOffset.y + scrollView.bounds.height)
            guard distanceFromBottom < scrollView.bounds.height else { return }
            onNearBottom()
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            scrollView = nil
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environment(AppState())
}
