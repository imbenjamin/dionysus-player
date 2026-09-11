import SwiftUI
import UIKit

/// Home's top section: a full-bleed, swipeable hero banner of unwatched movies
/// and series, each a backdrop-and-logo page via `BackdropLogoOverlay`.
/// Titleless — the artwork carries the item's identity, and a header row would
/// fight the full-bleed treatment.
///
/// Bleeds under the status bar via negative top padding applied by `HomeView`,
/// combined with `.scrollClipDisabled()` there so the overflow renders instead
/// of clipping at the scroll view's bounds.
struct HeroRailView: View {
    let items: [MediaItem]
    /// Whether Home is the selected tab, threaded down from `MainTabView`. A
    /// plain stored property rather than `@State`, so it reflects the caller's
    /// current value rather than latching the first. Combined with `isOnScreen`
    /// into `isVisible`, which gates the auto-advance timer.
    let isTabActive: Bool

    /// A custom init so `scrollPosition` can start at `0` rather than `1` when
    /// `loopedItems` doesn't pad `items` — with 0 or 1 items looping is
    /// meaningless, and the usual `1` would reference a nonexistent `.id` and
    /// render blank. Also computes `loopedItems` once (see that property).
    init(items: [MediaItem], isTabActive: Bool) {
        self.items = items
        self.isTabActive = isTabActive
        self.loopedItems = Self.loop(items)
        _scrollPosition = State(initialValue: items.count > 1 ? 1 : 0)
    }

    /// Tracked only to re-run `body` on rotation: `heroHeight` is a plain UIKit
    /// read, which SwiftUI can't know `body` depends on unless something here is
    /// a tracked dependency. Page width needs no such prompt, coming from a
    /// `GeometryReader` that is part of the layout system.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Gates `tick()`'s transition and `HeroPageIndicator`'s two animations.
    /// Manual swipes are untouched: HIG's guidance is to reduce automatic
    /// motion, listing gesture-tracked animation as a best practice.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Disables the automatic advance entirely, not just its transition style as
    /// `reduceMotion` does: a VoiceOver user needs to read one item fully rather
    /// than race a 5-second clock. `heroContent` mounts Previous/Next buttons in
    /// its place, so the carousel stays navigable. Enforced regardless of
    /// `autoCarouselEnabled`; `manualCarouselModeEnabled` is the combined gate
    /// most of this view reads.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// `ProfileView`'s "Auto Carousel on Home" toggle: the manual navigation
    /// VoiceOver enforces above, as a standing preference. Its default must
    /// match `ProfileView`'s for this key.
    @AppStorage(heroAutoCarouselEnabledStorageKey) private var autoCarouselEnabled = true

    /// The gate `tick()`, the indicator's pause state and the Previous/Next
    /// buttons read: true whenever the carousel should behave as manually
    /// navigated, whether VoiceOver enforces it or the preference is off.
    /// `voiceOverEnabled` stays reserved for `announceIfNeeded`, which a sighted
    /// user who merely turned auto-advance off has no use for.
    private var manualCarouselModeEnabled: Bool { !autoCarouselEnabled || voiceOverEnabled }

