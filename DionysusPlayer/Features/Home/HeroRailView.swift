import SwiftUI
import UIKit

/// Home's top section: a full-bleed, swipeable "hero" banner — a random mix
/// of unwatched movies and series (see `HomeViewModel.load()`), each shown
/// as its own backdrop+logo page via `BackdropLogoOverlay`. Deliberately
/// titleless (no "Continue Watching"-style header row) — the backdrop/logo
/// itself carries the item's identity, and a header row would fight the
/// full-bleed treatment.
///
/// Bleeding up under the status bar/notch relies on `HomeView`'s `ScrollView`
/// declaring `.ignoresSafeArea(edges: .top)` — a `ScrollView` clips its
/// content to its own bounds, so this view alone ignoring the safe area
/// would have nothing to bleed into.
struct HeroRailView: View {
    let items: [MediaItem]

    /// Custom init so `scrollPosition`'s starting value can account for
    /// whether `loopedItems` actually pads `items` — with 0 or 1 items it
    /// doesn't (looping a single page is meaningless), so `scrollPosition`
    /// must start at `0` rather than the usual `1`, or it would reference an
    /// `.id` that doesn't exist and the carousel would render blank.
    init(items: [MediaItem]) {
        self.items = items
        _scrollPosition = State(initialValue: items.count > 1 ? 1 : 0)
    }

