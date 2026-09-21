import SwiftUI

/// The circular glyph chrome shared by every trailing-toolbar control on the
/// asset detail page — `HeroActionButtons`' favorite/watched pair and
/// `AssetActionsButton`.
///
/// Extracted so a second control can't drift from the first. Everything here
/// was tuned against the live hero image and is easy to "tidy" back into a
/// bug; the reasoning, moved verbatim from `HeroActionButtons.icon(...)`
/// where it originally lived:
///
/// On iOS 26 the glyph draws **no chrome of its own** — no `.glassEffect`,
/// no background, just the glyph and a 44pt tap target. The nav bar already
/// wraps each `ToolbarItem` in its own Liquid Glass capsule, so a
/// `.glassEffect(in: Circle())` here drew a *second* glass shape nested
/// inside the system's: the visible circular outline around each control,
/// inside the group's capsule. It was subtle on iOS 26 and obvious on iOS 27,
/// where the system capsule's own edge treatment is stronger. No other
/// toolbar in the app did this (see the Downloads screens' bare
/// `Image(systemName:).downloadsToolbarTapTarget()`, which is exactly this
/// shape), and no system app does either. Don't reintroduce glass here —
/// let the toolbar provide it.
///
/// On iOS 26 the glyph sets no explicit color. This was tried the other way
/// on the assumption it'd match the back button's chevron, but that button
/// doesn't set an explicit color either, confirmed live — that's exactly why
/// it, unlike this button once it *did* hardcode black, stays legible over
/// both a light and a dark patch of the scrolling hero image: real
/// `.glassEffect` content is automatically tinted for contrast
/// against whatever's currently behind the system's glass, the same Liquid
/// Glass vibrancy the system back button gets for free. Forcing `.black` (or
/// `.white`) defeats that and pins the glyph to one color regardless of
/// what's under it. The pre-26 fallback has no such live-contrast mechanism
/// to defer to — `.primary` there just tracks light/dark *mode*, not the
/// image behind it — so it keeps an explicit color (overridden by `tint`
/// when set) chosen to read clearly against its own opaque background fill
/// instead.
///
/// `.body`/`.medium` — not the `20pt`/`.semibold` this started at — after
/// direct feedback that the original read as too thick/heavy to pass for
/// native chrome: the back button's own chevron (and this glyph's closest
/// real-world equivalent, the favorite/watched icons in Apple's own
/// Podcasts/TV apps) sit closer to this weight, with more glyph-to-circle
/// breathing room than a bigger/bolder glyph leaves. The 44pt frame stays
/// fixed either way — shrinking the glyph doesn't shrink the tap target,
/// just how much of the circle it visually fills. That 44pt is also what
/// satisfies the HIG minimum tap target these icon-only controls are
/// otherwise too small for (the same fix `.downloadsToolbarTapTarget()`
/// applies on the Downloads screens).
struct HeroToolbarGlyph: View {
    let systemName: String
    var tint: Color?
    var isPending: Bool

    var body: some View {
        if #available(iOS 26.0, *) {
            Group {
                if isPending {
                    ProgressView()
                } else if let tint {
                    Image(systemName: systemName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(tint)
                } else {
                    Image(systemName: systemName)
                        .font(.body.weight(.medium))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        } else {
            // Matches `ResetFiltersButton`'s pre-26 fallback — a light fill
            // a black glyph reads clearly against, not the dark fill this
            // used before the glyph itself switched from white to black.
            Group {
                if isPending {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: systemName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(tint ?? .black)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color(.secondarySystemBackground))
            .clipShape(Circle())
        }
    }
}
