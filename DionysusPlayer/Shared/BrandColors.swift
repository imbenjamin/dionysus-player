import SwiftUI
import UIKit

/// Dionysus brand palette. Reference these instead of raw `Color` literals so
/// palette changes stay in one place.
extension Color {
    static let dionysusGold = Color(red: 1.00, green: 0.88, blue: 0.10)
    static let dionysusAmber = Color(red: 0.94, green: 0.55, blue: 0.00)
    static let dionysusMagenta = Color(red: 0.84, green: 0.05, blue: 0.40)
    static let dionysusBurgundy = Color(red: 0.26, green: 0.00, blue: 0.12)

    /// Primary brand action colour. Burgundy on light backgrounds; magenta in
    /// dark (amber-in-dark reads as Plex-adjacent, so the palette leans on
    /// magenta + burgundy to stand out). Backed by a dynamic `UIColor` so any
    /// element rendered through UIKit adapts on trait changes too.
    static let dionysusPrimary = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(Color.dionysusMagenta)
            : UIColor(Color.dionysusBurgundy)
    })

    /// Inverse of `dionysusPrimary`: amber on light, burgundy on dark. Used
    /// for elements that need to contrast against a `dionysusPrimary` surface
    /// (e.g. a progress bar sitting on top of the primary Play button).
    static let dionysusProgress = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(Color.dionysusBurgundy)
            : UIColor(Color.dionysusAmber)
    })

    /// Highlight colour for accents sitting over media artwork (e.g. the
    /// rail-item progress bar over a poster). Amber in light, magenta in
    /// dark — the "no amber in dark" rule applies here too.
    static let dionysusHighlight = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(Color.dionysusMagenta)
            : UIColor(Color.dionysusAmber)
    })

    /// 70% lighter version of `dionysusPrimary` — primary mixed with white
    /// at 0.7. Used for the secondary "Restart" button so it reads as related
    /// to the Play button but visibly subordinate.
    static let dionysusPrimaryLight = Color(UIColor { traits in
        let base = traits.userInterfaceStyle == .dark
            ? UIColor(Color.dionysusMagenta)
            : UIColor(Color.dionysusBurgundy)
        return base.mixed(with: .white, amount: 0.7)
    })
}

private extension UIColor {
    /// Linear interpolation between two colours in sRGB. `amount` is the
    /// weight of `other` — 0 returns self, 1 returns other.
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red:   r1 + (r2 - r1) * amount,
            green: g1 + (g2 - g1) * amount,
            blue:  b1 + (b2 - b1) * amount,
            alpha: a1 + (a2 - a1) * amount
        )
    }
}
