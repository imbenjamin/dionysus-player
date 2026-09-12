import SwiftUI
import UIKit

/// Backdrop image with a logo (or title text fallback) overlaid at the bottom.
/// See `BackdropLogoOverlay` for the shared composition, also used by Home's
/// hero rail, and its `enable3DDepth`/`tiltX`/`tiltY` parameters for the
/// gyro-driven depth effect this view opts into via `DeviceTiltObserver`. It's
/// the only place that does: a detail hero is static once you're looking at it,
/// where Home's hero rail is already auto-advancing.
///
/// Lives inside a `ScrollView` whose detail page applies
/// `.ignoresSafeArea(edges: .top)`, so this renders flush with the physical top
/// edge, bleeding behind the status bar/notch like `HeroRailView` rather than
/// padding to clear it. `heroHeight` below duplicates
/// `HeroRailView.heroHeight`'s formula rather than sharing a helper, as
/// `isLandscape`/`statusBarInset` already do.
struct HeroHeaderView: View {
    /// Plain values, not `item: MediaItem`, so
    /// `DownloadedAssetDetailView`'s offline hero can reuse this composition
    /// from local artwork. See `BackdropLogoOverlay`.
    let backdropURL: URL?
    let logoURL: URL?
    let title: String
    /// Forwarded to `BackdropLogoOverlay`.
    var episodeTitle: String? = nil
    /// Forwarded to `BackdropLogoOverlay`.
    var episodeNumberAccessibilityText: String? = nil
    /// Forwarded to `BackdropLogoOverlay`.
    var kind: BaseItemKind? = nil

    /// `.shared`, not a per-view instance: one physical sensor, and
    /// `ProfileView`'s toggle needs the same `isApplyingChange` this view's
    /// `.onAppear`/`.onChange` drive. That toggle calls `start()`/`stop()` on
    /// the same instance, so both call sites agree on whether it's running.
    private var tiltObserver: DeviceTiltObserver { .shared }
    /// Three independent opt-outs, any of which disables the effect (see
    /// `is3DDepthEnabled`): system Reduce Motion; `ProfileView`'s "3D Depth
    /// Effects" toggle (`hero3DDepthEnabledStorageKey`, default on) for someone
    /// who wants only this effect off; and VoiceOver, since a screen reader user
    /// gets no benefit from parallax and there's no reason to keep the sensor
    /// running and `body` re-rendering at 30 Hz for them.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AppStorage(hero3DDepthEnabledStorageKey) private var depthEffectPreference = true
    private var is3DDepthEnabled: Bool { depthEffectPreference && !reduceMotion && !voiceOverEnabled }
    /// Whether this view instance has an outstanding `tiltObserver.acquire()`,
    /// and so owes a `release()`. `.onAppear`, `.onDisappear` and the
    /// `.onChange` below can each acquire or release independently, and this
    /// keeps them paired exactly once. `@State`, not a plain `var`: `body`
    /// reruns on every tilt sample, which would reset a plain property.
    @State private var isObservingTilt = false

