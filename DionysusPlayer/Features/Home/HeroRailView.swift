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

    /// Seconds elapsed since the last auto-advance, or since the user last
    /// touched the carousel — reset directly from the drag gesture's
    /// `onChanged`/`onEnded` (not just sampled by `tick()`, see below),
    /// ticked up by `tickTimer`. Deliberately a counted `@State` int over a
    /// longer-period `Timer` directly on `autoAdvanceInterval`, so a touch
    /// always buys a full fresh `autoAdvanceInterval` of undisturbed
    /// viewing after release, rather than resuming a countdown that was
    /// already partway elapsed when the touch began.
    @State private var idleSeconds = 0

    private static let autoAdvanceInterval = 5

    /// Duration of the auto-advance's own page-slide animation — kept as a
    /// named constant because `snapIfNeeded` needs to wait at least this
    /// long before performing the loop's silent snap-back, or it cuts the
    /// slide off before it finishes (see that function's doc comment).
    private static let autoAdvanceAnimationDuration: TimeInterval = 0.35

    /// Ticks once a second rather than firing directly at
    /// `autoAdvanceInterval` — the 1s granularity is enough to keep
    /// `idleSeconds` pinned at 0 for the duration of a held touch (a quick
    /// tap/swipe resets it directly from the gesture instead, since it
    /// might not overlap a tick at all — see `idleSeconds`'s doc comment).
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
            // Pause-on-touch detection — see `RegionTouchObserver`'s doc
            // comment for why this isn't a SwiftUI `DragGesture` (that
            // approach was tried first; confirmed via a temporary test
            // build to be exactly what was blocking dragging down from the
            // hero to scroll Home, even with `.simultaneousGesture`).
            .background {
                RegionTouchObserver { isDown in
                    isInteracting = isDown
                    idleSeconds = 0
                }
            }
            .onReceive(tickTimer) { _ in tick() }

            if items.count > 1 {
                HeroPageIndicator(count: items.count, currentIndex: currentIndex)
                    .padding(16)
            }
        }
        .frame(height: heroHeight)
    }

    /// Advances the carousel once `autoAdvanceInterval` seconds have passed
    /// with no finger on it. A no-op with 0 or 1 items — nothing to advance
    /// to, and `loopedItems`/`snapIfNeeded` aren't set up to loop in that
    /// case (see `loopedItems`'s doc comment).
    private func tick() {
        guard items.count > 1 else { return }
        guard !isInteracting else {
            idleSeconds = 0
            return
        }
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
private struct HeroPageIndicator: View {
    let count: Int
    let currentIndex: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == currentIndex ? 1 : 0.4))
                    .frame(width: 6, height: 6)
            }
        }
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
/// recognizer otherwise sees every touch anywhere on screen.
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
                guard hostView.bounds.contains(touch.location(in: hostView)) else { return }
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