    /// `.compact` is iPhone's landscape signal, as in `HeroHeaderView`.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// The key window's bounds rather than `UIScreen.main`, which is soft
    /// deprecated and ignores a scene resized under Stage Manager.
    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)
    }

    /// Portrait is a third of the screen stretched 25% taller, plus the window's
    /// raw status-bar inset so bleeding under the notch is upward growth rather
    /// than eating into that 1.25x budget — without the addition the two would
    /// fight over the same height.
    ///
    /// Landscape goes straight to 75% of the screen: a third-of-portrait formula
    /// reads far too short once the screen itself is shorter. The key window's
    /// `bounds` already reflect the current orientation.
    ///
    /// `keyWindow` is read once into a local rather than through two computed
    /// properties, which would re-walk `connectedScenes` twice per evaluation.
    private var heroHeight: CGFloat {
        let window = keyWindow
        let height = window?.bounds.height ?? 800
        guard !isLandscape else { return height * 0.75 }
        return (window?.safeAreaInsets.top ?? 0) + height / 3 * 1.25
    }

    /// Indexes into `loopedItems`, not `items`, starting at `1` — the first real
    /// page past the leading duplicate. Optional because `.scrollPosition(id:)`
    /// requires it: this is transiently `nil` before the first layout pass, which
    /// every reader below accounts for.
    @State private var scrollPosition: Int?

    /// `items` padded with a duplicate of the last item in front and the first
    /// behind, so a swipe off either end lands on a page showing the correct next
    /// item rather than stopping. `onChange(of:)` then snaps `scrollPosition`
    /// back into the real range without animation once the swipe lands; the snap
    /// is invisible because duplicate and real page are pixel-identical. The
    /// standard workaround for infinite paging, which has no native loop mode.
    ///
    /// A stored `let` computed in `init`, not a `body`-time property: it depends
    /// only on `items`, which never changes for a given instance, and would
    /// otherwise be rebuilt on every `body` evaluation including each of
    /// `tick()`'s once-a-second ticks.
    let loopedItems: [MediaItem]

    private static func loop(_ items: [MediaItem]) -> [MediaItem] {
        guard let first = items.first, let last = items.last, items.count > 1 else { return items }
        return [last] + items + [first]
    }

    /// `scrollPosition` in `items`' index space, so the dot indicator never
    /// shows the padding pages.
    private var currentIndex: Int {
        guard items.count > 1, let scrollPosition else { return 0 }
        return (scrollPosition - 1 + items.count) % items.count
    }

    /// See `TabBarTintModel`. `nil` — and so the default tint — whenever there
    /// is no hero artwork to sample, rather than leaving the previous hero's.
    private func publishBackdropLuminance() async {
        guard items.indices.contains(currentIndex),
              let url = items[currentIndex].backdropImageURL ?? items[currentIndex].primaryImageURL,
              let image = try? await RemoteImageLoader.shared.image(for: url) else {
            TabBarTintModel.shared.update(backdropLuminance: nil)
            return
        }
        TabBarTintModel.shared.update(
            backdropLuminance: TabBarTintModel.topStripLuminance(of: image)
        )
    }

    /// Whether a finger is down on the carousel, tracked by `RegionTouchObserver`
    /// — a raw `UIGestureRecognizer` on the hero's `UIScrollView`, which exposes
    /// nothing equivalent natively, rather than a SwiftUI `DragGesture`.
    @State private var isInteracting = false

    /// On-screen presence, from the `.onAppear`/`.onDisappear` pair
    /// `resyncScrollPosition(using:)` uses, which fires reliably around the
    /// Player's `.fullScreenCover`. `isTabActive` can't catch that: Home stays
    /// the selected tab the whole time the Player covers it.
    @State private var isOnScreen = true

    /// Whether the auto-advance tick should do anything. Combines `isTabActive`
    /// and `isOnScreen`, since neither alone covers both ways Home stops being
    /// visible while still mounted.
    ///
    /// While `false`, `tick()` is a complete no-op with no state write at all,
    /// as it already is while `isInteracting` — otherwise a backgrounded or
    /// covered Home drives a state write and re-render every second for as long
    /// as the app runs. `idleSeconds` is held where it was, so nothing drifts
    /// while invisible and there is nothing to resync on reappearance.
    private var isVisible: Bool { isTabActive && isOnScreen }

    /// Seconds since the current item became current, ticked by `tickTimer` and
    /// held steady — not reset — while `isInteracting`, so touching the carousel
    /// pauses the countdown where it was rather than restarting it.
    /// `HeroPageIndicator` mirrors the same pause for its fill.
    @State private var idleSeconds = 0

    /// `fileprivate` so `HeroPageIndicator` below can lock its countdown-fill
    /// animation to the same timing rather than duplicating the numbers.
    fileprivate static let autoAdvanceInterval = 5

    /// The auto-advance page-slide's duration. Named because `snapIfNeeded` must
    /// wait at least this long before the loop's silent snap-back, or it cuts
    /// the slide off mid-way.
    fileprivate static let autoAdvanceAnimationDuration: TimeInterval = 0.35

    /// Ticks once a second; `tick()` holds `idleSeconds` steady while
    /// `isInteracting`. `@State` rather than a plain `let`, which would tear down
    /// and recreate the Timer every time `HomeView.body` reconstructs this value
    /// type — on every dynamic-rail batch append while scrolling. A `@State`
    /// initial value evaluates once per view identity, keeping one Timer alive
    /// for the view's real lifetime.
    @State private var tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Reduce Motion's stand-in for the outgoing item during an auto-advance;
    /// `nil` otherwise. See `advanceWithFade(from:to:)`.
    @State private var fadeOutItem: MediaItem?
    /// `1` when an auto-advance begins under Reduce Motion, animated to `0` over
    /// `autoAdvanceAnimationDuration`.
    @State private var fadeOutOpacity: Double = 0

    /// Wraps the rail so each page's width comes from `proxy.size.width`, which
    /// is genuinely layout-driven unlike a `keyWindow.bounds.width` read.
    ///
    /// `.frame(height: heroHeight)` stays outside this `GeometryReader`, which
    /// otherwise expands to fill all available height — here the entire
    /// remaining height of Home's outer `ScrollView`, effectively unbounded.
    /// Applying the constraint outside proposes that fixed height into the
    /// reader, leaving only width free.
    var body: some View {
        GeometryReader { proxy in
            heroContent(pageWidth: proxy.size.width)
        }
        .frame(height: heroHeight)
        .accessibilityIdentifier(A11yID.Home.heroCarousel)
        // `proxy.size` reports the size within the safe area, not the full
        // available width: nothing above `HeroRailView` ignores the horizontal
        // safe area, only `.top` for the notch bleed, so `proxy.size.width` came
        // back 124pt narrower than the scroll view's true bounds. Pages were
        // sized to that shortfall while the scroll view paged by its real width,
        // producing "current page ends short, next page peeks in" — which reads
        // as progressive drift, since a fixed shortfall reapplies at every step.
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    @ViewBuilder
    private func heroContent(pageWidth: CGFloat) -> some View {
        // `ScrollViewReader` is here so `resyncScrollPosition(using:)` can force
        // an immediate scroll on reappear. It coexists with
        // `.scrollPosition(id:)` below, which stays the source of truth for
        // state; this proxy is only ever a one-shot nudge.
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .bottomTrailing) {
                // A paging `ScrollView` rather than `TabView(.page)`, which is
                // backed by `UIPageViewController` and claims every touch within
                // its bounds, vertical ones included, instead of letting them
                // fall through to an ancestor scroll view the way nested
                // `UIScrollView`s negotiate. That made vertical drags starting on
                // the carousel do nothing. A `ScrollView` is a real
                // `UIScrollView` and cooperates for free.
                ScrollView(.horizontal) {
                    // Plain `HStack`, not `LazyHStack` (what this used to be) —
                    // `loopedItems` is capped at 12 (`HomeViewModel.load()`
                    // fetches at most 10 hero candidates, plus the loop's own 2
                    // duplicate padding pages), cheap to render all of
                    // regardless of scroll position, and eager instantiation is
                    // actually what fixes a real bug rather than just being
                    // "good enough": with `LazyHStack`, a page's
                    // `AsyncRemoteImage` (and the network fetch it kicks off in
                    // `.task`) doesn't exist at all until that page scrolls near
                    // the visible range — for a manual swipe that's a bit early,
                    // but for `tick()`'s *auto*-advance it's exactly the moment
                    // the image is needed, the worst possible timing. Confirmed
                    // live via a recorded+frame-sampled repro on a cold image
                    // cache: several frames of solid white (not even
                    // `AsyncRemoteImage`'s gray placeholder — the page genuinely
                    // had no content mounted yet) between the outgoing item
                    // sliding away and the incoming one's image arriving,
                    // exactly matching the reported "flashes to white" symptom.
                    // An eager `HStack` mounts every page (and starts every
                    // fetch) the moment Home appears, so by the time
                    // auto-advance reaches any given page it's had the full
                    // idle interval, not zero, to load.
                    HStack(spacing: 0) {
                        // `loopedItems.indices`, not `Array(loopedItems
                        // .enumerated())` (an earlier version used that) — the
                        // latter allocates a fresh `[(offset: Int, element:
                        // MediaItem)]` on every single `body` evaluation
                        // (`tick()`'s once-a-second timer among them) despite
                        // `loopedItems` itself now being fixed for this view's
                        // lifetime (see that property's own doc comment for the
                        // matching fix). `Range<Int>.indices` is a cheap value
                        // type, not an allocation, and `loopedItems[offset]`
                        // below is an O(1) array subscript — same result, no
                        // per-render allocation to produce it.
                        ForEach(loopedItems.indices, id: \.self) { offset in
                            HeroRailCard(item: loopedItems[offset])
                                .frame(width: pageWidth)
                                .id(offset)
                        }
                    }
                    .scrollTargetLayout()
                    // Pause-on-touch detection — attached to the `LazyHStack`
                    // (the scroll view's own *content*), not the `ScrollView`
                    // itself below — see `RegionTouchObserver`'s doc comment
                    // for the two earlier, broader-than-necessary attachment
                    // points (window, then the app's root view) that each
                    // caused a real bug, and why attaching to the hero's own
                    // `UIScrollView` specifically avoids both. Placement
                    // matters here too, confirmed via a live view-hierarchy
                    // dump: a `.background` on the `ScrollView` container
                    // itself doesn't end up nested *inside* that scroll view's
                    // own backing `UIScrollView` — walking up from it lands on
                    // the next ancestor scroll view instead (the outer,
                    // vertical Home one, exactly what this must *not* attach
                    // to). A `.background` on the content passed *into* the
                    // scroll view is a genuine descendant of its own
                    // `UIScrollView`, so walking up from there correctly finds
                    // the hero's own one first.
                    .background {
                        RegionTouchObserver { isDown in
                            isInteracting = isDown
                        }
                    }
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollPosition)
                .scrollIndicators(.hidden)
                .scrollDisabled(items.count <= 1)
                .onChange(of: scrollPosition) { _, newValue in
                    guard let newValue else { return }
                    snapIfNeeded(from: newValue)
                }
                // `tick()` zeroes `idleSeconds` on an auto-advance, but a manual
                // swipe changes `scrollPosition` without going through it, so
                // the count carried over from the previous item.
                // `HeroPageIndicator` reads that value, so the fill popped to an
                // arbitrary leftover position instead of starting fresh. Firing
                // redundantly after an auto-advance is harmless.
                .onChange(of: currentIndex) { _, _ in idleSeconds = 0 }
                // Publishes the hero's backdrop luminance so the tab bar over it
                // can pick a legible tint. Keyed on `currentIndex` to re-run on
                // every advance. The hero just displayed the image, so this is a
                // cache hit and a one-pixel downsample rather than a fetch.
                .task(id: currentIndex) { await publishBackdropLuminance() }
                .onReceive(tickTimer) { _ in tick() }

                // Reduce Motion only. Sits directly above the ScrollView at one
                // page's exact frame, standing in for the previously current item
                // while the ScrollView jumps underneath it unanimated.
                if let fadeOutItem {
                    BackdropLogoOverlay(
                        backdropURL: fadeOutItem.backdropImageURL ?? fadeOutItem.primaryImageURL,
                        logoURL: fadeOutItem.logoImageURL,
                        title: fadeOutItem.name,
                        kind: fadeOutItem.kind
                    )
                    .frame(width: pageWidth, height: heroHeight)
                    .opacity(fadeOutOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                if items.count > 1 {
                    HeroPageIndicator(
                        count: items.count,
                        currentIndex: currentIndex,
                        // Not `isInteracting` alone: an invisible Home should
                        // freeze the fill like a held touch does. Core Animation
                        // doesn't care whether anything is on screen, so the fill
                        // would keep animating toward 100% while `tick()` is
                        // gated off and `idleSeconds` isn't advancing, desyncing
                        // on reappearance. `manualCarouselModeEnabled` is treated
                        // the same, since `tick()` never advances `idleSeconds`
                        // while it holds.
                        isPaused: isInteracting || !isVisible || manualCarouselModeEnabled
                    )
                    .padding(16)
                }

                // Replaces the automatic advance `tick()` doesn't perform while
                // `manualCarouselModeEnabled` holds. Vertically centred at the
                // leading and trailing edges, like the Player's VoiceOver-only
                // controls button: a predictable spot in VoiceOver's swipe order
                // that nothing else on this page occupies.
                if manualCarouselModeEnabled, items.count > 1 {
                    HStack {
                        heroNavigationButton(systemImage: "chevron.left", label: String(localized: "Previous Item")) {
                            advance(by: -1)
                        }
                        Spacer()
                        heroNavigationButton(systemImage: "chevron.right", label: String(localized: "Next Item")) {
                            advance(by: 1)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear {
                isOnScreen = true
                resyncScrollPosition(using: scrollProxy)
            }
            .onDisappear { isOnScreen = false }
        }
    }

    @ViewBuilder
    private func heroNavigationButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black.opacity(0.55)))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// Forces the backing `UIScrollView` to jump, unanimated, to wherever
    /// `scrollPosition` says the carousel should be.
    ///
    /// A defensive fallback rather than the primary fix: `tick()` is gated on
    /// `isVisible` and no longer advances `scrollPosition` while Home is covered
    /// or backgrounded, so in the normal case this is a no-op.
    ///
    /// It guards the failure mode that gating closed. A `UIScrollView` detached
    /// from a window can't move itself, so writes to `scrollPosition` while Home
    /// sat under a `.fullScreenCover` left the binding and the on-screen content
    /// desynced with nothing to correct it: the dot indicator kept advancing
    /// while the hero stayed frozen, until a real swipe resynced the scroll view.
    /// `proxy.scrollTo(_:anchor:)` on `.onAppear` is what that swipe did for
    /// free.
    private func resyncScrollPosition(using proxy: ScrollViewProxy) {
        guard let scrollPosition else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(scrollPosition, anchor: .leading)
        }
    }

    /// Advances the carousel once `autoAdvanceInterval` seconds pass with no
    /// finger on it. A no-op with 0 or 1 items, which `loopedItems` doesn't pad.
    ///
    /// Skips the increment while `isInteracting` without resetting `idleSeconds`,
    /// so a touch pauses the countdown in place. `isVisible` is treated the same,
    /// which is what stops `tickTimer` writing state and re-rendering this
    /// subtree while nobody can see it.
    private func tick() {
        guard items.count > 1 else { return }
        guard !isInteracting, isVisible, !manualCarouselModeEnabled else { return }
        idleSeconds += 1
        guard idleSeconds >= Self.autoAdvanceInterval else { return }
        idleSeconds = 0
        advance(by: 1)
    }

    /// Moves the carousel by `delta` pages. Both the automatic advance and the
    /// Previous/Next buttons funnel through this, so a button tap gets the same
    /// reduce-motion-aware treatment. `currentPosition` falls back to `1`: a
    /// `nil` `scrollPosition`, before the first layout pass, still needs a valid
    /// page to advance from.
    private func advance(by delta: Int) {
        guard items.count > 1 else { return }
        var currentPosition = scrollPosition ?? 1
        // A rapid second Previous/Next tap can land before `snapIfNeeded`'s
        // deferred correction runs, leaving `scrollPosition` on a padding index.
        // Normalize first, or `nextPosition` walks off `loopedItems`' bounds.
        // `tick()`'s slower cadence never raced this.
        if currentPosition == 0 {
            currentPosition = items.count
        } else if currentPosition == loopedItems.count - 1 {
            currentPosition = 1
        }
        let nextPosition = currentPosition + delta
        guard reduceMotion else {
            withAnimation(.easeInOut(duration: Self.autoAdvanceAnimationDuration)) {
                scrollPosition = nextPosition
            }
            announceIfNeeded(at: nextPosition)
            return
        }
        advanceWithFade(from: currentPosition, to: nextPosition)
        announceIfNeeded(at: nextPosition)
    }

    /// VoiceOver-only. `advance(by:)` leaves focus on the Previous/Next button
    /// just pressed rather than jumping to the hero card, so someone browsing
    /// can keep pressing it without re-navigating each time — but that would
    /// otherwise cost them hearing what they landed on, since pressing Next
    /// announces only "Next Item, button". An `.announcement` speaks the new item
    /// without moving focus, as a next-track media control does. Reuses
    /// `MediaItem.accessibilityDescription`, the label `HeroRailCard` gives the
    /// same item.
    private func announceIfNeeded(at position: Int) {
        guard voiceOverEnabled else { return }
        let description = loopedItems[position].accessibilityDescription
        // A `.post()` in the same run-loop turn as the button's activation is
        // silently dropped: VoiceOver is still delivering that button's own
        // feedback with nowhere to queue a second announcement. Deferring by the
        // transition's duration gives it a clear turn, and lands the speech as
        // the new card settles rather than mid-motion.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoAdvanceAnimationDuration + 0.2) {
            AccessibilityNotification.Announcement(description).post()
        }
    }

    /// Reduce Motion's replacement for the `withAnimation` slide: the same page
    /// change with no x-axis motion. The position jump is unanimated, via a
    /// `disablesAnimations` transaction, and a crossfade of the outgoing item —
    /// held in `fadeOutItem` and rendered in an overlay above the ScrollView —
    /// stands in for the slide.
    ///
    /// `currentPosition` indexes `loopedItems`, safe to subscript directly since
    /// `advance(by:)` calls this only once `items.count > 1`, which is also what
    /// guarantees `loopedItems` was padded.
    private func advanceWithFade(from currentPosition: Int, to nextPosition: Int) {
        fadeOutItem = loopedItems[currentPosition]
        fadeOutOpacity = 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition = nextPosition
        }
        withAnimation(.easeInOut(duration: Self.autoAdvanceAnimationDuration)) {
            fadeOutOpacity = 0
        }
        // Deferred by the animation's duration, like `snapIfNeeded` below, so the
        // overlay clears once its fade has finished rather than when it starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoAdvanceAnimationDuration) {
            fadeOutItem = nil
        }
    }

    /// Performs the "snap back into the real range" half of the loop trick.
    ///
    /// Deferred by `autoAdvanceAnimationDuration` rather than one run-loop turn.
    /// `onChange(of:)` fires when `scrollPosition`'s state changes — for a
    /// gesture-driven swipe, only once the page has settled, so an immediate
    /// snap is fine; but for `tick()`'s programmatic `withAnimation`, the state
    /// changes while the slide is still playing out. Snapping back with no delay
    /// cut that slide off after a frame or two, reading as a pop rather than a
    /// swipe.
    private func snapIfNeeded(from newValue: Int) {
        guard items.count > 1 else { return }
        let leadingPad = 0
        let trailingPad = loopedItems.count - 1
        guard newValue == leadingPad || newValue == trailingPad else { return }
        let target = newValue == leadingPad ? items.count : 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoAdvanceAnimationDuration) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition = target
            }
        }
    }
}

