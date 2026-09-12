import SwiftUI
import UIKit

/// Home is a single scrolling page of rails: a full-bleed hero banner, the
/// user's libraries, then Continue Watching / Recently Added Movies /
/// Recently Added Shows.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var viewModel: HomeViewModel?
    /// Whether Home is the selected tab, from `MainTabView`'s `selectedTab`.
    /// Threaded through to `HeroRailView` so its auto-advance timer idles
    /// while Home is off screen, and drives a soft refresh when it flips
    /// `true`. Defaults to `true` for `#Preview` and non-tab callers.
    var isActiveTab: Bool = true
    /// `MainTabView`'s bound path for Home's `NavigationStack` — observed,
    /// never written, to detect a pop back to Home's root, which triggers a
    /// soft refresh.
    var path: Binding<[AppRoute]> = .constant([])

    var body: some View {
        Group {
            if let placeholderState {
                // Outside the `ScrollView`, not inside it at a fixed height,
                // so `OfflineStateView`/`LoadingView`/`ErrorStateView`'s
                // `.frame(maxHeight: .infinity)` centers on the visible screen
                // rather than in a short box at the top of an empty scroll area.
                placeholderView(for: placeholderState)
            } else {
                ScrollView {
                    content
                        // Loads more dynamic rails once the scroll offset comes
                        // within one screen height of the bottom.
                        .background {
                            ScrollBottomObserver {
                                // Both guards checked synchronously here, not left
                                // to `loadMoreDynamicRails()`'s own. This closure
                                // runs on every `contentOffset` KVO tick near the
                                // bottom — many times a second during a scroll — so
                                // without them each tick spawns a `Task` that only
                                // discovers it has nothing to do once it runs.
                                guard viewModel?.hasMoreDynamicRails == true,
                                      viewModel?.isLoadingMoreDynamicRails == false else { return }
                                Task { await viewModel?.loadMoreDynamicRails() }
                            }
                        }
                }
                // Lets `HeroRailView` overflow-paint above its laid-out
                // position instead of being clipped there; the other half is
                // the negative top padding in `content`.
                .scrollClipDisabled()
                // Hard refresh — re-fetches everything. Only mounted once
                // `placeholderState` is `nil`, so it's unreachable during the
                // load/offline/error states, which have nothing to refresh over.
                .refreshable { await viewModel?.hardRefresh() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // VoiceOver users can't reliably perform a pull gesture, so this
            // mirrors `.refreshable` as an explicit button — unmounted rather
            // than hidden, like `PlayerView`'s VoiceOver-only controls button.
            if voiceOverEnabled {
                ToolbarItem(placement: .topBarTrailing) { refreshButton }
            }
        }
        .task { await setUpIfNeeded() }
        // On the back-online transition, retries whatever didn't make it:
        // `retryLoadIfNeeded()` if the primary load never succeeded, then
        // `retryDynamicRailCandidatesIfNeeded()` for the narrower case where
        // curated rails loaded but dynamic rail discovery (silent by design)
        // landed in the reconnect window. Sequenced, since a successful
        // `retryLoadIfNeeded()` already re-ran discovery inside `load()`.
        .onChange(of: ConnectivityMonitor.shared.isOffline) { wasOffline, isOffline in
            guard wasOffline, !isOffline else { return }
            Task {
                await viewModel?.retryLoadIfNeeded()
                await viewModel?.retryDynamicRailCandidatesIfNeeded()
            }
        }
        // Soft refresh on switching into the Home tab. Gated on `path` being
        // empty: the path persists across tab switches, so without it a
        // return to a pushed detail would refresh rails that aren't on screen
        // and then refresh again on the pop to root below. Can't race
        // `setUpIfNeeded()`'s first load — `.onChange` doesn't fire for an
        // initial value and `isActiveTab` defaults to `true`.
        .onChange(of: isActiveTab) { wasActive, isActive in
            guard !wasActive, isActive, path.wrappedValue.isEmpty else { return }
            Task { await viewModel?.softRefresh() }
        }
        // Soft refresh on back navigation reaching Home's root — a single pop,
        // a multi-level pop and iOS's pop-to-root on tab reselect all collapse
        // `path` to empty. `isEmpty` rather than a count comparison, so a
        // partial pop that doesn't reach root doesn't fire it.
        .onChange(of: path.wrappedValue) { oldPath, newPath in
            guard !oldPath.isEmpty, newPath.isEmpty else { return }
            Task { await viewModel?.softRefresh() }
        }
        // Measured on this view's own frame, not inside the scrolled content:
        // safe area insets don't change as content scrolls, so this doesn't
        // reheat the geometry cost `ScrollBottomObserver` describes. See
        // `topSafeAreaInset` for why a UIKit window lookup gives a different
        // number.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topSafeAreaInset = $0 }
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel?.hardRefresh() }
        } label: {
            if viewModel?.isHardRefreshing == true {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .accessibilityLabel(String(localized: "Refresh"))
        .accessibilityIdentifier(A11yID.Home.refreshButton)
        .disabled(viewModel?.isHardRefreshing == true)
    }

    /// Which full-screen placeholder, if any, replaces the rail `ScrollView`.
    /// `nil` means there's content to show. Single source of truth so `body`
    /// and `placeholderView(for:)` can't drift apart.
    private enum PlaceholderState {
        case offline
        case loading
        case failed(String)
        case empty
    }

    private var placeholderState: PlaceholderState? {
        switch viewModel?.loadState ?? .loading {
        case .idle, .loading:
            // Unconditional, regardless of `ConnectivityMonitor.isOffline`: an
            // active attempt should always show progress. Gating this behind an
            // offline check ahead of `loadState` left a retry tapped before
            // `isOffline` flipped (it only does once a request succeeds)
            // showing the static "You're Offline" screen with no sign of work.
            return .loading
        case .failed(let message):
            // Only consulted once there's an outcome to explain, distinguishing
            // an unreachable server from another error. Never reached while
            // `.loaded` has content on screen, so a background ping failing
            // after Home loaded can't blank it out.
            return ConnectivityMonitor.shared.isOffline ? .offline : .failed(message)
        case .loaded:
            let heroItems = viewModel?.heroItems ?? []
            let libraries = viewModel?.libraries ?? []
            let rails = viewModel?.rails ?? []
            return heroItems.isEmpty && libraries.isEmpty && rails.isEmpty ? .empty : nil
        }
    }

    @ViewBuilder
    private func placeholderView(for state: PlaceholderState) -> some View {
        switch state {
        case .offline:
            // `retryLoadIfNeeded()`, not a bare `load()`, so this coalesces
            // with an in-flight reconnect retry or a concurrent
            // `LibraryAvailability.retryAction` tap from Search.
            OfflineStateView(retry: { Task { await viewModel?.retryLoadIfNeeded() } })
        case .loading:
            LoadingView()
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await viewModel?.retryLoadIfNeeded() }
            }
        case .empty:
            ErrorStateView(message: String(localized: "Nothing here yet."), retry: nil)
        }
    }

    /// This view's effective top safe area inset, used to bleed `HeroRailView`
    /// under it via the negative padding in `content`.
    ///
    /// Populated by `.onGeometryChange` on `body`, not a UIKit window lookup:
    /// the window's raw `safeAreaInsets.top` is only the status
    /// bar/notch/Dynamic Island inset, while on iPad the floating top tab bar
    /// SwiftUI draws for `MainTabView` adds its own inset via `TabView`'s
    /// internal `.safeAreaInset(edge: .top)` — invisible to UIKit, but present
    /// in this view's `GeometryProxy.safeAreaInsets`. The window-only number
    /// undercounts by the tab bar's height on iPad, leaving the hero flush
    /// below the tab bar with a gap above it.
    @State private var topSafeAreaInset: CGFloat = 0

    /// Only reached once `placeholderState` is `nil`, so at least one of hero
    /// items, libraries or rails has content.
    @ViewBuilder
    private var content: some View {
        let heroItems = viewModel?.heroItems ?? []
        let libraries = viewModel?.libraries ?? []
        let rails = viewModel?.rails ?? []
        // `LazyVStack`: dynamic rails can push the count well past the curated
        // set, so don't construct every rail's hierarchy up front.
        LazyVStack(alignment: .leading, spacing: 24) {
            if !heroItems.isEmpty {
                // Bleeds `HeroRailView` under the status bar/notch via negative
                // top padding rather than `.ignoresSafeArea(edges: .top)`,
                // which is wrong in both of the places it could go:
                //
                // On the `ScrollView`, it extends the scroll view's *frame*
                // under the status bar, and `.refreshable`'s system spinner
                // anchors to that frame's top edge — the spinner rendered
                // squeezed into the notch area with a blank gap below it.
                //
                // On `HeroRailView` itself, it does nothing: a child declaring
                // it has no safe-area region left to expand into once its
                // container doesn't occupy one, so the hero lost its bleed
                // entirely. (`.scrollClipDisabled()` only stops clipping of
                // content that already overflows; it grants no access to space
                // the container was never laid out into.)
                //
                // Negative padding instead shrinks how much vertical space the
                // `LazyVStack` believes this view occupies, by exactly
                // `topSafeAreaInset`, while its content still renders at full
                // `heroHeight` — so those pixels overflow upward to the
                // physical top edge without moving `LibraryRailView` below it.
                // The `ScrollView` stays safe-area-respecting, so the
                // `.refreshable` spinner anchors correctly.
                // `.scrollClipDisabled()` above is required for the overflow to
                // render rather than be clipped.
                HeroRailView(items: heroItems, isTabActive: isActiveTab)
                    .padding(.top, -topSafeAreaInset)
            }
            if !libraries.isEmpty {
                LibraryRailView(libraries: libraries)
            }
            // `rails.indices`, not `Array(rails.enumerated())`, which would
            // allocate a fresh array of tuples on every recompute.
            ForEach(rails.indices, id: \.self) { index in
                MediaRailView(rail: rails[index])
            }

            if viewModel?.isLoadingMoreDynamicRails == true {
                LoadingView().frame(height: 150)
            }
        }
        .padding(.bottom, 24)
    }

    private func setUpIfNeeded() async {
        // Falls back to the cached `userID` from a prior sign-in, so a cold
        // launch that resumed `.main` from cache rather than a fresh sign-in
        // still builds a view model right away. See `AppState.start()`.
        guard viewModel == nil, let client = appState.apiClient,
              let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID else { return }
        let newViewModel = HomeViewModel(client: client, userID: userID)
        viewModel = newViewModel
        // Lets `SearchView`'s landing page trigger Home's retry without
        // holding a `HomeViewModel` reference (see `LibraryAvailability`).
        // `retryLoadIfNeeded()`, like the "Try Again" buttons above, so it
        // coalesces with a concurrent retry. `weak` because `newViewModel`'s
        // only strong owner is this view's `viewModel` `@State`.
        LibraryAvailability.shared.retryAction = { [weak newViewModel] in
            Task { await newViewModel?.retryLoadIfNeeded() }
        }
        await newViewModel.loadIfNeeded()
    }
}

