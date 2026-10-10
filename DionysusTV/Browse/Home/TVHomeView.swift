import SwiftUI

/// Home (prototype screen 5): the hero over a full-bleed backdrop, then the
/// rails in the iOS order, on the shared `HomeViewModel`.
struct TVHomeView: View {
    let client: JellyfinAPIClient
    let userID: String
    /// Owned by the shell, so Home's data outlives its views.
    let viewModel: HomeViewModel
    @Binding var rememberedFocus: String?
    @Environment(\.tvOpenRoute) private var open
    @Environment(\.tvOpenDetailBeneathPlayer) private var openDetailBeneathPlayer
    @Environment(\.tvPageIsOnShow) private var isOnShow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(heroAutoCarouselEnabledStorageKey) private var autoCarousel = true
    @FocusState private var focus: String?
    @State private var pager = TVHeroPager(count: 0)
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// Focus is in the rails below the hero: the backdrop fades away to the
    /// shell's own background (Benjamin, 2026-10-04).
    @State private var isBelowHero = false
    /// Bumped by Menu below the hero: the page scrolls back to its top.
    @State private var topRequest = 0

    private var heroItem: MediaItem? {
        viewModel.heroItems.indices.contains(pager.index) ? viewModel.heroItems[pager.index] : viewModel.heroItems.first
    }

    private var heroHasFocus: Bool { focus?.hasPrefix("hero.") ?? false }

    private var timerRuns: Bool {
        TVHeroPager.timerRuns(
            count: viewModel.heroItems.count, autoCarousel: autoCarousel, reduceMotion: reduceMotion,
            motionFrozen: UITestHarness.freezesAmbientMotion, voiceOver: voiceOverEnabled, heroHasFocus: heroHasFocus,
            isOnShow: isOnShow, stoppedByHand: pager.stoppedByHand
        )
    }

    /// Keyed on the rail's title, not its id: a rail's id is new with every
    /// refresh, and Home refreshes when it comes back on show, so focus
    /// remembered by id could never be put back.
    private static func tileFocus(rail: MediaCollectionRail, item: String) -> String { "rail.\(rail.title).\(item)" }
    private static func seeAllFocus(_ rail: MediaCollectionRail) -> String { "seeall.\(rail.title)" }

    /// Every focusable item in order; the hero's Play is the default.
    private static func isBelowHero(_ id: String) -> Bool { !id.hasPrefix("hero.") }

    private var focusIDs: [String] {
        (heroItem == nil ? [] : [TVHeroView.playFocus, TVHeroView.infoFocus])
            + viewModel.rails.flatMap { rail in
                rail.items.map { Self.tileFocus(rail: rail, item: $0.id) } + (rail.seeAllQuery == nil ? [] : [Self.seeAllFocus(rail)])
            }
    }