private struct HeroRailCard: View {
    let item: MediaItem

    var body: some View {
        // Wrapped in a single-child `ZStack` rather than a bare
        // `NavigationLink`, the same freeze fix `PosterCard` and `LibraryCard`
        // carry. This card sits in a plain `HStack` rather than a `LazyHStack`,
        // so it wasn't covered by those, but reproduced the identical signature.
        ZStack {
            NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
                BackdropLogoOverlay(
                    backdropURL: item.backdropImageURL ?? item.primaryImageURL,
                    logoURL: item.logoImageURL,
                    title: item.name,
                    kind: item.kind
                )
            }
            .buttonStyle(.plain)
            // `BackdropLogoOverlay` renders a logo image over the backdrop
            // whenever the item has one, leaving no text for VoiceOver to read.
            // `.ignore` plus an explicit label avoids depending on whether a text
            // fallback happens to be showing.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityIdentifier(A11yID.Media.card(item.id))
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Custom dot page indicator. A plain `ScrollView` has no built-in one, and
/// `TabView`'s could not have hidden `loopedItems`' two padding pages from its
/// dot count anyway.
///
/// The current item's dot expands into a countdown bar whose fill grows over
/// `autoAdvanceInterval` seconds, then retracts once the next item's dot takes
/// over.
///
/// The fill is event-driven via `withAnimation` rather than ticking
/// continuously. Two other approaches failed:
/// - Plain `withAnimation` reassigning the same `@State` on touch to freeze it.
///   `@State` storage for an animated value updates to its target immediately
///   while only the rendered value interpolates, so a mid-flight reassignment
///   doesn't reliably retarget the in-flight interpolation and the fill lurched
///   further right even while held.
/// - `TimelineView(.animation)`, computing the fill from elapsed wall-clock time
///   each frame. Glitch-free, having no animation object to interrupt, but
///   ticking the whole body at ~60Hz pegged the main thread inside this
///   subtree's layout and made the page unresponsive to touch for as long as the
///   indicator ran — which on an auto-advancing carousel is continuous.
///
/// This keeps the `TimelineView` version's accurate bookkeeping
/// (`accumulatedActiveTime`/`resumedAt`, touched only at discrete
/// pause/resume/reset events) and renders it through `withAnimation`, free
/// between those events since Core Animation interpolates without further body
/// evaluation. It never retargets a live animation: `fillGeneration` is bumped at
/// each event and the fill capsule keyed to it with `.id(_:)`, so SwiftUI
/// rebuilds it as a new view that can have no stale in-flight animation.
///
/// Decorative: `.allowsHitTesting(false)` keeps it from intercepting a touch. Its
/// target would be too small to tap reliably anyway — the carousel is driven by
/// swiping the whole hero.
private struct HeroPageIndicator: View {
    let count: Int
    let currentIndex: Int
    /// Freezes the fill exactly where it is, same treatment `HeroRailView
    /// .tick()` gives `idleSeconds` itself — the caller passes `true` for
    /// either a real held touch or (as of 2026-08-24) Home simply not being
    /// visible (backgrounded tab or covered by the Player), so this fill
    /// never keeps animating via Core Animation toward 100% while the real
    /// countdown it's meant to represent isn't actually advancing. Named
    /// for what it does here, not for either specific cause — see the call
    /// site in `heroContent(pageWidth:)` for what feeds into it.
    let isPaused: Bool

    /// Gates both animations below — the countdown fill (omitted from
    /// rendering entirely, not just frozen) and the current-dot width swap
    /// (`.animation(value: currentIndex)` in `body`, disabled outright) —
    /// see `HeroRailView.reduceMotion`'s doc comment for why: both are
    /// "scaling"/"peripheral motion" HIG names explicitly for reduction.
    /// The underlying elapsed-time bookkeeping (`accumulatedActiveTime`/
    /// `resumedAt`, and `animate(from:duration:)`'s own `withAnimation`
    /// calls) keeps running either way — harmless, since nothing renders it
    /// while this is `true`, and simpler than threading a second condition
    /// through that state machine too.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The fill's current position, `0...1`. Only ever set via
    /// `snapInstantly(to:)` or as the target of a `withAnimation` block —
    /// never both for the same `fillGeneration`, so there's exactly one
    /// clear "owner" of any in-flight interpolation at a time.
    @State private var fillProgress: CGFloat = 0
    /// Bumped at every pause/resume/reset, and used as the fill capsule's
    /// `.id(_:)` — see this type's doc comment for why forcing a fresh view
    /// identity, rather than reassigning `fillProgress` on an existing one,
    /// is what actually makes freezing/resuming reliable.
    @State private var fillGeneration = 0
    /// Total unpaused time elapsed toward the current item's countdown,
    /// banked here whenever a pause begins (see `pause()`) — used to
    /// compute exactly where to snap `fillProgress` to at that instant, and
    /// how much time remains for `resume()`'s animation.
    @State private var accumulatedActiveTime: TimeInterval = 0
    /// When the current unpaused stretch began; `nil` while paused.
    @State private var resumedAt: Date?

    private static let dotDiameter: CGFloat = 6
    private static let currentWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.4))
                    .frame(
                        width: index == currentIndex ? Self.currentWidth : Self.dotDiameter,
                        height: Self.dotDiameter
                    )
                    .overlay(alignment: .leading) {
                        if index == currentIndex, !reduceMotion {
                            // The colour media progress bars already use;
                            // `dionysusHighlight` adapts per appearance itself.
                            //
                            // A fixed-size capsule scaled by `fillProgress`
                            // rather than one whose `.frame(width:)` changes:
                            // width is a layout property, and animating it
                            // cascaded into re-laying-out the ancestor
                            // `ScrollView` every frame. `.scaleEffect` only
                            // affects rendering.
                            Capsule()
                                .fill(Color.dionysusHighlight)
                                .frame(width: Self.currentWidth, height: Self.dotDiameter)
                                .scaleEffect(x: fillProgress, y: 1, anchor: .leading)
                                .id(fillGeneration)
                        }
                    }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: HeroRailView.autoAdvanceAnimationDuration), value: currentIndex)
        .allowsHitTesting(false)
        .onAppear { startFresh() }
        .onChange(of: currentIndex) { _, _ in startFresh() }
        .onChange(of: isPaused) { _, paused in
            if paused {
                pause()
            } else {
                resume()
            }
        }
    }

    /// A new item became current, or this is the first render: count from zero.
    /// If still paused — a live swipe can flip through several items with a
    /// touch continuously down — stays paused at zero for `resume()` to pick up.
    private func startFresh() {
        accumulatedActiveTime = 0
        if isPaused {
            resumedAt = nil
            snapInstantly(to: 0)
        } else {
            resumedAt = .now
            animate(from: 0, duration: TimeInterval(HeroRailView.autoAdvanceInterval))
        }
    }

    /// Touch-down: bank the elapsed time and snap the fill to that point, as a
    /// fresh non-animating view.
    private func pause() {
        if let resumedAt {
            accumulatedActiveTime += Date.now.timeIntervalSince(resumedAt)
        }
        resumedAt = nil
        let frozen = min(CGFloat(accumulatedActiveTime / TimeInterval(HeroRailView.autoAdvanceInterval)), 1)
        snapInstantly(to: frozen)
    }

    /// Touch-up: continue from the frozen point, animating only the remaining
    /// time at the uninterrupted rate, so it still reaches 100% as the real
    /// auto-advance fires.
    private func resume() {
        resumedAt = .now
        let remaining = TimeInterval(HeroRailView.autoAdvanceInterval) - accumulatedActiveTime
        guard remaining > 0 else { return }
        animate(from: fillProgress, duration: remaining)
    }

    /// Bumps `fillGeneration`, which the fill capsule's `.id(_:)` is keyed to,
    /// for a fresh instance showing `value` unanimated: a clean base for
    /// `animate(from:duration:)`, or the resting state while paused.
    private func snapInstantly(to value: CGFloat) {
        fillGeneration += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            fillProgress = value
        }
    }

    /// A fresh fill capsule at `base`, then animated to full over `duration`. Two
    /// sequential transactions rather than one, so the new instance exists at
    /// `base` before anything asks it to move.
    private func animate(from base: CGFloat, duration: TimeInterval) {
        snapInstantly(to: base)
        withAnimation(.linear(duration: duration)) {
            fillProgress = 1
        }
    }
}

