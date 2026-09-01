import Shimmer
import SwiftUI

/// The shared placeholder/fallback visual for every poster, backdrop, and
/// thumbnail in the app — a content-representative SF Symbol glyph over a
/// flat gray box, replacing what used to be two independently-defined plain
/// `Rectangle().fill(Color.gray.opacity(0.2))` blocks in `AsyncRemoteImage`
/// and `LocalFileImage`.
///
/// Loading and settled states are visually distinct, not just a dimmer
/// glyph: while a fetch is outstanding/retrying, the glyph itself shimmers
/// (via the `Shimmer` package's `.shimmering()` modifier — chosen over a
/// hand-rolled animation for a more polished result with less tuning) —
/// scoped to the glyph rather than the whole tile, which read as calmer
/// against surrounding content. The moment a fetch settles — a definitive
/// failure, or nothing to even try (e.g. a cast member with no image tag)
/// — the shimmer stops for good and the glyph sits static at a slightly
/// higher resting opacity. The two states must never be visually
/// ambiguous: animated always means "still trying," static always means
/// "this is the resting fallback."
struct MediaPlaceholderBox: View {
    var systemImage: String = "photo"
    /// Overridable for tight frames — the default suits a typical
    /// poster/backdrop tile; small frames (the 84pt cast circle, a 44×66
    /// downloads row thumbnail) want something smaller, e.g. `20`.
    var glyphSize: CGFloat = 28
    /// `false` (the default): still loading/retrying — glyph shimmers.
    /// `true`: settled — a definitive failure, or nothing to even try —
    /// static, no motion.
    var isSettled: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Only shimmer while genuinely unsettled *and* motion isn't reduced —
    /// Reduce Motion falls back to the same static treatment the settled
    /// state uses, just at the lower "still working" opacity, rather than
    /// leaving the animation frozen mid-cycle. Passed straight to
    /// `.shimmering(active:)` — the package has no reduce-motion awareness
    /// of its own.
    private var isShimmering: Bool { !isSettled && !reduceMotion }

    var body: some View {
        Rectangle().fill(Color.gray.opacity(0.2))
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: glyphSize))
                    .foregroundStyle(Color.dionysusHighlight)
                    .opacity(isSettled ? 0.85 : 0.45)
                    .shimmering(active: isShimmering)
            }
            // Purely decorative — every real call site already carries its
            // own accessibility label, via either the established
            // `.accessibilityElement(children: .ignore)` card pattern or
            // `BackdropLogoOverlay`'s own dedicated label layer. This glyph
            // must never acquire a label of its own.
            .accessibilityHidden(true)
    }
}
