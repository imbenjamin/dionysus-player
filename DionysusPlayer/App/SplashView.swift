import CoreMotion
import Foundation
import Observation
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
struct SplashView: View {
    @State private var motion = TiltMotionManager()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.dionysusMagenta, .dionysusBurgundy],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            GlassGlyph()
                // Reads as elevated above the gradient rather than printed
                // on it — combined with the tilt-driven offset below, that
                // sells the glyph as a floating layer with its own depth,
                // the same illusion as iOS's classic parallax wallpaper.
                .shadow(color: .black.opacity(0.45), radius: 40, x: 0, y: 24)
                .offset(motion.offset)
        }
        .task { motion.start() }
        .onDisappear { motion.stop() }
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
    private static let size: CGFloat = 150

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

/// Reads device attitude (tilt) via Core Motion and exposes a small,
/// clamped offset for the splash glyph's parallax. Raw device-motion access
/// (unlike step-counting/activity APIs) isn't gated by an Info.plist usage
/// string on iOS, so no permission prompt or entitlement is needed.
@MainActor
@Observable
final class TiltMotionManager {
    private let manager = CMMotionManager()
    private(set) var offset: CGSize = .zero

    /// Clamp so a full tilt to either side only nudges the glyph a little —
    /// this is a subtle depth cue, not a joystick.
    private let maxOffset: CGFloat = 16

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Tilting the top of the phone away from you (negative pitch)
            // or rolling it (roll) should shift the "floating" glyph
            // opposite the gradient behind it, same direction real
            // parallax would move a nearer layer.
            let x = CGFloat(motion.attitude.roll) * -60
            let y = CGFloat(motion.attitude.pitch) * -60
            withAnimation(.easeOut(duration: 0.2)) {
                self.offset = CGSize(
                    width: x.clamped(to: -self.maxOffset...self.maxOffset),
                    height: y.clamped(to: -self.maxOffset...self.maxOffset)
                )
            }
        }
    }

    /// Idempotent to make `onDisappear` safe to call even if `start()`
    /// never actually began updates (e.g. motion unavailable in Simulator).
    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    SplashView()
}
