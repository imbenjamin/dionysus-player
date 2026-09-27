import SwiftUI
import UIKit

/// Dionysus brand palette. Reference these instead of raw `Color` literals so
/// palette changes stay in one place.
extension Color {
    static let dionysusGold = Color(red: 1.00, green: 0.88, blue: 0.10)
    static let dionysusAmber = Color(red: 0.94, green: 0.55, blue: 0.00)
    static let dionysusMagenta = Color(red: 0.84, green: 0.05, blue: 0.40)
    static let dionysusBurgundy = Color(red: 0.26, green: 0.00, blue: 0.12)

    /// Increase Contrast variant of `dionysusMagenta` — brighter/more
    /// luminant, not just more saturated. Computed via the standard WCAG
    /// relative-luminance formula: plain `dionysusMagenta` measures ~4.1:1
    /// against a near-black dark-mode background, just *under* the 4.5:1 AA
    /// minimum for normal text/icons (`Design Guideline — Accessibility`:
    /// "Text sizes up to 17pt... minimum contrast ratio 4.5:1"). This value
    /// measures ~6.6:1 against the same background — comfortably clear of
    /// the line, without leaving the magenta hue family.
    static let dionysusMagentaHighContrast = Color(red: 0.95, green: 0.35, blue: 0.55)

    /// Increase Contrast variant of `dionysusAmber`, same reasoning as
    /// `dionysusMagentaHighContrast` above — plain `dionysusAmber` measures
    /// only ~2.5:1 against a white light-mode background (well under 4.5:1);
    /// this deeper/more saturated amber measures ~5.5:1.
    static let dionysusAmberHighContrast = Color(red: 0.65, green: 0.32, blue: 0.00)

    /// The tab bar's selected-item tint when the artwork behind the bar
    /// is dark — see `TabBarTintModel`, which chooses between this and
    /// `dionysusPrimary` per hero.
    ///
    /// Same hue (333 degrees) and saturation (0.89) as `dionysusMagenta`,
    /// lifted to HSL lightness 0.73: recognisably the same brand magenta,
    /// light enough to survive the glass.
    ///
    /// Chosen against the *rendered* colour, not this raw one. The glass
    /// lifts whatever tint it is given by half the pill's own value —
    /// burgundy `(66, 0, 31)` renders as `(98, 32, 62)` on a `(64, 64, 64)`
    /// pill, i.e. +32 per channel. Clearing 4.5:1 there needs a rendered
    /// relative luminance of 0.406, so this renders to about
    /// `(255, 157, 211)`. Predicted 5.44:1, measured 5.84:1 live.
    /// Deliberately past the line rather than on it — HSL lightness 0.67
    /// lands on exactly 4.50:1 with no margin.
    ///
    /// Magenta rather than the amber or gold that clear the bar more
    /// easily (5.5:1 and 9.7:1): see `dionysusHighlight` for the palette's
    /// standing "no amber in dark" rule, and a glass pill over a
    /// near-black hero is a dark context.
    static let dionysusMagentaOnGlass = Color(red: 0.97, green: 0.49, blue: 0.70)

    /// Primary brand action colour. Burgundy on light backgrounds; magenta in
    /// dark (amber-in-dark reads as Plex-adjacent, so the palette leans on
    /// magenta + burgundy to stand out). Backed by a dynamic `UIColor` so any
    /// element rendered through UIKit adapts on trait changes too.
    ///
    /// `traits.accessibilityContrast == .high` (the system's Increase
    /// Contrast setting) swaps in `dionysusMagentaHighContrast` for the dark
    /// branch — see that constant's doc comment for the measured gap it
    /// closes. The light branch (burgundy) is untouched: it already measures
    /// ~16.8:1 against a white background, far past the minimum, so there's
    /// nothing for Increase Contrast to improve there.
    static let dionysusPrimary = Color(UIColor { traits in
        guard traits.userInterfaceStyle == .dark else {
            return UIColor(Color.dionysusBurgundy)
        }
        return UIColor(traits.accessibilityContrast == .high ? Color.dionysusMagentaHighContrast : Color.dionysusMagenta)
    })

