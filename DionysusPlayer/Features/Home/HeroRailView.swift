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

    /// Custom init so `selection`'s starting value can account for whether
    /// `loopedItems` actually pads `items` — with 0 or 1 items it doesn't
    /// (looping a single page is meaningless), so `selection` must start at
    /// `0` rather than the usual `1`, or it would reference a `.tag` that
    /// doesn't exist and `TabView` would render blank.
    init(items: [MediaItem]) {
        self.items = items
        _selection = State(initialValue: items.count > 1 ? 1 : 0)
    }

    /// Tracked purely to force `body` to re-run on rotation, the same
    /// reason `HeroHeaderView` reads `verticalSizeClass` — `screenHeight`/
    /// `statusBarInset` below are plain UIKit reads, and SwiftUI has no way
    /// to know `body` depends on them unless *something* here is a tracked
    /// dependency.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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

    /// A third of the screen, stretched 25% taller, *plus* `statusBarInset`
    /// so bleeding up under the notch is pure upward growth rather than
    /// eating into that 1.25x budget — without the addition, reaching the
    /// notch and "25% taller" would fight over the same height instead of
    /// both actually happening.
    private var heroHeight: CGFloat {
        statusBarInset + screenHeight / 3 * 1.25
    }

    /// Indexes into `loopedItems`, not `items` — see that property's doc
    /// comment. Starts at `1`, the first *real* page once the leading
    /// duplicate is accounted for.
    @State private var selection: Int = 1

    /// `items` padded with a duplicate of the last item in front and the
    /// first item behind, so a swipe off either end of the real range still
    /// lands on a page showing the correct "next" item instead of stopping.
    /// `onChange(of:)` below then snaps `selection` back into the real
    /// range with animation disabled once that swipe's own animation has
    /// landed — the duplicate page makes the swipe itself look continuous,
    /// and the snap-back is invisible because the duplicate and the real
    /// page it stands in for are pixel-identical. Standard workaround for
    /// "infinite" paging with `TabView`, which has no native loop mode.
    private var loopedItems: [MediaItem] {
        guard let first = items.first, let last = items.last, items.count > 1 else { return items }
        return [last] + items + [first]
    }

    /// `selection` translated back into `items`' index space, for the dot
    /// indicator — the indicator should never show the padding pages.
    private var currentIndex: Int {
        guard items.count > 1 else { return 0 }
        return (selection - 1 + items.count) % items.count
    }

    /// Whether a finger is currently down on the carousel — tracked via a
    /// zero-distance `DragGesture` rather than anything TabView exposes
    /// natively (it doesn't). `minimumDistance: 0` makes `onChanged` fire
    /// the instant a touch lands, before any movement, so this reflects
    /// "finger is on the carousel" rather than "user is actively swiping."
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
            TabView(selection: $selection) {
                ForEach(Array(loopedItems.enumerated()), id: \.offset) { offset, item in
                    HeroRailCard(item: item)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: selection) { _, newValue in
                snapIfNeeded(from: newValue)
            }
            // `simultaneousGesture` rather than `gesture` — the latter
            // would compete with (and could win against) TabView's own
            // paging drag gesture; this one only observes touch state
            // alongside it without ever blocking or being blocked by it.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        isInteracting = true
                        idleSeconds = 0
                    }
                    .onEnded { _ in
                        isInteracting = false
                        idleSeconds = 0
                    }
            )
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
            selection += 1
        }
    }

    /// Performs the "snap back into the real range" half of the loop trick.
    ///
    /// Deferred by `autoAdvanceAnimationDuration`, not just one run-loop
    /// turn — `onChange(of:)` fires the instant `selection`'s *state*
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
                selection = target
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

/// Custom dot page indicator, standing in for `TabView`'s native one (kept
/// hidden via `indexDisplayMode: .never`) — the native indicator has no way
/// to hide `loopedItems`' two padding pages from its dot count, and would
/// briefly show the wrong dot lit while a loop snap-back is in flight.
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

#Preview {
    HeroRailView(items: [])
}