    var body: some View {
        TVPageScaffold(layout: .besideRailScrollingUnder, background: { background }) {
            if heroItem != nil || !viewModel.rails.isEmpty {
                content
            } else if case .failed(let message) = viewModel.loadState {
                TVPageMessage(title: String(localized: "Couldn't Load Home"), message: message, actionTitle: "Try Again", actionIdentifier: A11yID.TV.Main.retry) {
                    Task { await viewModel.load() }
                }
            } else {
                // Takes focus, so the sidebar doesn't open over it (see
                // `TVDetailLoading`).
                TVDetailLoading().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await viewModel.loadIfNeeded() }
        .onChange(of: viewModel.heroItems.count, initial: true) { _, count in pager.setCount(count) }
        .onChange(of: heroHasFocus) { _, has in
            if !has { pager.heroLostFocus() }
        }
        // Back on show after a detail page or a See All grid: progress and
        // watched state may have changed.
        .onChange(of: isOnShow) { _, onShow in
            if onShow { Task { await viewModel.softRefresh() } }
        }
        // Restarted whenever the item changes, so each gets a full interval.
        .task(id: "\(timerRuns)-\(pager.index)") {
            guard timerRuns else { return }
            try? await Task.sleep(for: TVHeroPager.interval)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) { pager.tick() }
        }
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $rememberedFocus)
        // Below the hero, Menu goes back to the top with Play focused; from
        // the hero it's the shell's, which opens the sidebar.
        .tvMenuReturnsToLanding($focus, landing: heroItem == nil ? nil : TVHeroView.playFocus, isAway: isBelowHero) {
            topRequest += 1
        }
    }

    @ViewBuilder
    private var background: some View {
        // One backdrop, not one per item: it holds the picture on show until
        // the next has loaded, then fades (`TVHeldImage`). Below the hero it
        // fades out, leaving the shell's plum glow behind the rails, and fades
        // back in when focus returns to the hero.
        ZStack {
            if let heroItem, !isBelowHero {
                TVDetailBackdrop(item: heroItem)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: isBelowHero)
    }

    private var content: some View {
        ScrollView(.vertical) {
            // The hero sits outside the lazy stack, so it's built however far
            // down the page is: Menu's focus on Play landed only once a scroll
            // rebuilt it, and under VoiceOver that scroll never starts, so
            // focus snapped back to the tile (Benjamin, 2026-10-10).
            VStack(alignment: .leading, spacing: 50) {
                if let heroItem {
                    TVHeroView(item: heroItem, count: viewModel.heroItems.count, pager: $pager, isCounting: timerRuns, focus: $focus) {
                        playHero(heroItem)
                    } moreInfo: {
                        open(.assetDetail(itemID: heroItem.id, preloadedItem: heroItem))
                    }
                    // The hero fills the first screen; the first rail's
                    // title shows at its foot. The detail pages' header
                    // height, measured so Play lands without a nudge.
                    .frame(minHeight: TVDetailMetrics.headerHeight, alignment: .bottomLeading)
                }
                LazyVStack(alignment: .leading, spacing: 50) {
                    // By title, not id: a rail's id is new with every refresh, and
                    // Home refreshes when it comes back on show. Keyed by id the
                    // rails were rebuilt, each scrolled back to its start, and the
                    // tile focus was to return to (a See All at a rail's end) no
                    // longer existed.
                    ForEach(viewModel.rails, id: \.title) { rail in
                        railView(rail)
                    }
                    if viewModel.hasMoreDynamicRails {
                        // Keeps loading batches for as long as the spinner is
                        // built (on screen, or near it in the lazy stack), not one
                        // when it appears: a batch whose candidates were all too
                        // thin, or one that added rails without moving the spinner
                        // out of the stack, or an appearance mid-load, left it
                        // spinning for good. iOS's `ScrollBottomObserver` exists
                        // for the same reason. Each batch runs in a task of its
                        // own: cancelled with the spinner, its requests failed and
                        // its candidates were dropped as too thin.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task {
                                while !Task.isCancelled, viewModel.hasMoreDynamicRails {
                                    if viewModel.isLoadingMoreDynamicRails {
                                        try? await Task.sleep(for: .milliseconds(250))
                                        continue
                                    }
                                    await Task { await viewModel.loadMoreDynamicRails() }.value
                                }
                            }
                    }
                }
            }
            .padding(.top, 60)
            .padding(.bottom, 200)
        }
        // Back up in the hero, the page returns to its top, as a detail page
        // does from its rails.
        .tvDetailLanding(focus: focus, isBelowHeader: $isBelowHero, topRequest: topRequest, isBelow: Self.isBelowHero)
        .scrollClipDisabled()
    }

    private func railView(_ rail: MediaCollectionRail) -> some View {
        let shape = TVTileShape(items: rail.items)
        return TVRail(title: rail.title, titleIdentifier: A11yID.TV.Main.rail(rail.title), groupIdentifier: A11yID.TV.Main.railGroup(rail.title), buildsEveryTile: true) {
            ForEach(rail.items) { item in
                TVShapedTile(item: item, shape: shape, identifier: A11yID.TV.Main.tile(item.id)) {
                    open(.assetDetail(itemID: item.id, preloadedItem: item))
                }
                .focused($focus, equals: Self.tileFocus(rail: rail, item: item.id))
            }
            if let query = rail.seeAllQuery {
                Button { open(.collection(query)) } label: {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.right").font(.system(size: 64)).accessibilityHidden(true)
                        Text("See All").font(.callout.weight(.semibold))
                    }
                    .frame(width: TVTileMetrics.poster.width, height: shape.railSize.height)
                    .background(.white.opacity(0.1))
                    // Named for its rail: on its own VoiceOver read "See All" (M5).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("See All, \(rail.title)"))
                }
                .buttonStyle(.card)
                .focused($focus, equals: Self.seeAllFocus(rail))
                .accessibilityIdentifier(A11yID.TV.Main.seeAll(rail.title))
            }
        }
    }

    private func playHero(_ item: MediaItem) {
        Task { @MainActor in
            guard let target = await TVHeroPlayTarget.resolve(item, client: client, userID: userID) else {
                // Nothing to play (a series with no episodes): its page says so.
                open(.assetDetail(itemID: item.id, preloadedItem: item))
                return
            }
            // Leaving the player lands on the title's page, over Home
            // (Benjamin, 2026-10-04). Home refreshes when Menu brings it back.
            // Pushed only once the player is up: the page counts as covered
            // until the player closes.
            var detailPlaybackEnded: (@MainActor (PlaybackSessionOutcome) -> Void)?
            let presented = TVPlayerPresenter.present(PlaybackRequest(itemID: target), client: client, userID: userID) { outcome in
                detailPlaybackEnded?(outcome)
            }
            if presented { detailPlaybackEnded = openDetailBeneathPlayer(item) }
        }
    }
}