/// Calls `onNearBottom` whenever the enclosing `ScrollView`'s content offset
/// comes within one screen height of its bottom — the mechanism behind Home's
/// scroll-triggered dynamic rail loading.
///
/// Reads `UIScrollView.contentOffset` via KVO (not the `.delegate` slot — see
/// `Coordinator.attachIfNeeded()`) because the two obvious SwiftUI approaches
/// both failed:
/// - `GeometryReader`/`PreferenceKey` on a marker view in a named coordinate
///   space tracked position correctly, but the coordinate-space conversion
///   scales with how much view tree it walks: a CPU sample during a freeze
///   after several dozen rails showed the main thread pegged inside
///   `GeometryReader.Child.updateValue()`, refiring every scroll frame.
/// - `.onAppear` on the last few rail rows is cheap but unreliable:
///   `LazyVStack` doesn't guarantee it materializes every row a fast scroll
///   passes through, and scrolling straight to the bottom in one motion
///   sometimes never fired it.
///
/// KVO needs no coordinate conversion, and observes the scroll view rather
/// than a lazily-rendered row's lifecycle, so `contentOffset` is authoritative
/// regardless of what `LazyVStack` has materialized.
private struct ScrollBottomObserver: UIViewRepresentable {
    var onNearBottom: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNearBottom: onNearBottom)
    }

    func makeUIView(context: Context) -> UIView {
        let view = WindowAttachmentTrackingView()
        view.backgroundColor = .clear
        // Never part of hit-testing; exists only as a starting point for the
        // coordinator to walk up from.
        view.isUserInteractionEnabled = false
        // `updateUIView` alone is not a reliable retry point for
        // `attachIfNeeded()`: on a real device every early call landed before
        // this view had a window (so `nearestScrollViewAncestor()` found
        // nothing) and it was never called again for the rest of that launch,
        // leaving KVO unattached and scroll-triggered rail loading dead for
        // the whole session. `didMoveToWindow` is UIKit's own signal that the
        // superview chain has settled into a live window.
        view.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.attachIfNeeded()
        }
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

    /// `@MainActor` explicitly: forming a KVO key path to
    /// `UIScrollView.contentOffset` requires it, since the SDK marks that
    /// property `@MainActor`-isolated.
    @MainActor
    final class Coordinator: NSObject {
        var onNearBottom: () -> Void
        weak var hostView: UIView?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        init(onNearBottom: @escaping () -> Void) {
            self.onNearBottom = onNearBottom
        }

        /// Finds the enclosing `ScrollView`'s backing `UIScrollView` by walking
        /// up from a `.background` marker, like `HeroRailView`'s
        /// `RegionTouchObserver` — robust to SwiftUI changing how many wrapper
        /// views it inserts between them.
        ///
        /// Observes `contentOffset` via KVO rather than becoming the scroll
        /// view's `UIScrollViewDelegate`: that's a single slot SwiftUI already
        /// occupies to implement scrolling/bounce/paging, so claiming it would
        /// break the real `ScrollView`. KVO observers coexist.
        func attachIfNeeded() {
            guard observation == nil, let scrollView = hostView?.nearestScrollViewAncestor() else { return }
            self.scrollView = scrollView
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                // KVO's closure is inferred nonisolated despite this class's
                // `@MainActor`, but `contentOffset` only changes on the main
                // thread, so the assumption holds.
                MainActor.assumeIsolated { self?.checkNearBottom(scrollView) }
            }
            // Check once immediately: content shorter than one screen never
            // changes `contentOffset` at all.
            checkNearBottom(scrollView)
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

/// An invisible `UIView` that calls back when UIKit inserts it into a live
/// window — the reliable retry signal `attachIfNeeded()` needs. See
/// `ScrollBottomObserver.makeUIView`.
private final class WindowAttachmentTrackingView: UIView {
    var onDidMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onDidMoveToWindow?()
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environment(AppState())
}
