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
    /// `.id` that doesn't exist and the carousel would render blank. Also
    /// where `loopedItems` itself gets computed — see that property's doc
    /// comment for why doing it here, once, rather than as a `body`-time
    /// computed property, actually matters.
    init(items: [MediaItem]) {
        self.items = items
        self.loopedItems = Self.loop(items)
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
    ///
    /// A stored `let`, computed once in `init` — not a `body`-time computed
    /// property (an earlier version was), which rebuilt this padded array
    /// from scratch on *every* `body` evaluation, including every one of
    /// `tick()`'s once-a-second ticks, even though it depends only on
    /// `items`, which never changes for a given `HeroRailView` instance.
    let loopedItems: [MediaItem]

    private static func loop(_ items: [MediaItem]) -> [MediaItem] {
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
    /// `RegionTouchObserver` below (a raw `UIGestureRecognizer` attached to
    /// the hero's own `UIScrollView`, not anything the scroll view exposes
    /// natively, which it doesn't, and not a SwiftUI `DragGesture`; see
    /// that type's doc comment for why, including two earlier, broader
    /// attachment points that each caused their own real bug).
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
/// The fill is driven by `withAnimation`, event-driven rather than ticking
/// continuously — two earlier versions of this tried other approaches and
/// both had real problems:
/// - Plain `withAnimation`, reassigning the same `@State` on touch to
///   "freeze" it: unreliable in practice. SwiftUI's `@State` storage for an
///   animated value updates to its *target* immediately, with only the
///   *rendered* value interpolating over time, so a reassignment mid-flight
///   doesn't reliably retarget the already-in-flight interpolation — it
///   could keep animating toward its old target regardless, which looked
///   like the fill lurching further right even while held.
/// - `TimelineView(.animation)`, computing the fill as a pure function of
///   elapsed wall-clock time every frame: glitch-free (nothing to
///   interrupt, since there's no animation object at all), but ticking the
///   view's whole body at ~60/sec turned out to be genuinely expensive —
///   a live CPU sample during a reported freeze showed the main thread
///   permanently stuck inside this subtree's layout, pegging the CPU and
///   making the page unresponsive to touch for as long as the indicator
///   was running (which, on an actively auto-advancing carousel, is
///   essentially all the time — each item's countdown ends right as the
///   next one's begins).
///
/// This version keeps the accurate elapsed-time bookkeeping the
/// `TimelineView` version already got right (`accumulatedActiveTime`/
/// `resumedAt`, only touched at discrete pause/resume/reset events, not
/// every frame) but renders it via `withAnimation` — genuinely free
/// between those events, since Core Animation interpolates it without any
/// further SwiftUI body re-evaluation — and sidesteps the "reassignment
/// doesn't reliably retarget" problem by never reassigning a live
/// animation's target at all: `fillGeneration` is bumped at every
/// pause/resume/reset, and the fill capsule is keyed to it via `.id(_:)`,
/// forcing SwiftUI to tear down and rebuild it as a *completely new* view
/// each time rather than asking the existing one to retarget. A brand-new
/// view can't have a stale in-flight animation to conflict with — it was
/// never around to have one.
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
                        if index == currentIndex {
                            // Same colour used for media (e.g. poster/rail
                            // tile) progress bars, in both Light and Dark —
                            // `dionysusHighlight` is already a dynamic
                            // colour that adapts per appearance on its own.
                            //
                            // A fixed-size capsule scaled by `fillProgress`
                            // (a render-time transform) rather than one
                            // whose `.frame(width:)` itself changes —
                            // `.frame(width:)` is a *layout* property, and
                            // animating it turned out to cascade into
                            // re-laying-out the ancestor `ScrollView` on
                            // every frame (see this type's doc comment).
                            // `.scaleEffect` only affects rendering.
                            Capsule()
                                .fill(Color.dionysusHighlight)
                                .frame(width: Self.currentWidth, height: Self.dotDiameter)
                                .scaleEffect(x: fillProgress, y: 1, anchor: .leading)
                                .id(fillGeneration)
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: HeroRailView.autoAdvanceAnimationDuration), value: currentIndex)
        .allowsHitTesting(false)
        .onAppear { startFresh() }
        .onChange(of: currentIndex) { _, _ in startFresh() }
        .onChange(of: isInteracting) { _, interacting in
            if interacting {
                pause()
            } else {
                resume()
            }
        }
    }

    /// A new item just became current (or this is the very first render) —
    /// start counting from zero. If a touch is still down (a live swipe can
    /// flip through several items while `isInteracting` stays continuously
    /// true), stays paused at zero rather than starting to count —
    /// `resume()` will pick it up once the finger actually lifts.
    private func startFresh() {
        accumulatedActiveTime = 0
        if isInteracting {
            resumedAt = nil
            snapInstantly(to: 0)
        } else {
            resumedAt = .now
            animate(from: 0, duration: TimeInterval(HeroRailView.autoAdvanceInterval))
        }
    }

    /// Touch-down: bank whatever's elapsed so far and snap the fill to
    /// exactly that point, as a fresh, non-animating view (see this type's
    /// doc comment for why a fresh `.id(_:)` matters here).
    private func pause() {
        if let resumedAt {
            accumulatedActiveTime += Date.now.timeIntervalSince(resumedAt)
        }
        resumedAt = nil
        let frozen = min(CGFloat(accumulatedActiveTime / TimeInterval(HeroRailView.autoAdvanceInterval)), 1)
        snapInstantly(to: frozen)
    }

    /// Touch-up: continue from exactly the frozen point, animating only
    /// the remaining time — at the same overall rate as an uninterrupted
    /// `autoAdvanceInterval` — so it still lands at 100% around when the
    /// real auto-advance fires.
    private func resume() {
        resumedAt = .now
        let remaining = TimeInterval(HeroRailView.autoAdvanceInterval) - accumulatedActiveTime
        guard remaining > 0 else { return }
        animate(from: fillProgress, duration: remaining)
    }

    /// Forces a fresh fill-capsule instance (bumping `fillGeneration`,
    /// which the view's `.id(_:)` is keyed to) showing `value` immediately,
    /// with no animation — a clean base for `animate(from:duration:)` to
    /// build on next, or simply the correct static resting state while
    /// paused.
    private func snapInstantly(to value: CGFloat) {
        fillGeneration += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            fillProgress = value
        }
    }

    /// Forces a fresh fill-capsule instance starting at `base`, then
    /// animates it to full over `duration` — two separate, sequential
    /// transactions (snap, then animate), not one combined change, so the
    /// fresh instance genuinely starts existing at `base` before anything
    /// asks it to move.
    private func animate(from base: CGFloat, duration: TimeInterval) {
        snapInstantly(to: base)
        withAnimation(.linear(duration: duration)) {
            fillProgress = 1
        }
    }
}

