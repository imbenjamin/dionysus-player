import SwiftUI
import UIKit

/// Picks the tab bar's selected-item tint from the artwork currently
/// behind the bar.
///
/// ## Why this exists
///
/// On iPadOS 26 the floating tab bar is Liquid Glass. Its selection pill
/// takes its tone from whatever is behind it, while the selected item's
/// label is painted from `MainTabView`'s `.tint(_:)` — so the two move
/// independently and a fixed tint is legible at only one end of the
/// range. Measured live (2026-09-04, iPad A16) by sweeping the Home hero
/// carousel and sampling the rendered label against its own pill:
///
/// | tint | dark pills (58–82) | light pills (125–227) |
/// | --- | --- | --- |
/// | `dionysusPrimary` (burgundy) | 1.05–1.67:1 FAIL | 5.22–13.76:1 PASS |
/// | `dionysusMagentaOnGlass` | 5.13–5.92:1 PASS | 1.35–2.26:1 FAIL |
///
/// Worst observed case was 1.05:1 — burgundy on a near-black hero, where
/// the glyph is actually *darker* than the pill under it, so what
/// legibility remains comes from hue rather than luminance. Against a
/// 4.5:1 minimum for text this size.
///
/// Neither colour wins outright, but between them they cover the range,
/// which is what this type exploits: sample the artwork, pick the colour
/// that suits it.
///
/// ## What was tried first
///
/// - **Recolouring alone.** Moves the failure rather than removing it —
///   that is what the table above shows.
/// - **Giving Home a toolbar item.** The theory was that a populated
///   navigation bar puts the tab bar into a system-managed appearance
///   that manages its own contrast. Built and swept: 11/16 frames still
///   failed, worst case 1.05:1, label visibly unchanged. The evidence
///   that suggested it was a single-frame comparison whose two frames
///   had different artwork behind the bar — not a real effect.
///
/// ## What this does and does not fix
///
/// Swept live over 18 carousel frames: **2 failures**, against 6 of 14
/// for burgundy alone and 8 of 16 for the light tint alone. Both
/// survivors were saturated mid-tone backdrops — a vivid red and a pale
/// cyan — where the light tint was still chosen but the pill had
/// already gone bright (1.78:1 and 1.59:1).
///
/// The residual cause is the sampling, not the threshold. This measures
/// the *source image's* top strip, while what matters is the strip the
/// aspect-filled hero actually puts behind the bar; for those two frames
/// the two diverged sharply. Reproducing the fill geometry — or
/// weighting by saturation, since both survivors were highly saturated —
/// is where to look next if this is worth pushing further.
///
/// One genuine difference between Home and a pushed screen remains
/// unexplained: on a detail page the selection pill stayed at 173.8 even
/// with a dark backdrop scrolled behind it, where Home's pill tracks the
/// artwork down to 58. If that mechanism is ever identified it may well
/// be a cleaner fix than this, and this type should be revisited.
@Observable
@MainActor
final class TabBarTintModel {
    static let shared = TabBarTintModel()

    private init() {}

    /// Mean relative luminance (0...1) of the strip of artwork the tab
    /// bar sits over, or `nil` when nothing is on screen behind it (any
    /// tab other than Home, or Home before its hero has loaded).
    private(set) var backdropLuminance: Double?

    /// Below this, the backdrop is dark enough that the pill goes dark
    /// too and burgundy disappears into it.
    ///
    /// Both this value and 0.05 were built and swept live. 0.15 failed
    /// 2 of 18 frames; 0.05 failed 5 of 20. The lower value looked
    /// better on paper — every frame that passed on the light tint had
    /// measured at or below 0.032 — and was worse in practice, because
    /// it pushed borderline-dark heroes onto burgundy, which then failed
    /// them. 0.15 is kept on the measurement, not the theory.
    ///
    /// Expressed against the *artwork*, not the pill — those are
    /// correlated but not equal, since the glass mixes its own fill in.
    private static let threshold = 0.15

    /// Applied either side of `threshold` so a hero whose luminance sits
    /// right on the line can't flip the tint back and forth as the
    /// carousel cross-fades. The tint only changes once the backdrop is
    /// clearly on one side.
    private static let hysteresis = 0.04