/// Observes touch-down and touch-up within the hero's horizontal `ScrollView`,
/// without blocking or being blocked by any other gesture recognizer — including
/// Home's outer vertical `ScrollView` several levels up — and without entangling
/// anything outside the hero. Both constraints come from real bugs.
///
/// `.simultaneousGesture(DragGesture(minimumDistance: 0))` avoided blocking the
/// carousel's own paging swipe but still blocked the outer vertical
/// `ScrollView` from seeing a drag that started on the hero: its cooperation
/// doesn't reliably extend past the view it is attached to.
///
/// A raw `UIGestureRecognizer` avoids that, with `cancelsTouchesInView` and both
/// `delaysTouches*` disabled and a delegate that always permits simultaneous
/// recognition. It never leaves `.possible`, so it never recognizes anything in
/// UIKit's terms — a passive observer, structurally unable to block or delay
/// another recognizer.
///
/// Where it attaches matters. On the key window or the app's root view it is an
/// ancestor of everything on screen, and every other recognizer in the app asks
/// it for permission to recognize simultaneously. That left SwiftUI's gesture
/// coordination stuck after swiping the page while an episode tile's overflow
/// menu was open: touch and scroll stopped responding until that menu was opened
/// and closed properly, while UIKit-native controls kept working.
///
/// The requirement is only to be an ancestor of the hero's own content. The
/// hero's horizontal `UIScrollView` is exactly that, and a sibling of everything
/// else on the page, so it can neither block the outer `ScrollView` nor be asked
/// about touches outside the hero. `attachToScrollViewIfNeeded()` locates it.
///
/// Touches are filtered to `hostView.bounds`; see
/// `Coordinator.isTrackingActiveTouch` for why that gates only starting to
/// track a touch.
private struct RegionTouchObserver: UIViewRepresentable {
    var onTouchesChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouchesChanged: onTouchesChanged)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Never part of hit-testing: the recognizer attaches to the hero's
        // `UIScrollView`, and this view exists only to give the coordinator a
        // starting point to walk up from and a `bounds` to filter against.
        view.isUserInteractionEnabled = false
        context.coordinator.hostView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTouchesChanged = onTouchesChanged
        context.coordinator.attachToScrollViewIfNeeded()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTouchesChanged: (Bool) -> Void
        weak var hostView: UIView?
        /// Tracked to detect `hostView` moving to a different window, the signal
        /// to re-walk the hierarchy and re-attach. The recognizer itself attaches
        /// to `attachedHost`.
        private weak var attachedWindow: UIWindow?
        /// The view the recognizer attaches to: the hero's horizontal
        /// `UIScrollView`.
        private weak var attachedHost: UIView?
        private var recognizer: PassthroughTouchRecognizer?

        /// Whether a touch that began inside `hostView.bounds` is down,
        /// independent of where it ends up. Only touch-down checks bounds:
        /// checking symmetrically dropped the "ended" signal whenever a fast
        /// diagonal swipe's finger drifted outside by the time it lifted —
        /// backward swipes drift out more often for a typical grip, matching the
        /// direction-biased flakiness reported. A dropped "ended" left
        /// `isInteracting` stuck `true`, freezing both the indicator's fill and
        /// the auto-advance until some other in-bounds touch delivered a `false`.
        private var isTrackingActiveTouch = false

        init(onTouchesChanged: @escaping (Bool) -> Void) {
            self.onTouchesChanged = onTouchesChanged
        }

        /// A view's `window` is `nil` until inserted into one, so this runs from
        /// `updateUIView` rather than once from `makeUIView`, getting repeated
        /// chances once the window is available. `window !== attachedWindow`
        /// short-circuits after the first successful attach.
        ///
        /// Attaches to the hero's backing `UIScrollView`, found by walking up
        /// `hostView`'s `superview` chain — not the window or root view, for the
        /// reasons in this type's doc comment.
        ///
        /// Placement matters: `hostView` is a `.background` on the stack passed
        /// into `ScrollView(.horizontal)`, a genuine descendant of that scroll
        /// view's `UIScrollView`, so walking up finds it first. A `.background`
        /// on the `ScrollView` container itself is not nested inside it, and
        /// walking up from there lands on Home's outer vertical scroll view —
        /// the over-broad attachment point this exists to avoid. Finding it by
        /// type rather than a fixed number of hops survives SwiftUI changing how
        /// many wrapper views it inserts.
        func attachToScrollViewIfNeeded() {
            guard let window = hostView?.window, window !== attachedWindow else { return }
            guard let scrollView = hostView?.nearestScrollViewAncestor() else { return }
            detach()
            attachedWindow = window
            attachedHost = scrollView
            // Half the fix for the carousel's landscape misalignment. The
            // default `.automatic` `contentInsetAdjustmentBehavior` added a 62pt
            // `adjustedContentInset` on both side edges in landscape — where the
            // Dynamic Island's safe area falls on a side rather than the top —
            // resting the scroll view at content offset -62 from first
            // appearance, with no rotation needed to reproduce.
            //
            // The other half is `body`'s `GeometryReader` reporting a
            // safe-area-reduced `pageWidth` for the same reason. Together pages
            // were 124pt narrower than the scroll view's true bounds, which read
            // as the carousel drifting further off-screen with every swipe.
            //
            // No SwiftUI `ScrollView` modifier reaches this half:
            // `.contentMargins(...)` left the adjusted inset unchanged. Setting
            // it as the scroll view is first found, before any paging math runs,
            // avoids the problem rather than compensating after the fact.
            scrollView.contentInsetAdjustmentBehavior = .never
            let recognizer = PassthroughTouchRecognizer(target: nil, action: nil)
            recognizer.delegate = self
            recognizer.onTouches = { [weak self] touches, isDown in
                guard let self, let hostView = self.hostView, let touch = touches.first else { return }
                if isDown {
                    guard hostView.bounds.contains(touch.location(in: hostView)) else { return }
                    isTrackingActiveTouch = true
                } else {
                    // No bounds check; see `isTrackingActiveTouch`.
                    guard isTrackingActiveTouch else { return }
                    isTrackingActiveTouch = false
                }
                self.onTouchesChanged(isDown)
            }
            scrollView.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer, let attachedHost {
                attachedHost.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            attachedWindow = nil
            attachedHost = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// The recognizer `RegionTouchObserver` attaches to the hero's backing
/// `UIScrollView`. Reports raw touch-down and touch-up through `onTouches`
/// without ever transitioning its `state`, which keeps it observational: a
/// recognizer that never leaves `.possible` never wins, never fires an action,
/// and never requires another to fail.
private final class PassthroughTouchRecognizer: UIGestureRecognizer {
    var onTouches: ((Set<UITouch>, Bool) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouches?(touches, true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouches?(touches, false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouches?(touches, false)
    }
}

/// `UserDefaults` key for `ProfileView`'s "Auto Carousel on Home" toggle, shared
/// so `HeroRailView`'s `@AppStorage` reads what `ProfileView` writes.
let heroAutoCarouselEnabledStorageKey = "heroAutoCarouselEnabled"

#Preview {
    HeroRailView(items: [], isTabActive: true)
}
