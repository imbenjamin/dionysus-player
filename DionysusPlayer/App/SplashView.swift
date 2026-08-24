import SwiftUI

/// Branded splash shown while `AppState` restores the session
/// (`RootView`'s `.isRestoringSession` phase) — replaces what used to be a
/// plain black screen with a spinner.
///
/// Deliberately mirrors `dionysus.icon` (the source-of-truth Icon Composer
/// spec for the app icon, `dionysus.icon/icon.json`): same magenta →
/// burgundy gradient, same solid-white/Normal-blend glyph. The icon's own
/// "specular"/"translucency" group properties are Icon Composer's take on
/// glass; here that's the real thing via SwiftUI's `.glassEffect`.
///
/// The gyro-driven depth effect is the same two-plane `.rotation3DEffect`
/// technique `BackdropLogoOverlay` uses for the detail-page hero (gradient
/// as the "far" plane, glyph as the "near" one, pivoting in opposite `anchorZ`
/// directions so tilting the device reads as looking into a receded scene
/// with the glyph genuinely floating above it) — reuses that view's own
/// `rotation(tiltX:tiltY:maxDegrees:)` helper rather than a third copy of the
/// same math, and the same `DeviceTiltObserver`/`hero3DDepthEnabledStorageKey`
/// pairing so this screen obeys Reduce Motion and the Profile "3D Depth
/// Effects" toggle exactly like every other depth-effect surface in the app.
/// An earlier version drove its own bespoke `CMMotionManager`-based glyph
/// offset instead — replaced entirely per direct feedback that it should
/// match the hero's real 3D effect rather than a one-off parallax.
struct SplashView: View {
    /// `.shared`, not a per-view instance — see `DeviceTiltObserver`'s own
    /// doc comment for why (one physical sensor shared app-wide).
    private var tiltObserver: DeviceTiltObserver { .shared }
    /// Same two independent opt-outs as `HeroHeaderView`: system Reduce
    /// Motion, and the Profile "3D Depth Effects" toggle. Either being true
    /// disables the tilt-driven rotation (though the glyph's own baseline
    /// shadow stays — see `GlassGlyph`'s doc comment for why that's not
    /// also gated).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(hero3DDepthEnabledStorageKey) private var depthEffectPreference = true
    private var is3DDepthEnabled: Bool { depthEffectPreference && !reduceMotion }
    /// See `HeroHeaderView.isObservingTilt`'s doc comment — same reasoning,
    /// keeps this view's `acquire()`/`release()` pair balanced across
    /// `.onAppear`/`.onDisappear`/the preference `.onChange`.
    @State private var isObservingTilt = false
    /// Gates the loading spinner below — session restore is typically
    /// near-instant, so showing it immediately would mostly just flash
    /// briefly on every launch rather than communicate anything useful.
    /// Flipped `true` after `spinnerDelay` by the `.task` below, which
    /// SwiftUI cancels automatically the moment this view disappears (i.e.
    /// restoration finished before the delay elapsed) — nothing else needs
    /// to guard against a late, spurious flip.
    @State private var showsSpinner = false
    private static let spinnerDelay: Duration = .seconds(3)

    private var tiltX: CGFloat { is3DDepthEnabled ? CGFloat(tiltObserver.x) : 0 }
    private var tiltY: CGFloat { is3DDepthEnabled ? CGFloat(tiltObserver.y) : 0 }