    /// Inverse of `dionysusPrimary`: amber on light, burgundy on dark. Used
    /// for elements that need to contrast against a `dionysusPrimary` surface
    /// (e.g. a progress bar sitting on top of the primary Play button) —
    /// always composited on that surface, never bare against a plain system
    /// background, which is why only the light (amber) branch gets its own
    /// Increase Contrast swap below. The dark (burgundy) branch doesn't need
    /// one: burgundy-on-`dionysusPrimary` already measures ~3.3:1, but
    /// automatically becomes ~5.3:1 once `dionysusPrimary`'s own dark value
    /// picks up its Increase Contrast bump above — nothing extra to do here.
    static let dionysusProgress = Color(UIColor { traits in
        guard traits.userInterfaceStyle != .dark else {
            return UIColor(Color.dionysusBurgundy)
        }
        return UIColor(traits.accessibilityContrast == .high ? Color.dionysusAmberHighContrast : Color.dionysusAmber)
    })

    /// Highlight colour for accents sitting over media artwork (e.g. the
    /// rail-item progress bar over a poster). Amber in light, magenta in
    /// dark — the "no amber in dark" rule applies here too. Reuses the same
    /// Increase Contrast swaps as `dionysusPrimary`/`dionysusProgress` above
    /// (same underlying colours, just cross-wired by appearance) rather than
    /// introducing a third pair of high-contrast constants for what's
    /// already the same two colours.
    static let dionysusHighlight = Color(UIColor { traits in
        let highContrast = traits.accessibilityContrast == .high
        if traits.userInterfaceStyle == .dark {
            return UIColor(highContrast ? Color.dionysusMagentaHighContrast : Color.dionysusMagenta)
        }
        return UIColor(highContrast ? Color.dionysusAmberHighContrast : Color.dionysusAmber)
    })

    /// Favorite (heart) icon colour: Jellyfin's own favourite red, the same in
    /// both appearances, so a favourite looks the way it does in every other
    /// Jellyfin client. `#D15353` is jellyfin-web's `$error-light`, which its
    /// theme applies to a rated (favourited) heart,
    /// `.ratingbutton-icon-withrating` in `src/themes/_base/_theme.scss`.
    ///
    /// Deliberately outside the brand palette, like `dionysusWatched`. It
    /// replaced amber when favourite changed from a star to a heart: amber
    /// suited a star, the Mail/Podcasts/Files convention, and a heart reads
    /// as red.
    ///
    /// Measured contrast: 4.1:1 on white and on dark mode's `#1C1C1E`, above
    /// the 3:1 minimum for a non-text glyph in both. Increase Contrast moves it
    /// away from whichever background is current: jellyfin-web's own
    /// `$error-main` (`#C62828`, 5.6:1 on white) in light mode, and a lighter
    /// `#E57373` (7.0:1 on black) in dark mode, where `#C62828` would drop to
    /// 3.0:1.
    ///
    /// Used for the heart badge on rail items (`PosterCard
    /// .watchStatusOverlay`) and the favorite toolbar button and menu rows on
    /// asset detail pages (`HeroActionButtons`).
    static let dionysusFavorite = Color(UIColor { traits in
        guard traits.accessibilityContrast == .high else {
            return UIColor(red: 0xD1 / 255, green: 0x53 / 255, blue: 0x53 / 255, alpha: 1)
        }
        return traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xE5 / 255, green: 0x73 / 255, blue: 0x73 / 255, alpha: 1)
            : UIColor(red: 0xC6 / 255, green: 0x28 / 255, blue: 0x28 / 255, alpha: 1)
    })

    /// Watched (eye) icon colour — deliberately magenta in *both*
    /// appearances, the mirror-image deviation of `dionysusFavorite` above:
    /// confirmed live that the watched eye
    /// (toolbar button on `HeroActionButtons` and the badge on rail items,
    /// `PosterCard.watchStatusOverlay`) read as inconsistent between the two
    /// once `dionysusPrimary`'s usual light/dark swap put it at burgundy in
    /// light mode — dark mode's magenta (already what `dionysusPrimary`
    /// resolves to there) is the one that reads correctly, so this pins that
    /// same magenta for light mode too instead of letting it swap. Anywhere
    /// else that wants the app's general adaptive accent (the Play button,
    /// tab bar tint, active filter pills, ...) should keep using
    /// `dionysusPrimary` — this is scoped to the watched glyph specifically,
    /// not a replacement for it.
    static let dionysusWatched = Color(UIColor { traits in
        UIColor(traits.accessibilityContrast == .high ? Color.dionysusMagentaHighContrast : Color.dionysusMagenta)
    })
}
