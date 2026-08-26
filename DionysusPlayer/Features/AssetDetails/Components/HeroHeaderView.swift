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
/// `.ignoresSafeArea(edges: .top)`, so this renders flush with the screen's
/// physical top edge even at rest — deliberately bleeding up behind the
/// status bar/notch/Dynamic Island cutout, the same way Home's `HeroRailView`
/// does, rather than reserving top padding to clear it (an earlier version of
/// this view did reserve that padding; removed so the two heroes actually
/// match rather than one sitting a notch-height lower than the other).
/// `heroHeight` below is the same formula as `HeroRailView.heroHeight` for
/// the same reason — see that property's doc comment for why each term is
/// there; kept as a second copy here rather than a shared helper, matching
/// how `isLandscape`/`statusBarInset` below already duplicate that view's.
struct HeroHeaderView: View {
    /// Plain values, not `item: MediaItem` — generalized (2026-08-19) so
    /// `DownloadedAssetDetailView`'s offline hero header can reuse this
    /// exact tilt-effect composition from its own local artwork; see
    /// `BackdropLogoOverlay`'s own doc comment for the rest of the story.
    let backdropURL: URL?
    let logoURL: URL?
    let title: String
    /// Forwarded straight to `BackdropLogoOverlay` — see its own doc
    /// comment.
    var episodeTitle: String? = nil

    /// `.shared`, not a per-view instance — see `DeviceTiltObserver`'s own
    /// doc comment for why (one physical sensor, and `ProfileView`'s toggle
    /// needs visibility into the same `isApplyingChange` this view's
    /// `.onAppear`/`.onChange` below drive). `ProfileView`'s toggle also
    /// calls `start()`/`stop()` directly on the same shared instance — see
    /// that view for why — so either call site's idea of "is it running"
    /// stays in sync regardless of which one triggered it.
    private var tiltObserver: DeviceTiltObserver { .shared }
    /// Three independent opt-outs, all meaning "don't run the effect": the
    /// system-level Reduce Motion setting, `ProfileView`'s own "3D Depth
    /// Effects" toggle (`hero3DDepthEnabledStorageKey`, default on) for
    /// someone who doesn't mind motion in general but just doesn't want
    /// this one effect, and VoiceOver — added while chasing a real VoiceOver
    /// bug on this exact view (see `BackdropLogoOverlay.body`'s doc comment
    /// for the actual root cause and fix, an unrelated accessibility-frame/
    /// status-bar overlap, confirmed live and unaffected by this effect
    /// either way). Kept anyway on its own merits, not reverted: a screen
    /// reader user gets no visual benefit from a parallax effect they can't
    /// perceive, so there's no reason to keep the tilt sensor running (and
    /// `body` re-rendering on every sample) for them. Any of the three being
    /// true is enough to disable it — see `is3DDepthEnabled` below.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AppStorage(hero3DDepthEnabledStorageKey) private var depthEffectPreference = true
    private var is3DDepthEnabled: Bool { depthEffectPreference && !reduceMotion && !voiceOverEnabled }
    /// Whether *this* view instance currently has an outstanding
    /// `tiltObserver.acquire()` — i.e. whether it owes a matching
    /// `release()`. Needed because `.onAppear`/`.onDisappear`/the
    /// `.onChange` below can each independently decide to acquire or
    /// release; this is what keeps each of those calls paired up exactly
    /// once rather than acquiring twice or releasing without ever having
    /// acquired. `@State`, not a plain `var` — this struct's `body` reruns
    /// on every tilt sample (30 Hz), which would reset a plain property
    /// back to its initial value on every one of those.
    @State private var isObservingTilt = false

