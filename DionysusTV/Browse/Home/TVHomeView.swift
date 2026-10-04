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
    @Environment(\.tvSelectLibrary) private var selectLibrary
    @Environment(\.tvPageIsOnShow) private var isOnShow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(heroAutoCarouselEnabledStorageKey) private var autoCarousel = true
    @FocusState private var focus: String?
    @State private var pager = TVHeroPager(count: 0)
    /// Focus is in the rails below the hero: the backdrop fades away to the
    /// shell's own background (Benjamin, 2026-10-04).
    @State private var isBelowHero = false

    private var heroItem: MediaItem? {
        viewModel.heroItems.indices.contains(pager.index) ? viewModel.heroItems[pager.index] : viewModel.heroItems.first
    }

    private var libraries: [MediaItem] { viewModel.libraries.filter { !$0.isAudioLibrary } }
    private var heroHasFocus: Bool { focus?.hasPrefix("hero.") ?? false }

    private var timerRuns: Bool {
        TVHeroPager.timerRuns(
            count: viewModel.heroItems.count, autoCarousel: autoCarousel, reduceMotion: reduceMotion,
            motionFrozen: UITestHarness.freezesAmbientMotion, heroHasFocus: heroHasFocus,
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
            + libraries.map { "library.\($0.id)" }
    }

    var body: some View {
        TVPageScaffold(background: { background }) {
            if heroItem != nil || !viewModel.rails.isEmpty {
                content
            } else if case .failed(let message) = viewModel.loadState {
                TVPageMessage(title: String(localized: "Couldn't Load Home"), message: message, actionTitle: "Try Again", actionIdentifier: A11yID.TV.Main.retry) {
                    Task { await viewModel.load() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
            LazyVStack(alignment: .leading, spacing: 50) {
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
                // By title, not id: a rail's id is new with every refresh, and
                // Home refreshes when it comes back on show. Keyed by id the
                // rails were rebuilt, each scrolled back to its start, and the
                // tile focus was to return to (a See All at a rail's end) no
                // longer existed.
                ForEach(viewModel.rails, id: \.title) { rail in
                    railView(rail)
                }
                if viewModel.hasMoreDynamicRails {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await viewModel.loadMoreDynamicRails() }
                }
                if !libraries.isEmpty {
                    librariesRail
                }
            }
            .padding(.top, 60)
            .padding(.bottom, 200)
        }
        // Back up in the hero, the page returns to its top, as a detail page
        // does from its rails.
        .tvDetailLanding(focus: focus, isBelowHeader: $isBelowHero, isBelow: Self.isBelowHero)
        .scrollClipDisabled()
    }

    private func railView(_ rail: MediaCollectionRail) -> some View {
        TVRail(title: rail.title) {
            ForEach(rail.items) { item in
                Group {
                    if rail.usesLandscapeTiles {
                        TVLandscapeTile(item: item, title: item.railTitle, subtitle: item.railSubtitle, identifier: A11yID.TV.Main.tile(item.id)) {
                            open(.assetDetail(itemID: item.id, preloadedItem: item))
                        }
                    } else {
                        TVPosterTile(item: item, identifier: A11yID.TV.Main.tile(item.id)) {
                            open(.assetDetail(itemID: item.id, preloadedItem: item))
                        }
                    }
                }
                .focused($focus, equals: Self.tileFocus(rail: rail, item: item.id))
            }
            if let query = rail.seeAllQuery {
                Button { open(.collection(query)) } label: {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.right").font(.system(size: 64)).accessibilityHidden(true)
                        Text("See All").font(.callout.weight(.semibold))
                    }
                    .frame(width: TVTileMetrics.poster.width, height: rail.usesLandscapeTiles ? TVTileMetrics.landscape.height : TVTileMetrics.poster.height)
                    .background(.white.opacity(0.1))
                }
                .buttonStyle(.card)
                .focused($focus, equals: Self.seeAllFocus(rail))
                .accessibilityIdentifier(A11yID.TV.Main.seeAll(rail.title))
            }
        }
    }

    /// Each tile switches to the library's own page.
    private var librariesRail: some View {
        TVRail(title: String(localized: "Libraries")) {
            ForEach(libraries) { library in
                Button { selectLibrary(library.id) } label: {
                    AsyncRemoteImage(url: library.primaryImageURL, placeholderSystemImage: TVSidebarLayout.systemImage(forCollectionType: library.collectionType))
                        .frame(width: TVTileMetrics.episode.width, height: TVTileMetrics.episode.height)
                        .overlay {
                            Text(verbatim: library.name)
                                .font(.system(size: 44, weight: .bold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(red: 20 / 255, green: 4 / 255, blue: 14 / 255).opacity(0.55))
                        }
                }
                .buttonStyle(.card)
                .focused($focus, equals: "library.\(library.id)")
                .accessibilityLabel(library.name)
                .accessibilityIdentifier(A11yID.TV.Main.library(library.id))
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