    /// Tracked purely to force `body` to re-run on rotation, the same
    /// reason `HeroHeaderView` reads `verticalSizeClass` — `screenHeight`/
    /// `statusBarInset` below are plain UIKit reads, and SwiftUI has no way
    /// to know `body` depends on them unless *something* here is a tracked
    /// dependency.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Same check `HeroHeaderView` uses, for the same reason (see that
    /// view's `verticalSizeClass` doc comment) — `.compact` is iPhone's
    /// landscape signal.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Deliberately the key window's own bounds, not `UIScreen.main` (soft
    /// deprecated, and doesn't reflect a resized scene under iPadOS Stage
    /// Manager) — same reasoning as `HeroHeaderView.statusBarInset`.
    private var screenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)?
            .bounds.height ?? 800
    }

    /// Same raw hardware inset `HeroHeaderView` uses (status bar/notch only,
    /// not the nav bar) — see that view's doc comment for why it has to be
    /// this rather than the ambient `safeAreaInsets`.
    private var statusBarInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    /// Portrait: a third of the screen, stretched 25% taller, *plus*
    /// `statusBarInset` so bleeding up under the notch is pure upward
    /// growth rather than eating into that 1.25x budget — without the
    /// addition, reaching the notch and "25% taller" would fight over the
    /// same height instead of both actually happening. Landscape instead
    /// goes straight to 75% of the screen — a third-of-portrait-height
    /// formula would read as far too short once the screen itself is much
    /// shorter, so landscape gets its own, larger fraction rather than
    /// reusing the portrait math. `screenHeight` already reflects whichever
    /// orientation is current (the key window's `bounds` rotate with the
    /// device), so no separate landscape screen-height read is needed.
    private var heroHeight: CGFloat {
        guard !isLandscape else { return screenHeight * 0.75 }
        return statusBarInset + screenHeight / 3 * 1.25
    }

    /// Indexes into `loopedItems`, not `items` — see that property's doc
    /// comment. Starts at `1`, the first *real* page once the leading
    /// duplicate is accounted for. Optional (not a plain `Int`, unlike the
    /// old `TabView`-based `selection`) because that's what `.scrollPosition
    /// (id:)` requires — it can transiently be `nil` (e.g. before the first
    /// layout pass resolves), which every reader of this below already
    /// accounts for.
    @State private var scrollPosition: Int?

    /// `items` padded with a duplicate of the last item in front and the
    /// first item behind, so a swipe off either end of the real range still
    /// lands on a page showing the correct "next" item instead of stopping.
    /// `onChange(of:)` below then snaps `scrollPosition` back into the real
    /// range with animation disabled once that swipe's own animation has
    /// landed — the duplicate page makes the swipe itself look continuous,
    /// and the snap-back is invisible because the duplicate and the real
    /// page it stands in for are pixel-identical. Standard workaround for
    /// "infinite" paging, which has no native loop mode.
    private var loopedItems: [MediaItem] {
        guard let first = items.first, let last = items.last, items.count > 1 else { return items }
        return [last] + items + [first]
    }

    /// `scrollPosition` translated back into `items`' index space, for the
    /// dot indicator — the indicator should never show the padding pages.
    private var currentIndex: Int {
        guard items.count > 1, let scrollPosition else { return 0 }
        return (scrollPosition - 1 + items.count) % items.count
    }

    /// Whether a finger is currently down on the carousel — tracked via
    /// `RegionTouchObserver` below (a raw `UIGestureRecognizer`, not
    /// anything the scroll view exposes natively, which it doesn't) rather
    /// than a SwiftUI `DragGesture`; see that type's doc comment for why.
    @State private var isInteracting = false

    /// Seconds elapsed since the current item became current, ticked up by
    /// `tickTimer` but held steady (not reset) while `isInteracting` is
    /// true — touching the carousel pauses the countdown exactly where it
    /// was, rather than restarting it, so `tick()` picks back up from the
    /// same partway-elapsed point once the finger lifts. `HeroPageIndicator`
    /// mirrors this same pause/resume for its own fill, rather than each
    /// tracking it independently.
    @State private var idleSeconds = 0

    /// `fileprivate`, not `private` — `HeroPageIndicator` below (a sibling
    /// type in this same file) needs both constants too, to keep its
    /// countdown-fill animation locked to the exact same timing rather than
    /// duplicating the numbers and risking the two drifting apart.
    fileprivate static let autoAdvanceInterval = 5

    /// Duration of the auto-advance's own page-slide animation — kept as a
    /// named constant because `snapIfNeeded` needs to wait at least this
    /// long before performing the loop's silent snap-back, or it cuts the
    /// slide off before it finishes (see that function's doc comment).
    fileprivate static let autoAdvanceAnimationDuration: TimeInterval = 0.35

    /// Ticks once a second; `tick()` itself is what actually holds
    /// `idleSeconds` steady while `isInteracting` is true.
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // `ScrollView(.horizontal) + .scrollTargetBehavior(.paging)`,
            // not `TabView(.page)` (what this used to be) — `TabView(.page)`
            // is backed by `UIPageViewController`, which is known to
            // aggressively claim touches within its own bounds, including
            // vertical ones, rather than letting them fall through to an
            // ancestor scroll view the way nested `UIScrollView`s normally
            // negotiate (this is exactly how e.g. the App Store's own
            // horizontal "Featured" carousels let you start a vertical drag
            // directly on top of them to scroll the whole page). A plain
            // `ScrollView` is a real `UIScrollView` under the hood and gets
            // that same built-in cooperative behavior for free, which is
            // the whole reason for this rewrite: reported bug was "can't
            // drag/scroll starting from the hero carousel, only from areas
            // below it."
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(loopedItems.enumerated()), id: \.offset) { offset, item in
                        HeroRailCard(item: item)
                            .containerRelativeFrame(.horizontal)
                            .id(offset)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollPosition)
            .scrollIndicators(.hidden)
            .scrollDisabled(items.count <= 1)
            .onChange(of: scrollPosition) { _, newValue in
                guard let newValue else { return }
                snapIfNeeded(from: newValue)
            }
            // `tick()`'s own auto-advance already zeroes `idleSeconds`
            // directly, but that's the only path that did — a *manual*
            // swipe changes `scrollPosition`/`currentIndex` without ever
            // going through `tick()`, so without this, `idleSeconds` kept
            // counting up from whatever the previous item's elapsed time
            // was instead of restarting for the newly-current item. That
            // stale value is exactly what `HeroPageIndicator` reads to
            // freeze/resume its fill, so the bug showed up there as the
            // fill popping to some arbitrary leftover position instead of
            // starting fresh — harmless to also fire redundantly right
            // after an auto-advance (idleSeconds is already 0 by then).
            .onChange(of: currentIndex) { _, _ in idleSeconds = 0 }
            // Pause-on-touch detection — see `RegionTouchObserver`'s doc
            // comment for why this isn't a SwiftUI `DragGesture` (that
            // approach was tried first; confirmed via a temporary test
            // build to be exactly what was blocking dragging down from the
            // hero to scroll Home, even with `.simultaneousGesture`).
            .background {
                RegionTouchObserver { isDown in
                    isInteracting = isDown
                }
            }
            .onReceive(tickTimer) { _ in tick() }

            if items.count > 1 {
                HeroPageIndicator(
                    count: items.count,
                    currentIndex: currentIndex,
                    isInteracting: isInteracting
                )
                .padding(16)
            }
        }
        .frame(height: heroHeight)
    }

    /// Advances the carousel once `autoAdvanceInterval` seconds have passed
    /// with no finger on it. A no-op with 0 or 1 items — nothing to advance
    /// to, and `loopedItems`/`snapIfNeeded` aren't set up to loop in that
    /// case (see `loopedItems`'s doc comment). Simply skips the increment
    /// while `isInteracting` — not resetting `idleSeconds` — so a touch
    /// pauses the countdown in place rather than restarting it; `tick()`
    /// picks back up from the same count once the finger lifts.
    private func tick() {
        guard items.count > 1 else { return }
        guard !isInteracting else { return }
        idleSeconds += 1
        guard idleSeconds >= Self.autoAdvanceInterval else { return }
        idleSeconds = 0
        withAnimation(.easeInOut(duration: Self.autoAdvanceAnimationDuration)) {
            scrollPosition = (scrollPosition ?? 1) + 1
        }
    }

    /// Performs the "snap back into the real range" half of the loop trick.
    ///
    /// Deferred by `autoAdvanceAnimationDuration`, not just one run-loop
    /// turn — `onChange(of:)` fires the instant `scrollPosition`'s *state*
    /// changes, which for a gesture-driven swipe is only once the page has
    /// already visually settled (so snapping back right away is fine, the
    /// slide is already done), but for a *programmatic* change like
    /// `tick()`'s `withAnimation` call, the state changes immediately while
    /// the slide animation is still playing out over the next
    /// `autoAdvanceAnimationDuration` seconds in the background. Snapping
    /// back too early — the original `DispatchQueue.main.async` with no
    /// delay — cut that slide off after only a frame or two, which looked
    /// like a fade/pop instead of a swipe. Waiting out the animation's own
    /// duration lets it finish before the (still instant, still invisible —
    /// the two pages are pixel-identical) snap happens.
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
        NavigationLink(value: AppRoute.assetDetail(itemID: item.id, preloadedItem: item)) {
            BackdropLogoOverlay(item: item)
        }
        .buttonStyle(.plain)
    }
}

