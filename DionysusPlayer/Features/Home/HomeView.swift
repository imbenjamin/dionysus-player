import SwiftUI
import UIKit

/// Home is a single scrolling page of rails: a full-bleed hero banner, the
/// user's libraries (replacing the old top-menu category picker), then
/// Continue Watching / Recently Added Movies / Recently Added Shows.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var viewModel: HomeViewModel?
    /// Whether Home is currently the selected tab — passed down from
    /// `MainTabView`, which tracks `selectedTab` explicitly. Threaded
    /// straight through to `HeroRailView` so its auto-advance timer can
    /// stop doing real work while Home isn't on screen; see that
    /// property's doc comment on `HeroRailView` for why tab selection alone
    /// isn't the whole story. Defaults to `true` so `#Preview` and any
    /// future non-tab caller don't need to think about it. Also drives a
    /// soft refresh whenever this flips from `false` to `true` — see the
    /// `.onChange(of: isActiveTab)` below.
    var isActiveTab: Bool = true
    /// `MainTabView`'s bound path for Home's own `NavigationStack` —
    /// observed (never written) purely to detect the user popping back to
    /// Home's root, which also triggers a soft refresh. Defaults to
    /// `.constant([])` so `#Preview` doesn't need to think about it.
    var path: Binding<[AppRoute]> = .constant([])

    var body: some View {
        Group {
            if let placeholderState {
                // Rendered outside the `ScrollView` entirely (rather than
                // inside it at a fixed height, as this used to do) so
                // `OfflineStateView`/`LoadingView`/`ErrorStateView`'s own
                // `.frame(maxHeight: .infinity)` centers within the *actual*
                // visible screen instead of a small fixed-height box sitting
                // at the top of an otherwise-empty scroll area — confirmed
                // live (2026-08-29): the offline/error states rendered
                // pinned near the top with a large dead area below rather
                // than centered on screen.
                placeholderView(for: placeholderState)
            } else {
                ScrollView {
                    content
                        // Loads more dynamic rails once the scroll view's own
                        // content offset comes within one screen height of the
                        // bottom — see `ScrollBottomObserver`'s doc comment for why
                        // this is the third design tried here, and what was wrong
                        // with each of the first two.
                        .background {
                            ScrollBottomObserver {
                                // Both guards checked here, synchronously, before
                                // spawning anything — not just left to
                                // `loadMoreDynamicRails()`'s own internal guard.
                                // `checkNearBottom` (the caller of this closure)
                                // fires on every `contentOffset` KVO tick while
                                // within one screen height of the bottom, i.e. many
                                // times a second during a continuous scroll; without
                                // the `isLoadingMoreDynamicRails` check here too,
                                // every one of those ticks spawned a fresh `Task`
                                // that only found out it had nothing to do once it
                                // actually ran, piling up avoidable work on the main
                                // actor for the whole scroll instead of skipping it
                                // up front.
                                guard viewModel?.hasMoreDynamicRails == true,
                                      viewModel?.isLoadingMoreDynamicRails == false else { return }
                                Task { await viewModel?.loadMoreDynamicRails() }
                            }
                        }
                }
                // Lets `HeroRailView` overflow-paint above its own laid-out
                // position (via the negative top padding applied to it in
                // `content`, below) instead of being clipped there — see
                // that padding's own doc comment for the full bleed-vs-
                // `.refreshable` story this is one half of.
                .scrollClipDisabled()
                // Hard refresh — re-fetches everything, as if this were a
                // fresh app load. Only ever mounted once `placeholderState`
                // is `nil` (this branch), so it's naturally unreachable
                // during the initial load/offline/error states — nothing
                // to pull-to-refresh over yet in those.
                .refreshable { await viewModel?.hardRefresh() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // VoiceOver users can't reliably perform a pull gesture, so
            // this mirrors `.refreshable` above as an explicit, always-
            // reachable button — same reasoning, and the same "unmount
            // entirely rather than just hide" treatment, as `PlayerView`'s
            // VoiceOver-only controls button.
            if voiceOverEnabled {
                ToolbarItem(placement: .topBarTrailing) { refreshButton }
            }
        }
        .task { await setUpIfNeeded() }
        // Catches the "we're back online" transition and retries whatever
        // didn't make it: `retryLoadIfNeeded()` (with backoff — see its own
        // doc comment for why a single immediate retry isn't enough) if the
        // primary load itself never succeeded, then
        // `retryDynamicRailCandidatesIfNeeded()` for the narrower case
        // where the curated rails loaded fine but dynamic rail discovery
        // — which fails silently by design, see `HomeViewModel.load()`'s
        // doc comment — happened to land in that same reconnect window.
        // Sequenced rather than parallel: a successful `retryLoadIfNeeded()`
        // already re-ran dynamic rail discovery as part of `load()` itself,
        // so this only ever has real work left to do in the narrower case.
        .onChange(of: ConnectivityMonitor.shared.isOffline) { wasOffline, isOffline in
            guard wasOffline, !isOffline else { return }
            Task {
                await viewModel?.retryLoadIfNeeded()
                await viewModel?.retryDynamicRailCandidatesIfNeeded()
            }
        }
        // Soft refresh: catches the user switching into the Home tab from
        // somewhere else (the nav-bar case). Also gated on `path` already
        // being empty — without that, switching tabs away and back while
        // still nested on a pushed detail (the path persists across tab
        // switches) would soft-refresh rails not even on screen, then
        // soft-refresh again when the user actually pops back to root via
        // the `path` observer below. Can't race `setUpIfNeeded()`'s first
        // load: `.onChange` never fires for a view's initial value, and
        // `isActiveTab` defaults to `true`.
        .onChange(of: isActiveTab) { wasActive, isActive in
            guard !wasActive, isActive, path.wrappedValue.isEmpty else { return }
            Task { await viewModel?.softRefresh() }
        }
        // Soft refresh: catches in-page back navigation returning to
        // Home's own root — a single pop, a multi-level pop, or iOS's own
        // "pop to root" on a tab reselect while nested, all collapse
        // `path` to empty. `isEmpty`, not `newPath.count < oldPath.count`
        // — this should fire on *returning to Home*, not every partial pop
        // that doesn't reach root.
        .onChange(of: path.wrappedValue) { oldPath, newPath in
            guard !oldPath.isEmpty, newPath.isEmpty else { return }
            Task { await viewModel?.softRefresh() }
        }
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
        .disabled(viewModel?.isHardRefreshing == true)
    }

    /// Which full-screen placeholder (if any) should replace the rail
    /// `ScrollView` entirely. `nil` means there's real content to show —
    /// the only case that still uses the `ScrollView`. Single source of
    /// truth for this decision so `body` (which branch to render) and
    /// `placeholderView(for:)` (what that branch shows) can't drift apart.
    private enum PlaceholderState {
        case offline
        case loading
        case failed(String)
        case empty
    }

    private var placeholderState: PlaceholderState? {
        switch viewModel?.loadState ?? .loading {
        case .idle, .loading:
            // Unconditional, regardless of `ConnectivityMonitor.isOffline`
            // — an active attempt (the first load, a manual "Try Again", or
            // the automatic reconnect loop) should always show progress.
            // This used to be gated behind an offline check that ran ahead
            // of `loadState` entirely, which meant a retry tapped while
            // `isOffline` hadn't yet flipped false (it only does once some
            // request actually succeeds) silently kept showing the static
            // "You're Offline" screen with no visible sign anything was
            // happening — confirmed live, 2026-08-29.
            return .loading
        case .failed(let message):
            // Only consulted once there's an actual outcome to explain —
            // distinguishes "can't reach the server at all" from some other
            // real error. Never reached while `.loaded` already has content
            // on screen (that case is handled separately below), so a
            // scenePhase-triggered background ping failing after Home
            // already loaded still can't blank the screen out from under
            // the user.
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
            // `retryLoadIfNeeded()`, not a bare `load()` — coalesces with
            // any automatic reconnect retry (or a concurrent tap on
            // `LibraryAvailability.retryAction` from Search) already in
            // flight instead of racing it — see that method's doc comment.
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

    /// The key window's top safe area inset (status bar/notch/Dynamic
    /// Island height) — used to bleed `HeroRailView` under it via negative
    /// padding rather than `.ignoresSafeArea`; see that padding's own doc
    /// comment in `content` for why. A plain UIKit lookup rather than a
    /// `GeometryReader`-based one (SwiftUI has no direct environment value
    /// for this) — cheap, and this app is single-scene/single-window, so
    /// `.first` is always the right window.
    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 0
    }

    /// Only reached once `placeholderState` is `nil` — there's always at
    /// least one of hero items/libraries/rails to show here.
    @ViewBuilder
    private var content: some View {
        let heroItems = viewModel?.heroItems ?? []
        let libraries = viewModel?.libraries ?? []
        let rails = viewModel?.rails ?? []
        // `LazyVStack`, not `VStack` — with dynamic rails potentially
        // pushing the rail count well past the curated set, this avoids
        // constructing every rail's view hierarchy up front.
        LazyVStack(alignment: .leading, spacing: 24) {
            if !heroItems.isEmpty {
                // Bleeds `HeroRailView` up under the status bar/notch at
                // rest via negative top padding, rather than the simpler
                // `.ignoresSafeArea(edges: .top)` this used to carry (moved
                // off the enclosing `ScrollView` to here, then off this
                // view too — see below for why).
                //
                // `.ignoresSafeArea(edges: .top)` on the `ScrollView` itself
                // was the very first design, and looked right at rest — but
                // it also extends the scroll view's own *frame* under the
                // status bar, and `.refreshable`'s system spinner anchors to
                // that same frame's top edge. Confirmed live on a physical
                // device (2026-09-02): the spinner rendered squeezed into
                // the status bar/notch area (barely visible, fighting with
                // the Dynamic Island) with a stray blank gap left below it.
                //
                // Putting `.ignoresSafeArea` on `HeroRailView` instead
                // (still inside a normal, safe-area-respecting `ScrollView`)
                // was the second design, tried next — also confirmed wrong
                // live: a `ScrollView`'s own frame is what "ignoring the
                // safe area" needs to reach into, and a child alone
                // declaring the same modifier has no safe-area region left
                // to expand into once its container doesn't occupy one
                // (`.scrollClipDisabled()` on the `ScrollView`, added at the
                // same time, only stops *clipping* of content that already
                // overflows its bounds — it doesn't grant a child access to
                // space the container's own frame was never laid out into).
                // The visible result was the hero losing its bleed
                // entirely, flush below the status bar instead.
                //
                // This third design keeps the `ScrollView` itself safe-area
                // -respecting (so `.refreshable`'s spinner anchors correctly
                // below the status bar) while still making the hero
                // genuinely overflow-paint past its own laid-out top edge:
                // negative top padding shrinks how much vertical space the
                // `LazyVStack` believes this view occupies (by exactly
                // `topSafeAreaInset`) while its content still renders at its
                // full `heroHeight`, so the extra `topSafeAreaInset` worth
                // of pixels overflow upward past where the stack thinks the
                // view starts — reaching the physical top of the screen —
                // without changing where `LibraryRailView` below it ends up
                // (the same math the removed `.ignoresSafeArea` used to
                // produce). `.scrollClipDisabled()` above is still required
                // for that overflow to actually render instead of being
                // clipped at the scroll view's bounds.
                HeroRailView(items: heroItems, isTabActive: isActiveTab)
                    .padding(.top, -topSafeAreaInset)
            }
            if !libraries.isEmpty {
                LibraryRailView(libraries: libraries)
            }
            // `rails.indices`, not `Array(rails.enumerated())` — same
            // reasoning as `HeroRailView.loopedItems`'s `ForEach`: avoids
            // allocating a fresh array of tuples every time this recomputes.
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
        // Falls back to the cached `userID` from a prior sign-in (same
        // idiom `PlayerView` uses) so this still constructs a view model
        // right away on a cold launch that resumed `.main` from cache
        // rather than a fresh sign-in — see `AppState.start()`.
        guard viewModel == nil, let client = appState.apiClient,
              let userID = appState.currentUser?.id ?? appState.sessionStore.credentials?.userID else { return }
        let newViewModel = HomeViewModel(client: client, userID: userID)
        viewModel = newViewModel
        // Lets `SearchView`'s landing page trigger Home's own retry —
        // `retryLoadIfNeeded()`, same as this view's own "Try Again"
        // buttons above, so it coalesces with any concurrent retry rather
        // than racing it (see that method's doc comment) — without needing
        // a reference to `HomeViewModel` itself, see `LibraryAvailability`'s
        // doc comment. `weak` since `newViewModel`'s only strong owner is
        // this view's own `viewModel` `@State`, not this closure.
        LibraryAvailability.shared.retryAction = { [weak newViewModel] in
            Task { await newViewModel?.retryLoadIfNeeded() }
        }
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
///
/// This design itself had one more real bug, found live on a physical
/// device (2026-08-24): `attachIfNeeded()` only ever got (re-)called from
/// `updateUIView`, and on that device every one of its early calls landed
/// before this marker view actually had a window — so `nearestScrollViewAncestor()`
/// found nothing every time, and `updateUIView` simply never fired again
/// for the rest of that launch even though Home's own content kept
/// changing on screen. The KVO observation never got set up at all, which
/// silently broke scroll-triggered loading for the *entire session* —
/// whatever rail count `load()`'s own first inline batch happened to
/// produce was all that would ever show, no matter how much further the
/// user scrolled (user-reported as "0 or 1 dynamic rail even after several
/// relaunches" — a real, deterministic bug, not the batch-luck variance it
/// first looked like). Fixed by also retrying `attachIfNeeded()` from
/// `WindowAttachmentTrackingView.didMoveToWindow()` — UIKit's own reliable
/// "this view's superview chain just became real" signal, not dependent on
/// however many more times SwiftUI happens to call `updateUIView`.
private struct ScrollBottomObserver: UIViewRepresentable {
    var onNearBottom: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNearBottom: onNearBottom)
    }

    func makeUIView(context: Context) -> UIView {
        let view = WindowAttachmentTrackingView()
        view.backgroundColor = .clear
        // Never itself part of hit-testing — exists only to give the
        // coordinator a starting point to walk up from.
        view.isUserInteractionEnabled = false
        // Confirmed live (2026-08-24): relying on `updateUIView` alone to
        // eventually retry `attachIfNeeded()` is not reliable — on a real
        // device, all of its early calls landed before this view had a
        // window (so `nearestScrollViewAncestor()` found nothing), and
        // `updateUIView` was never called again for the rest of that
        // launch even as Home's content clearly kept changing underneath
        // it, permanently breaking scroll-triggered dynamic-rail loading
        // for that whole session (the one rail count you got from `load()`'s
        // own first batch was all you'd ever see, no matter how much you
        // scrolled). `didMoveToWindow` is UIKit's own reliable signal for
        // "this view (and therefore its now-settled superview chain) just
        // became part of a live window" — retrying here as well closes
        // that gap regardless of whatever SwiftUI's own re-render timing
        // happens to do.
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
            guard observation == nil, let scrollView = hostView?.nearestScrollViewAncestor() else { return }
            self.scrollView = scrollView
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                // KVO's closure type is inferred nonisolated regardless of
                // this class's own `@MainActor`, but a UIScrollView's
                // contentOffset only ever changes on the main thread in
                // practice — the isolation assumption here is guaranteed,
                // not a leap of faith.
                MainActor.assumeIsolated { self?.checkNearBottom(scrollView) }
            }
            // Also check once immediately — content shorter than one
            // screen (nothing to scroll at all) would otherwise never
            // trigger a `contentOffset` change to check from.
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

/// A plain, invisible `UIView` except for one thing: it calls back whenever
/// UIKit actually inserts it into a live window — see `ScrollBottomObserver
/// .makeUIView`'s doc comment for why that's the reliable retry signal
/// `attachIfNeeded()` needs, rather than trusting `updateUIView` to get
/// called again later.
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
