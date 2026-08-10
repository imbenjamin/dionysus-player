import SwiftUI
import UIKit

/// Backdrop image with a logo (or title text fallback) overlaid at the
/// bottom, Disney+-style — see `BackdropLogoOverlay` for the shared visual
/// composition (also used by Home's hero rail) and its `enable3DDepth`/
/// `tiltX`/`tiltY` parameters for the gyro-driven 3D depth effect this view
/// opts into (backed by `DeviceTiltObserver`, below) — the one place in the
/// app that does, since a per-page detail hero (static once you're looking
/// at it) is where a subtle tilt-driven depth effect reads as a nice touch
/// rather than fighting something else already animating on screen (Home's
/// hero rail auto-advances on its own timer).
///
/// Lives inside a `ScrollView` whose containing detail page applies
/// `.ignoresSafeArea(edges: .top)`, so this can render flush with the
/// screen's physical top edge once scrolled. At rest, though, that would put
/// the top of this image right behind the status bar/notch/Dynamic Island
/// cutout — the `.padding(.top, ...)` below reserves just enough space to
/// clear that at rest, while still letting the image scroll up through the
/// cutout once the user scrolls (the padding scrolls away with everything
/// else in the `ScrollView`, same as any other content). Landscape has no
/// such cutout to clear at the top, so the padding is skipped there.
struct HeroHeaderView: View {
    let item: MediaItem

    /// `.shared`, not a per-view instance — see `DeviceTiltObserver`'s own
    /// doc comment for why (one physical sensor, and `ProfileView`'s toggle
    /// needs visibility into the same `isApplyingChange` this view's
    /// `.onAppear`/`.onChange` below drive). `ProfileView`'s toggle also
    /// calls `start()`/`stop()` directly on the same shared instance — see
    /// that view for why — so either call site's idea of "is it running"
    /// stays in sync regardless of which one triggered it.
    private var tiltObserver: DeviceTiltObserver { .shared }
    /// Two independent opt-outs, both meaning "don't run the effect": the
    /// system-level Reduce Motion setting, and `ProfileView`'s own "3D Depth
    /// Effects" toggle (`hero3DDepthEnabledStorageKey`, default on) for
    /// someone who doesn't mind motion in general but just doesn't want
    /// this one effect. Either being true is enough to disable it — see
    /// `is3DDepthEnabled` below.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(hero3DDepthEnabledStorageKey) private var depthEffectPreference = true
    private var is3DDepthEnabled: Bool { depthEffectPreference && !reduceMotion }

    /// `@Environment` — not a plain computed property reading UIKit state
    /// directly — is what actually matters here. `statusBarInset` below
    /// *is* a plain computed property, and that's fine on its own: whatever
    /// calls it just gets a fresh read every time it's evaluated. The bug
    /// with two earlier attempts at `isLandscape` (checking
    /// `UIWindowScene.interfaceOrientation`, then comparing the key window's
    /// own `bounds`) wasn't that either signal was wrong — it's that SwiftUI
    /// has no idea `body` depends on either one, so it had no reason to
    /// *re-run* `body` on rotation at all. The padding value got computed
    /// once at first render and then sat frozen, whichever expression was
    /// there. `@Environment(\.verticalSizeClass)` is a tracked dependency:
    /// SwiftUI reruns `body` when it changes, which is what makes
    /// `statusBarInset` below get a fresh read too — the same expression
    /// that didn't work standalone works once *something* in this view is
    /// actually wired into SwiftUI's invalidation.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Deliberately the raw window/hardware inset, not SwiftUI's ambient
    /// `safeAreaInsets` (via `GeometryReader`) — inside a `NavigationStack`,
    /// that value also folds in the visible navigation bar's height, which
    /// would push this down by more than just the status bar/cutout. The
    /// key window's own inset is unaffected by any app-level chrome drawn
    /// inside it.
    private var statusBarInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    private static let height: CGFloat = 320

    var body: some View {
        BackdropLogoOverlay(
            item: item,
            enable3DDepth: is3DDepthEnabled,
            tiltX: is3DDepthEnabled ? CGFloat(tiltObserver.x) : 0,
            tiltY: is3DDepthEnabled ? CGFloat(tiltObserver.y) : 0
        )
        .frame(height: Self.height)
        .padding(.top, isLandscape ? 0 : statusBarInset)
        .onAppear { if is3DDepthEnabled { Task { await tiltObserver.start() } } }
        // Deliberately no `.onDisappear` calling `stop()` here — found the
        // hard way (real-device repro, 2026-08-10): pushing a new detail
        // page (e.g. tapping a "More Like This" item) fires this view's
        // `.onDisappear` and the new page's `.onAppear` within moments of
        // each other, each as its own unstructured `Task`. Nothing
        // guarantees `stop()` actually finishes tearing the sensor down
        // before `start()`'s guard checks whether it's already active — if
        // `start()` wins that race, it sees "already active," no-ops, and
        // then `stop()` goes on to really shut everything off, leaving
        // *both* pages with a dead effect until something else happens to
        // call `start()` again (confirmed: popping back to the original
        // page didn't recover it either, for the same reason). A page
        // merely being pushed under another isn't "the effect is no longer
        // needed" anyway — `start()` above is idempotent, so leaving the
        // sensor running across in-stack navigation is both simpler and
        // correct. Actually stopping it stays driven only by an explicit
        // signal: the "3D Depth Effects" toggle (`ProfileView`, this view's
        // own `.onChange` below) or Reduce Motion changing.
        // `depthEffectPreference` can change while this view is already on
        // screen (flipped in Settings, then navigating straight to a detail
        // page without relaunching) — `.onAppear` alone would miss that,
        // since it only fires once per appearance, not on every dependency
        // change. `reduceMotion` is a tracked `@Environment` dependency
        // already covered by `body` re-running on its own; this just adds
        // the same coverage for the `@AppStorage` one.
        .onChange(of: depthEffectPreference) { _, isEnabled in
            Task {
                if isEnabled, !reduceMotion {
                    await tiltObserver.start()
                } else {
                    await tiltObserver.stop()
                }
            }
        }
    }
}

/// `UserDefaults` key for `ProfileView`'s "3D Depth Effects" toggle —
/// shared so `HeroHeaderView`'s own `@AppStorage` reads the exact same
/// value `ProfileView` writes.
let hero3DDepthEnabledStorageKey = "hero3DDepthEnabled"