    /// Same `anchorZ`/`perspective` pairs as `BackdropLogoOverlay`'s own
    /// backdrop/logo — see that type's doc comment for why those two
    /// specifically are left alone rather than pushed further (they interact
    /// multiplicatively; the confirmed-visible pairing is worth keeping
    /// fixed). Only the rotation angles are tuned up from that view's own
    /// values — direct feedback that the hero's subtlety (tuned for a photo
    /// backdrop the eye is already busy with) read as barely-there against
    /// this screen's plain gradient, with nothing else on screen to draw
    /// attention away from a bigger swing.
    private static let backgroundMaxRotationDegrees: Double = 22
    private static let backgroundAnchorZ: CGFloat = -180
    private static let backgroundPerspective: CGFloat = 0.3
    /// Headroom so the gradient's rotated corners never reveal whatever's
    /// behind this view — see `BackdropLogoOverlay.backdropScale`'s doc
    /// comment for the identical reasoning (there, an image edge; here, the
    /// window background past the gradient's own bounds). Bumped up from
    /// that view's own `1.25` alongside the larger rotation angle above —
    /// more rotation swings the corners further, so this needs more slack
    /// to still never reveal an edge.
    private static let backgroundScale: CGFloat = 1.4
    private static let glyphMaxRotationDegrees: Double = 14
    private static let glyphAnchorZ: CGFloat = 150
    private static let glyphPerspective: CGFloat = 0.4
    private static let glyphShadowRange: CGFloat = 14

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.dionysusMagenta, .dionysusBurgundy],
                startPoint: .top,
                endPoint: .bottom
            )
            .scaleEffect(is3DDepthEnabled ? Self.backgroundScale : 1)
            .rotation3DEffect(
                backgroundRotation.angle, axis: backgroundRotation.axis,
                anchor: .center, anchorZ: Self.backgroundAnchorZ, perspective: Self.backgroundPerspective
            )
            .ignoresSafeArea()

            GlassGlyph()
                .rotation3DEffect(
                    glyphRotation.angle, axis: glyphRotation.axis,
                    anchor: .center, anchorZ: Self.glyphAnchorZ, perspective: Self.glyphPerspective
                )
                // A baseline shadow regardless of `is3DDepthEnabled` — unlike
                // `BackdropLogoOverlay`'s logo (a flat lockup sitting on a
                // backdrop, with no inherent reason to look "raised" once its
                // depth effect is off), this glyph is meant to read as an
                // elevated glass badge always, tilt or no tilt; only the
                // *shift* toward wherever the device is tilted is gated.
                .shadow(
                    color: .black.opacity(0.45), radius: 30,
                    x: -tiltX * Self.glyphShadowRange, y: -tiltY * Self.glyphShadowRange * 0.5 + 24
                )
        }
        // Between the icon and the bottom edge, not right under the icon —
        // close enough to read as belonging to this screen rather than
        // floating in empty space, far enough to stay clear of the icon's
        // own rotation/shadow. White, not `.dionysusPrimary` (the usual
        // in-app spinner tint) — this sits directly on the brand gradient
        // itself rather than a system background, and needs to read against
        // both the magenta and burgundy ends of it regardless of light/dark
        // mode, the same reason the glyph above is solid white too. Held
        // back by `showsSpinner` — see that property's doc comment for why.
        .overlay(alignment: .bottom) {
            if showsSpinner {
                ProgressView()
                    .tint(.white)
                    .padding(.bottom, 96)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: showsSpinner)
        .task {
            do {
                try await Task.sleep(for: Self.spinnerDelay)
                showsSpinner = true
            } catch {
                // Cancelled because this view disappeared (session restore
                // finished) before the delay elapsed — nothing to show a
                // spinner for by then.
            }
        }
        // Not also calling `tiltObserver.warmUp()` here — `AppState.start()`
        // already fires it once, unconditionally, during exactly this
        // splash/session-restore window (see its own doc comment for why
        // there specifically). Calling it a second time from here would
        // race this view's own `acquire()` below: `warmUp()`'s direct
        // `stop()` isn't reference-counted against `acquire()`/`release()`,
        // so an unluckily-timed pair could stop the sensor this view just
        // started.
        .onAppear { acquireTiltObserverIfNeeded() }
        // See `HeroHeaderView.onDisappear`'s doc comment — a real
        // `.onDisappear`-driven `release()` is safe because of
        // `DeviceTiltObserver`'s reference-counted grace period.
        .onDisappear { releaseTiltObserverIfNeeded() }
        .onChange(of: depthEffectPreference) { _, _ in
            if is3DDepthEnabled { acquireTiltObserverIfNeeded() } else { releaseTiltObserverIfNeeded() }
        }
    }

    private var backgroundRotation: (angle: Angle, axis: (x: CGFloat, y: CGFloat, z: CGFloat)) {
        BackdropLogoOverlay.rotation(tiltX: tiltX, tiltY: tiltY, maxDegrees: Self.backgroundMaxRotationDegrees)
    }

    private var glyphRotation: (angle: Angle, axis: (x: CGFloat, y: CGFloat, z: CGFloat)) {
        BackdropLogoOverlay.rotation(tiltX: tiltX, tiltY: tiltY, maxDegrees: Self.glyphMaxRotationDegrees)
    }

    /// See `HeroHeaderView.acquireTiltObserverIfNeeded()` — identical
    /// reasoning, duplicated rather than shared since the two views have no
    /// other relationship to hang a shared helper off of.
    private func acquireTiltObserverIfNeeded() {
        guard is3DDepthEnabled, !isObservingTilt else { return }
        isObservingTilt = true
        Task { await tiltObserver.acquire() }
    }

    private func releaseTiltObserverIfNeeded() {
        guard isObservingTilt else { return }
        isObservingTilt = false
        Task { await tiltObserver.release() }
    }
}

/// The glyph itself rendered as Liquid Glass — no separate badge shape
/// behind it. `.glassEffect` only knows how to confine itself to a `Shape`
/// (a geometric path), not an arbitrary image's silhouette, so a plain
/// glass rectangle is generated first and then `.mask`ed down to the
/// glyph's own alpha channel — the glass ends up exactly the shape of the
/// `dionysus_glyph` artwork, same as `dionysus_glyph`'s "specular" /
/// "translucency" group in `dionysus.icon/icon.json` applies those
/// qualities directly to the glyph layer rather than to a badge around it.
/// Tinted white to match that layer's solid-white/Normal-blend fill.
private struct GlassGlyph: View {
    /// Sized up from an earlier `150` per direct feedback that it read as
    /// small next to a typical iOS launch screen's own centered app icon —
    /// closer to that scale now, though "the same size as the system
    /// default" isn't a fixed constant Apple documents anywhere; adjust
    /// further on more feedback rather than treating this as exact.
    private static let size: CGFloat = 210

    var body: some View {
        Rectangle()
            .modifier(GlassSurface())
            .frame(width: Self.size, height: Self.size)
            .mask {
                Image("DionysusGlyph")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            .blendMode(.normal)
    }
}

/// `.glassEffect` is iOS 26+ only; deployment target here is 17, so older
/// OSes fall back to a plain white-tinted frosted material instead.
private struct GlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .foregroundStyle(.clear)
                .glassEffect(.regular.tint(.white), in: Rectangle())
        } else {
            content
                .foregroundStyle(.white.opacity(0.85))
                .background(.ultraThinMaterial)
        }
    }
}

#Preview {
    SplashView()
}