/// Observes touch-down/touch-up specifically within the hero's own
/// horizontal `ScrollView`'s bounds, without ever blocking (or being
/// blocked by) any other gesture recognizer — including several levels up
/// (the outer, vertical Home `ScrollView`), which turned out to matter, and
/// without being entangled with anything *outside* the hero either, which
/// separately turned out to matter just as much. Both constraints came from
/// real, empirically-confirmed bugs — see below.
///
/// A SwiftUI `.simultaneousGesture(DragGesture(minimumDistance: 0))` was
/// tried first. It reliably avoided blocking the carousel's *own* paging
/// swipe (that part always worked), but empirically still blocked the
/// *outer* vertical `ScrollView` several levels up from ever seeing a drag
/// that started on the hero — confirmed by temporarily removing it
/// entirely, which fixed dragging down from the hero to scroll Home.
/// `.simultaneousGesture`'s cooperation, in other words, doesn't reliably
/// extend past the view it's directly attached to.
///
/// That was sidestepped by attaching a raw `UIGestureRecognizer` instead —
/// first to the key window, then (after that caused a *second* bug, below)
/// to the app's root view — with `cancelsTouchesInView`/
/// `delaysTouchesBegan`/`delaysTouchesEnded` all disabled and a delegate
/// that unconditionally permits simultaneous recognition with anything it's
/// asked about. It never transitions its own `state` away from `.possible`
/// either, so it never "recognizes" anything in UIKit's own terms — purely
/// a passive observer, which is what makes it structurally unable to block
/// or delay any other gesture recognizer, unlike `.simultaneousGesture`'s
/// own (apparently limited) internal cooperation logic. Both of those
/// attachment points are ancestors of literally everything on screen, which
/// is *more* than this actually needs — and turned out to be actively
/// harmful: reported symptom was that swiping the page while an episode
/// tile's "⋯" menu was open (which dismisses the menu, same as swiping
/// anywhere else would) worked exactly once, after which touch/scroll on
/// the whole page stopped responding, until opening and properly closing
/// that menu again. Since a recognizer this broadly attached is asked by
/// *every other* recognizer in the app — including whatever backs the
/// menu's own presentation — for permission to recognize simultaneously,
/// something about that (unconfirmed exactly what, even with a live
/// debugger attached mid-freeze) was leaving SwiftUI's own gesture
/// coordination for ordinary content stuck, while raw UIKit-native controls
/// like the menu's own button weren't affected.
///
/// The actual requirement was never "see every touch in the app" — just
/// "be an ancestor of the hero's own content, so touches there aren't
/// blocked or delayed on their way to it." The hero's own horizontal
/// `UIScrollView` satisfies that exactly, and is *only* an ancestor of the
/// hero's own content — a sibling of, not an ancestor of, everything else
/// on the page (other rails, menus, etc.) — so attaching there instead
/// structurally cannot repeat either bug: it can't block the outer
/// `ScrollView` (unchanged non-blocking configuration), and it can't
/// interfere with anything outside the hero (it's simply never asked,
/// since it isn't in those touches' hit-test chain at all). See
/// `attachToScrollViewIfNeeded()` for how that scroll view is located.
/// Touches are additionally filtered to this view's own bounds
/// (`hostView.bounds.contains(location)`, effectively the whole hero here)
/// — see `Coordinator.isTrackingActiveTouch`'s doc comment for why that
/// bounds check only gates *starting* to track a touch, not whether its
/// "ended" signal gets delivered.
private struct RegionTouchObserver: UIViewRepresentable {
    var onTouchesChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouchesChanged: onTouchesChanged)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Never itself part of hit-testing — the recognizer that actually
        // observes touches is attached to the hero's own `UIScrollView`,
        // not this view; this view exists only to give the coordinator a
        // starting point to walk up from (see `attachToScrollViewIfNeeded()`)
        // and a `bounds` to filter touch locations against.
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
        /// Tracked purely to detect when `hostView` moves to a *different*
        /// window (rare, but possible), which is the signal to re-walk the
        /// hierarchy and re-attach — the recognizer itself attaches to
        /// `attachedHost` below, not this.
        private weak var attachedWindow: UIWindow?
        /// The view the recognizer is actually attached to — the hero's
        /// own horizontal `UIScrollView` (see
        /// `attachToScrollViewIfNeeded()`'s doc comment).
        private weak var attachedHost: UIView?
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
        ///
        /// Attaches to the hero's own backing `UIScrollView` — found by
        /// walking up `hostView`'s `superview` chain until the first
        /// `UIScrollView` is found — not the window or the app's root view
        /// (two earlier versions used each of those in turn; see this
        /// type's doc comment for the two separate bugs that traces back
        /// to). `hostView` is placed as a `.background` on the
        /// `LazyHStack` passed *into* `ScrollView(.horizontal)` in
        /// `HeroRailView`'s `body` — a genuine descendant of that scroll
        /// view's own backing `UIScrollView` (`SwiftUI.HostingScrollView`),
        /// so walking up finds it first. Confirmed via a live
        /// view-hierarchy dump that this placement matters: a `.background`
        /// on the `ScrollView` container itself (what an earlier version of
        /// this used) is *not* actually nested inside that scroll view's
        /// own `UIScrollView` — walking up from there skipped right past
        /// it and landed on the next ancestor scroll view instead (Home's
        /// own outer, vertical one), which is exactly the over-broad
        /// attachment point this whole rewrite exists to avoid. Walking up
        /// to find it by type, rather than assuming a fixed number of
        /// `superview` hops, is robust to SwiftUI changing exactly how many
        /// wrapper views it inserts between them across versions.
        func attachToScrollViewIfNeeded() {
            guard let window = hostView?.window, window !== attachedWindow else { return }
            guard let scrollView = nearestScrollViewAncestor() else { return }
            detach()
            attachedWindow = window
            attachedHost = scrollView
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
            scrollView.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        private func nearestScrollViewAncestor() -> UIScrollView? {
            var candidate = hostView?.superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView { return scrollView }
                candidate = view.superview
            }
            return nil
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

/// The actual `UIGestureRecognizer` `RegionTouchObserver` attaches to the
/// app's root view — see that type's doc comment for the full reasoning. Reports
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