/// Custom dot page indicator — the `TabView`-based version of this carousel
/// used to hide `TabView`'s native one via `indexDisplayMode: .never` since
/// it had no way to hide `loopedItems`' two padding pages from its dot
/// count; a plain `ScrollView` has no built-in page indicator at all, so
/// this is now the only one either way.
///
/// The current item's dot expands into a small countdown bar — its fill
/// grows from empty to full over exactly `autoAdvanceInterval` seconds —
/// then retracts back to a plain dot once the carousel advances and the
/// next item's dot takes over. Prototyped as a standalone mockup and
/// reviewed before landing here (tap-to-jump dots and a dedicated
/// hold-to-pause region existed in that prototype but are deliberately not
/// carried over — see `isInteracting`'s doc comment below).
///
/// The fill's width is computed fresh every frame from wall-clock time
/// (`TimelineView`) rather than driven through `withAnimation` — two
/// earlier versions tried the latter and both produced visible glitches
/// that trace back to the same root cause: SwiftUI's `@State` storage for
/// an animated value updates to its *target* immediately, with only the
/// *rendered* value interpolating over time, so touch handling that reads
/// or reassigns that `@State` is working with the wrong number (target,
/// not current-on-screen), and reassigning it mid-flight to "freeze" the
/// animation isn't reliably honored — the prior in-flight animation could
/// keep interpolating toward its old target regardless, which looked like
/// the fill lurching further right even while held. Computing the fill as
/// a pure function of elapsed time — with pausing implemented as "stop
/// advancing the clock," not "cancel an animation" — has no in-flight
/// animation to fight with, so there's nothing left to glitch.
///
/// Purely decorative: `.allowsHitTesting(false)` guarantees it never
/// intercepts a touch, even though it has no gesture recognizers of its own
/// to begin with. Its hit target would be too small to reliably tap
/// anyway — the carousel is driven entirely by swiping the whole hero
/// (already handled by the `ScrollView` + `RegionTouchObserver` above),
/// not by touching the indicator itself.
private struct HeroPageIndicator: View {
    let count: Int
    let currentIndex: Int
    let isInteracting: Bool