    /// Whether the *light* tint is currently in effect. Stored rather
    /// than derived so `hysteresis` has a previous state to work from.
    private var usesLightTint = false

    var tint: Color {
        usesLightTint ? .dionysusMagentaOnGlass : .dionysusPrimary
    }

    /// Guard-before-write on both properties: this is an `@Observable`
    /// singleton read from `MainTabView.body`, so an unconditional
    /// assignment would invalidate the whole tab container on every
    /// carousel advance even when nothing actually changed. Same reason
    /// `ConnectivityMonitor` guards its own writes.
    func update(backdropLuminance luminance: Double?) {
        if backdropLuminance != luminance {
            backdropLuminance = luminance
        }

        let shouldUseLightTint: Bool
        switch luminance {
        case nil:
            shouldUseLightTint = false
        case let value?  where usesLightTint:
            // Already light: stay light until the backdrop is clearly bright.
            shouldUseLightTint = value < Self.threshold + Self.hysteresis
        case let value?:
            // Already burgundy: switch only once the backdrop is clearly dark.
            shouldUseLightTint = value < Self.threshold - Self.hysteresis
        }

        if usesLightTint != shouldUseLightTint {
            usesLightTint = shouldUseLightTint
        }
    }

    /// Mean relative luminance of the top slice of `image` — the part a
    /// full-bleed hero puts behind the tab bar.
    ///
    /// `topFraction` is deliberately generous. The tab bar occupies
    /// roughly the top 16% of the hero's height, but a hero is
    /// aspect-*filled*, so the visible top strip isn't exactly the
    /// image's own top strip whenever the aspect ratios differ. Since
    /// this only has to decide light-or-dark, an approximate region is
    /// enough and is cheaper than reproducing the fill geometry.
    ///
    /// Averages in sRGB and linearises once at the end, rather than
    /// linearising every pixel and averaging that. Not strictly the same
    /// number, but the difference is far smaller than the margin either
    /// side of `threshold`, and it lets CoreGraphics do the averaging by
    /// downsampling to a single pixel.
    nonisolated static func topStripLuminance(of image: UIImage, topFraction: Double = 0.2) -> Double? {
        guard let source = image.cgImage else { return nil }
        let stripHeight = max(1, Int(Double(source.height) * topFraction))
        guard let strip = source.cropping(
            to: CGRect(x: 0, y: 0, width: source.width, height: stripHeight)
        ) else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixel[0]) + 0.7152 * linear(pixel[1]) + 0.0722 * linear(pixel[2])
    }
}

extension View {
    /// Pins a tab's own content to the brand tint, so it stops inheriting
    /// the artwork-derived one `MainTabView` sets for the tab bar.
    ///
    /// `TabBarTintModel`'s tint is chosen for one specific surface: the
    /// Liquid Glass selection pill, floating over Home's hero. SwiftUI's
    /// `.tint(_:)` is not that narrow — set on the `TabView` it becomes the
    /// accent for everything inside it, including the toolbars of screens
    /// pushed onto each tab's `NavigationStack`, which have no hero behind
    /// them and never will.
    ///
    /// Measured on `CollectionGridView` (iPad A16, 2026-09-04) while the
    /// model had settled on the light tint after a dark Home hero — its
    /// Sort and Random glyphs render `dionysusMagentaOnGlass` over a white
    /// glass capsule at **2.46:1**, under the 3:1 minimum for a non-text
    /// control (and under 4.5:1 read as a small icon). `dionysusPrimary`
    /// on the same capsule measures 16.78:1. Nothing about that screen
    /// varies — its background is the system background in both
    /// appearances — so the tint that suits the pill is simply wrong
    /// there, whichever one is currently in effect.
    ///
    /// Applied to each `NavigationStack` itself, *outside* its content
    /// closure. Inside doesn't work: a navigation bar resolves its tint
    /// from above whichever view declared the `.toolbar`, so tinting the
    /// stack's content left the failing glyphs measuring 2.46:1
    /// unchanged. `.tabItem` is attached after this, wrapping the
    /// already-tinted stack, so the tab bar's own selected label still
    /// reads `TabBarTintModel`'s tint.
    func stableContentTint() -> some View {
        tint(Color.dionysusPrimary)
    }
}