    /// `@Environment` — not a plain computed property reading UIKit state
    /// directly — is what actually matters here. `statusBarInset` below
    /// *is* a plain computed property, and that's fine on its own: whatever
    /// calls it just gets a fresh read every time it's evaluated. The bug
    /// with two earlier attempts at `isLandscape` (checking
    /// `UIWindowScene.interfaceOrientation`, then comparing the key window's
    /// own `bounds`) wasn't that either signal was wrong — it's that SwiftUI
    /// has no idea `body` depends on either one, so it had no reason to
    /// *re-run* `body` on rotation at all. `heroHeight` got computed once
    /// at first render and then sat frozen, whichever expression was there.
    /// `@Environment(\.verticalSizeClass)` is a tracked dependency:
    /// SwiftUI reruns `body` when it changes, which is what makes
    /// `statusBarInset` below get a fresh read too — the same expression
    /// that didn't work standalone works once *something* in this view is
    /// actually wired into SwiftUI's invalidation.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Shared by `screenHeight`/`statusBarInset` below, same reasoning as
    /// `HeroRailView.keyWindow`.
    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)
    }

    /// Deliberately the key window's own bounds, not `UIScreen.main` (soft
    /// deprecated, doesn't reflect a resized scene under iPadOS Stage
    /// Manager) — same as `HeroRailView.screenHeight`.
    private var screenHeight: CGFloat { keyWindow?.bounds.height ?? 800 }

    /// Deliberately the raw window/hardware inset, not SwiftUI's ambient
    /// `safeAreaInsets` (via `GeometryReader`) — inside a `NavigationStack`,
    /// that value also folds in the visible navigation bar's height, which
    /// would overstate the status bar/cutout alone. The key window's own
    /// inset is unaffected by any app-level chrome drawn inside it.
    private var statusBarInset: CGFloat { keyWindow?.safeAreaInsets.top ?? 0 }

    /// Same formula as `HeroRailView.heroHeight` — see this type's own doc
    /// comment for why it's duplicated here rather than shared.
    private var heroHeight: CGFloat {
        guard !isLandscape else { return screenHeight * 0.75 }
        return statusBarInset + screenHeight / 3 * 1.25
    }

    var body: some View {
        BackdropLogoOverlay(
            backdropURL: backdropURL,
            logoURL: logoURL,
            title: title,
            episodeTitle: episodeTitle,
            // Every detail-page hero centers, unlike `HeroRailCard`'s own
            // left-aligned default — see `BackdropLogoOverlay.alignment`'s
            // own doc comment for why.
            alignment: .center,
            enable3DDepth: is3DDepthEnabled,
            tiltX: is3DDepthEnabled ? CGFloat(tiltObserver.x) : 0,
            tiltY: is3DDepthEnabled ? CGFloat(tiltObserver.y) : 0,
            // Keeps this hero's *accessibility* frame from ever reaching
            // the status bar it visually bleeds under — see
            // `BackdropLogoOverlay.body`'s own doc comment for the bug this
            // fixes.
            accessibilityTopInset: statusBarInset
        )
        .frame(height: heroHeight)
        .onAppear { acquireTiltObserverIfNeeded() }
        // A real `.onDisappear` — releasing, not stopping outright — is
        // safe here specifically *because* `DeviceTiltObserver.acquire()`/
        // `release()` are reference-counted with a grace period, unlike a
        // direct `stop()` call would be. Found the hard way (real-device
        // repro, 2026-08-10) that a direct stop-on-disappear raced a
        // straight-to-another-detail-page push: the outgoing page's
        // `.onDisappear` and the incoming page's `.onAppear` fire within
        // moments of each other, each its own unstructured `Task`, and
        // nothing guaranteed `stop()` finished before the next `start()`'s
        // "already active" guard saw it as still running and no-opped —
        // whichever order they landed in could leave the sensor dead for
        // both pages. `release()`'s grace period (see its own doc comment)
        // is what closes that race: the count never sees a *sustained* zero
        // across a same-instant push, so no `stop()` fires there at all —
        // while actually leaving the feature (popping back out, with
        // nothing re-acquiring in time) now genuinely stops the sensor
        // instead of leaving it running for the rest of the app session.
        .onDisappear { releaseTiltObserverIfNeeded() }
        // `depthEffectPreference` can change while this view is already on
        // screen (flipped in Settings, then navigating straight to a detail
        // page without relaunching) — `.onAppear` alone would miss that,
        // since it only fires once per appearance, not on every dependency
        // change. `reduceMotion` is a tracked `@Environment` dependency
        // already covered by `body` re-running on its own; this just adds
        // the same coverage for the `@AppStorage` one.
        .onChange(of: depthEffectPreference) { _, _ in
            if is3DDepthEnabled { acquireTiltObserverIfNeeded() } else { releaseTiltObserverIfNeeded() }
        }
    }

    /// See `isObservingTilt`'s doc comment — every acquire goes through
    /// here so it only ever happens once per outstanding `release()`.
    private func acquireTiltObserverIfNeeded() {
        guard is3DDepthEnabled, !isObservingTilt else { return }
        isObservingTilt = true
        Task { await tiltObserver.acquire() }
    }

    /// See `acquireTiltObserverIfNeeded()`.
    private func releaseTiltObserverIfNeeded() {
        guard isObservingTilt else { return }
        isObservingTilt = false
        Task { await tiltObserver.release() }
    }
}

/// `UserDefaults` key for `ProfileView`'s "3D Depth Effects" toggle —
/// shared so `HeroHeaderView`'s own `@AppStorage` reads the exact same
/// value `ProfileView` writes.
let hero3DDepthEnabledStorageKey = "hero3DDepthEnabled"