    /// Total unpaused time elapsed toward the current item's countdown,
    /// banked here whenever a pause begins (see `pause()`) — the fill's
    /// width is this plus whatever's elapsed since `resumedAt`, so pausing
    /// is just "stop adding to it," never a cancelled animation.
    @State private var accumulatedActiveTime: TimeInterval = 0
    /// When the current unpaused stretch began; `nil` while paused, so
    /// `progress(at:)` adds nothing further until `resume()` sets a new
    /// one.
    @State private var resumedAt: Date? = .now

    private static let dotDiameter: CGFloat = 6
    private static let currentWidth: CGFloat = 24

    var body: some View {
        TimelineView(.animation(paused: isInteracting)) { context in
            let progress = progress(at: context.date)
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(
                            width: index == currentIndex ? Self.currentWidth : Self.dotDiameter,
                            height: Self.dotDiameter
                        )
                        .overlay(alignment: .leading) {
                            if index == currentIndex {
                                // Same colour used for media (e.g.
                                // poster/rail tile) progress bars, in both
                                // Light and Dark — `dionysusHighlight` is
                                // already a dynamic colour that adapts per
                                // appearance on its own.
                                Capsule()
                                    .fill(Color.dionysusHighlight)
                                    .frame(width: Self.currentWidth * progress)
                            }
                        }
                }
            }
            .animation(.easeInOut(duration: HeroRailView.autoAdvanceAnimationDuration), value: currentIndex)
        }
        .allowsHitTesting(false)
        .onAppear { resetSegment() }
        .onChange(of: currentIndex) { _, _ in resetSegment() }
        .onChange(of: isInteracting) { _, interacting in
            if interacting {
                pause()
            } else {
                resume()
            }
        }
    }

    /// Elapsed-fraction of `autoAdvanceInterval`, as of `now`. Purely a
    /// function of `accumulatedActiveTime`/`resumedAt` — no animation
    /// object involved, so there's nothing to retarget or interrupt.
    private func progress(at now: Date) -> CGFloat {
        let liveElapsed = accumulatedActiveTime + (resumedAt.map { now.timeIntervalSince($0) } ?? 0)
        return min(CGFloat(liveElapsed / TimeInterval(HeroRailView.autoAdvanceInterval)), 1)
    }

    /// A new item just became current (or this is the very first render) —
    /// start from zero elapsed time. If a touch is still down (a live swipe
    /// can flip through several items while `isInteracting` stays
    /// continuously true), stays paused at zero rather than starting to
    /// count — `resume()` will pick it up once the finger actually lifts.
    private func resetSegment() {
        accumulatedActiveTime = 0
        resumedAt = isInteracting ? nil : .now
    }

    /// Touch-down: bank whatever's elapsed so far and stop the clock.
    private func pause() {
        if let resumedAt {
            accumulatedActiveTime += Date.now.timeIntervalSince(resumedAt)
        }
        resumedAt = nil
    }

    /// Touch-up: resume from exactly the banked elapsed time, at the same
    /// rate as before — no separate "remaining duration" bookkeeping
    /// needed, since `progress(at:)` just keeps adding to
    /// `accumulatedActiveTime` from here.
    private func resume() {
        resumedAt = .now
    }
}