    /// `@Environment`, not a computed property reading UIKit state, because only
    /// the former is a tracked dependency. Earlier attempts at `isLandscape`
    /// read `UIWindowScene.interfaceOrientation` and then the key window's
    /// `bounds`: neither signal was wrong, but SwiftUI didn't know `body`
    /// depended on them, so it never re-ran on rotation and `heroHeight` stayed
    /// frozen at its first render. With `verticalSizeClass` tracked, `body`
    /// reruns and `statusBarInset` below gets a fresh read as a side effect.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Shared by `screenHeight`/`statusBarInset`, as in `HeroRailView.keyWindow`.
    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)
    }

    /// The key window's bounds, not `UIScreen.main`, which is soft-deprecated
    /// and doesn't reflect a scene resized under Stage Manager. Same as
    /// `HeroRailView.screenHeight`.
    private var screenHeight: CGFloat { keyWindow?.bounds.height ?? 800 }

    /// The raw window inset, not SwiftUI's ambient `safeAreaInsets`: inside a
    /// `NavigationStack` that folds in the navigation bar's height, overstating
    /// the status bar/cutout. The window's own inset ignores app-level chrome.
    private var statusBarInset: CGFloat { keyWindow?.safeAreaInsets.top ?? 0 }

    /// The width the layout system measured for this hero, written by the
    /// `.onGeometryChange` in `body`.
    ///
    /// Exists so `heroHeight(forWidth:)` has a dependency that changes when an
    /// iPad rotates. `verticalSizeClass` can't: every iPad reports regular
    /// height in both orientations, so `body` never re-runs on rotation there
    /// and the untracked `screenHeight` stays frozen at first render. On an
    /// iPad, opening a movie in portrait measured the hero at 523.9pt and
    /// rotating left it at 523.5pt, where first rendering in landscape gave
    /// 373.5pt — the 150.4pt gap is exactly `(1180 - 820) / 3 * 1.25`, the whole
    /// difference between the two formulas, never applied. The hero then ate 64%
    /// of an 820pt landscape screen, pushing metadata, Play and tabs to the
    /// bottom.
    ///
    /// This hero is full-bleed, so its width is the screen width, and unlike the
    /// window read it comes from the layout system, changing on rotation on
    /// every device.
    @State private var measuredWidth: CGFloat = 0

    /// Same formula as `HeroRailView.heroHeight`, duplicated rather than shared
    /// (see this type's doc comment).
    ///
    /// Takes the measured width as an argument the arithmetic never uses: that's
    /// what makes this depend on a value that changes on rotation, so the
    /// `screenHeight`/`statusBarInset` reads below are re-evaluated rather than
    /// frozen. See `measuredWidth`; `HeroRailView.heroHeight` still has the
    /// unfixed version of this bug.
    private func heroHeight(forWidth width: CGFloat) -> CGFloat {
        _ = width
        guard !isLandscape else { return screenHeight * 0.75 }
        return statusBarInset + screenHeight / 3 * 1.25
    }

    var body: some View {
        BackdropLogoOverlay(
            backdropURL: backdropURL,
            logoURL: logoURL,
            title: title,
            kind: kind,
            episodeTitle: episodeTitle,
            episodeNumberAccessibilityText: episodeNumberAccessibilityText,
            // Detail-page heroes center, unlike `HeroRailCard`'s left-aligned
            // default — see `BackdropLogoOverlay.alignment`.
            alignment: .center,
            enable3DDepth: is3DDepthEnabled,
            tiltX: is3DDepthEnabled ? CGFloat(tiltObserver.x) : 0,
            tiltY: is3DDepthEnabled ? CGFloat(tiltObserver.y) : 0,
            // Keeps the accessibility frame out of the status bar this visually
            // bleeds under — see `BackdropLogoOverlay.body`.
            accessibilityTopInset: statusBarInset
        )
        .frame(height: heroHeight(forWidth: measuredWidth))
        // See `measuredWidth`. Fires after layout, so a rotation shows one frame
        // at the old height before correcting.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            measuredWidth = newWidth
        }
        .onAppear { acquireTiltObserverIfNeeded() }
        // Releasing rather than stopping outright, because
        // `DeviceTiltObserver.acquire()`/`release()` are reference-counted with
        // a grace period. A direct stop-on-disappear raced a push straight to
        // another detail page: the outgoing `.onDisappear` and incoming
        // `.onAppear` fire moments apart in separate unstructured `Task`s, and
        // nothing guaranteed `stop()` finished before the next `start()`'s
        // "already active" guard no-opped — either order could leave the sensor
        // dead for both pages. The grace period means the count never sees a
        // sustained zero across such a push, while genuinely leaving the feature
        // still stops the sensor.
        .onDisappear { releaseTiltObserverIfNeeded() }
        // `depthEffectPreference` can change while this view is on screen, which
        // `.onAppear` misses, firing once per appearance rather than on every
        // dependency change. `reduceMotion` is already covered by `body`
        // re-running; this adds the same for the `@AppStorage` value.
        .onChange(of: depthEffectPreference) { _, _ in
            if is3DDepthEnabled { acquireTiltObserverIfNeeded() } else { releaseTiltObserverIfNeeded() }
        }
    }

    /// Every acquire goes through here so it happens once per outstanding
    /// `release()`. See `isObservingTilt`.
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

/// `UserDefaults` key for `ProfileView`'s "3D Depth Effects" toggle, shared so
/// `HeroHeaderView`'s `@AppStorage` reads what `ProfileView` writes.
let hero3DDepthEnabledStorageKey = "hero3DDepthEnabled"