/// Observes touch-down/touch-up specifically within this view's own
/// bounds, without ever blocking (or being blocked by) any other gesture
/// recognizer anywhere in the view hierarchy — including several levels
/// up, which turned out to matter here.
///
/// A SwiftUI `.simultaneousGesture(DragGesture(minimumDistance: 0))` was
/// tried first for this. It reliably avoided blocking the carousel's *own*
/// paging swipe (that part always worked), but empirically still blocked
/// the *outer* vertical `ScrollView` several levels up from ever seeing a
/// drag that started on the hero — confirmed by temporarily removing it
/// entirely, which fixed dragging down from the hero to scroll Home.
/// `.simultaneousGesture`'s cooperation, in other words, doesn't reliably
/// extend past the view it's directly attached to.
///
/// This sidesteps that by attaching a raw `UIGestureRecognizer` to the key
/// window itself — the one view guaranteed to be an ancestor of literally
/// everything on screen — with `cancelsTouchesInView`/`delaysTouchesBegan`/
/// `delaysTouchesEnded` all disabled and a delegate that unconditionally
/// permits simultaneous recognition with anything it's asked about. It
/// never transitions its own `state` away from `.possible` either, so it
/// never "recognizes" anything in UIKit's own terms — purely a passive
/// observer of the raw touch stream, which is what makes it structurally
/// unable to block or delay any other gesture recognizer, unlike relying
/// on `.simultaneousGesture`'s own (apparently limited) internal
/// cooperation logic. Touches are filtered to this view's own bounds
/// (`hostView.bounds.contains(location)`) since a window-attached
/// recognizer otherwise sees every touch anywhere on screen — but see
/// `Coordinator.isTrackingActiveTouch`'s doc comment for why that bounds
/// check only gates *starting* to track a touch, not whether its "ended"
/// signal gets delivered.
private struct RegionTouchObserver: UIViewRepresentable {
    var onTouchesChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouchesChanged: onTouchesChanged)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Never itself part of hit-testing — the recognizer that actually
        // observes touches is attached to the window, not this view; this
        // view exists only to give the coordinator a `window` to find and
        // a `bounds` to filter touch locations against.
        view.isUserInteractionEnabled = false
        context.coordinator.hostView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTouchesChanged = onTouchesChanged
        context.coordinator.attachToWindowIfNeeded()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTouchesChanged: (Bool) -> Void
        weak var hostView: UIView?
        private weak var attachedWindow: UIWindow?
        private var recognizer: PassthroughTouchRecognizer?

        /// Whether a touch that began inside `hostView.bounds` is currently
        /// down, tracked independently of where that touch's location ends
        /// up. Only the touch-*down* bounds check should gate anything —
        /// checking bounds symmetrically for touch-*up* too (an earlier
        /// version did this, re-testing `hostView.bounds.contains(...)` for
        /// both) silently dropped the "ended" signal whenever a swipe's
        /// finger drifted outside the hero's bounds by the moment it lifted
        /// (a real, if occasional, thing for a fast diagonal-ish swipe —
        /// backward swipes apparently drift out of bounds more often than
        /// forward ones for a typical grip, matching the reported
        /// direction-biased flakiness). A dropped "ended" left
        /// `isInteracting` stuck `true` forever, since nothing else would
        /// ever tell it the touch was over — which froze both the
        /// indicator's fill and the real auto-advance (both gate on it)
        /// until some *other*, cleanly-in-bounds touch happened to deliver
        /// a fresh `false`.
        private var isTrackingActiveTouch = false

        init(onTouchesChanged: @escaping (Bool) -> Void) {
            self.onTouchesChanged = onTouchesChanged
        }

        /// A view's `window` is `nil` until it's actually been inserted
        /// into a real window, so this is called from `updateUIView`
        /// (invoked repeatedly as SwiftUI updates) rather than just once
        /// from `makeUIView`, giving it multiple chances to succeed once
        /// the window becomes available. `window !== attachedWindow`
        /// short-circuits everything after the first successful attach.
        func attachToWindowIfNeeded() {
            guard let window = hostView?.window, window !== attachedWindow else { return }
            detach()
            attachedWindow = window
            let recognizer = PassthroughTouchRecognizer(target: nil, action: nil)
            recognizer.delegate = self
            recognizer.onTouches = { [weak self] touches, isDown in
                guard let self, let hostView = self.hostView, let touch = touches.first else { return }
                if isDown {
                    guard hostView.bounds.contains(touch.location(in: hostView)) else { return }
                    isTrackingActiveTouch = true
                } else {
                    // No bounds check here on purpose — see
                    // `isTrackingActiveTouch`'s doc comment.
                    guard isTrackingActiveTouch else { return }
                    isTrackingActiveTouch = false
                }
                self.onTouchesChanged(isDown)
            }
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer, let attachedWindow {
                attachedWindow.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            attachedWindow = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// The actual `UIGestureRecognizer` `RegionTouchObserver` attaches to the
/// window — see that type's doc comment for the full reasoning. Reports
/// raw touch-down/up via `onTouches` without ever transitioning its own
/// `state`, which is what keeps it purely observational (a gesture
/// recognizer that never leaves `.possible` never "wins," never fires an
/// action, and never requires any other recognizer to fail).
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

#Preview {
    HeroRailView(items: [])
}
