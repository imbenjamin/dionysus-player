import SwiftUI

/// Keeps the status bar and the toolbar legible on a page whose hero bleeds
/// under them (Home and every detail page), both over the hero and once it has
/// scrolled away.
///
/// **The status bar's colour is set here, not left to the system.** Nothing
/// else in the app chose it, and the system chose differently by device: light
/// over every hero on the Simulator, dark over every hero on an iPhone running
/// iOS 27, including dark artwork where it couldn't be read. So while the hero
/// is under the bars, `toolbarColorScheme(.dark)` asks for light status bar
/// content (and dark toolbar glass), and once the hero has gone the page's own
/// scheme is asked for explicitly. Not `nil`: that hands the choice back to the
/// system, which on the iOS 27 Simulator kept Home's clock light over the light
/// band.
///
/// **Over the hero**, a soft dark shade behind the bars keeps that light
/// content readable on bright artwork. The hero only darkens its own bottom
/// edge, for the logo.
///
/// **After the hero**, the posters and text that follow would pass straight
/// under the clock. The system's own top scroll edge effect handles that
/// unevenly: a blur across the top of the hero at rest on iOS 27, faint (and
/// absent on Home) on iOS 26, and missing entirely on iOS 18. So on iOS 27 it
/// is hidden while the hero is under the bars and shown once it has gone, the
/// native look. Earlier versions hide it and draw a bar-material band that
/// fades out just below the bars instead. Either way it cross-fades with the
/// shade as the hero's bottom edge reaches the bars.
///
/// The hero reports its height through `HeroHeightKey`. A page with no hero
/// (Home before its carousel loads) reports nothing, and the band is simply on.
///
/// Applied to the page's `ScrollView` itself, after any
/// `.ignoresSafeArea(edges: .top)`: `onScrollGeometryChange` and the edge
/// effect both act on the scroll view they're attached to. Home's scroll view
/// respects the top safe area and the detail pages' don't (see `HomeView`'s
/// hero comment for why), so the overlay measures where the bars end in window
/// coordinates rather than trusting either view's safe-area insets.
struct HeroScrollEdgeScrim: ViewModifier {
    /// The hero's height, from its top at the physical screen edge.
    @State private var heroHeight: CGFloat?
    /// Where the bars end, in window coordinates.
    @State private var barBottom: CGFloat = 0
    /// 0 while the hero is under the bars, 1 once it has scrolled away.
    @State private var progress: Double = 0
    /// Identifies this page to `HeroStatusBarScheme`, so a page that has
    /// already been replaced can't clear the scheme its replacement set.
    @State private var statusBarOwner = UUID()
    /// The page's own scheme, which the bars return to after the hero.
    @Environment(\.colorScheme) private var colorScheme

    /// Dark (light content) over the hero, the page's own scheme after it.
    private var barScheme: ColorScheme {
        Self.isOverHero(progress: progress) ? .dark : colorScheme
    }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(HeroHeightKey.self) { height in
                MainActor.assumeIsolated { heroHeight = height }
            }
            .onScrollGeometryChange(for: Double.self) { geometry in
                Self.progress(
                    scrolled: geometry.contentOffset.y + geometry.contentInsets.top,
                    heroHeight: heroHeight,
                    barBottom: barBottom
                )
            } action: { _, newProgress in
                progress = newProgress
            }
            .topScrollEdgeEffect(hidden: Self.isOverHero(progress: progress))
            .toolbarColorScheme(barScheme, for: .navigationBar)
            .onAppear { HeroStatusBarScheme.shared.claim(statusBarOwner, scheme: barScheme) }
            .onChange(of: barScheme) { _, scheme in HeroStatusBarScheme.shared.claim(statusBarOwner, scheme: scheme) }
            .onDisappear { HeroStatusBarScheme.shared.release(statusBarOwner) }
            .overlay(alignment: .top) { bands }
    }

    /// A zero-height marker at the top of the safe area gives `barBottom`; the
    /// two bands then extend up through the bars to the screen edge.
    private var bands: some View {
        Color.clear
            .frame(height: 0)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barBottom = $0 }
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    // Over the hero: a dark shade for the light status bar.
                    LinearGradient(
                        colors: [.black.opacity(Self.shadeOpacity), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: barBottom + Self.shadeExtent)
                    .opacity(1 - progress)

                    // After the hero: the bar material, fading out below the bars.
                    Rectangle()
                        .fill(.bar)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: Self.solidFraction(barBottom: barBottom)),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        }
                        .frame(height: barBottom + Self.fadeHeight)
                        .opacity(usesSystemEdgeEffect ? 0 : progress)
                }
                .offset(y: -barBottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    /// How far the material fades out below the bars.
    static let fadeHeight: CGFloat = 32
    /// How far the dark shade reaches below the bars, fading all the way.
    static let shadeExtent: CGFloat = 40
    /// The shade's strength at the screen edge: enough for light status bar
    /// content on bright artwork, without visibly darkening the hero.
    static let shadeOpacity: Double = 0.35
    /// How much scrolling the cross-fade takes, ending as the hero's bottom
    /// edge reaches the bars.
    static let rampDistance: CGFloat = 60
    /// How many steps the cross-fade takes: one every 3pt of the ramp, too
    /// fine to see in a fade this short.
    static let progressSteps: Double = 20

    /// How far the page has moved from "hero under the bars" (0) to "hero
    /// gone" (1) after scrolling `scrolled` points: 0 until the hero's bottom
    /// edge is within `rampDistance` of the bars, 1 once it has passed under
    /// them, and 1 throughout on a page with no hero. Quantised to
    /// `progressSteps`, so that scrolling outside the ramp leaves it unchanged
    /// and scrolling inside it re-renders the page every few points rather
    /// than every frame.
    static func progress(scrolled: CGFloat, heroHeight: CGFloat?, barBottom: CGFloat) -> Double {
        guard let heroHeight, heroHeight > 0 else { return 1 }
        let heroBottom = heroHeight - scrolled
        let raw = (barBottom + rampDistance - heroBottom) / rampDistance
        let clamped = min(max(raw, 0), 1)
        return (Double(clamped) * progressSteps).rounded() / progressSteps
    }

    /// Whether the hero is still what's behind the bars, so the status bar and
    /// toolbar should be light. Flips at the cross-fade's midpoint.
    static func isOverHero(progress: Double) -> Bool {
        progress < 0.5
    }

    /// Where the solid part of the material ends, as a fraction of its height.
    static func solidFraction(barBottom: CGFloat) -> CGFloat {
        let total = barBottom + fadeHeight
        return total > 0 ? barBottom / total : 0
    }
}

/// The height of the hero at the top of a page, from the physical screen
/// edge. Set by `HeroRailView` and `HeroHeaderView`, read by
/// `HeroScrollEdgeScrim`. `nil` when there's no hero.
struct HeroHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// See `HeroScrollEdgeScrim`.
    func heroScrollEdgeScrim() -> some View {
        modifier(HeroScrollEdgeScrim())
    }
}

/// The status bar colour the page on screen asks for, applied at the app's
/// root (`DionysusPlayerApp`).
///
/// It has to be the root: on an iPhone running iOS 27 the root hosting
/// controller decides the status bar style itself, asking for dark content
/// whatever the page below it wants, and never hands the decision to the
/// navigation stack (measured on device: `preferredStatusBarStyle` 3,
/// `childForStatusBarStyle` nil, over the hero and after it). A
/// `toolbarColorScheme` on the page reaches its own toolbar but not that
/// controller. Once the system scroll edge effect was hidden the status bar
/// followed the navigation bar again, which is why the band alone worked.
///
/// One page owns the value at a time. A page claims it on appearing and
/// whenever its scheme changes, and releases it on disappearing, but only if
/// it's still the owner: a push shows the new page before the old one
/// disappears.
@MainActor @Observable
final class HeroStatusBarScheme {
    static let shared = HeroStatusBarScheme()

    private(set) var scheme: ColorScheme?
    private var owner: UUID?

    func claim(_ owner: UUID, scheme: ColorScheme) {
        self.owner = owner
        if self.scheme != scheme { self.scheme = scheme }
    }

    func release(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        scheme = nil
    }
}

extension View {
    /// Sets the status bar's own colour scheme, on iOS 27, where the
    /// `.statusBar` placement was added. Compiled only with the iOS 27 SDK
    /// (Swift 6.4), since the placement doesn't exist in earlier ones; CI's
    /// Xcode 26 builds skip it, and keep the material band, whose status bar
    /// follows the navigation bar's scheme (see `usesSystemEdgeEffect`).
    @ViewBuilder
    func statusBarColorScheme(_ scheme: ColorScheme?) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            toolbarColorScheme(scheme, for: .statusBar)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Whether the system's top scroll edge effect replaces the material band.
/// iOS 27 only: measured on the iOS 26.5 Simulator, the effect never appeared
/// on Home (whose scroll view stops at the safe area) and was too faint on the
/// detail pages to keep the clock off the text beneath it.
///
/// Also only when built with the iOS 27 SDK: the effect takes over the
/// status bar's colour, and only that SDK has the `.statusBar` placement to
/// set it back (see `statusBarColorScheme`). A build from Xcode 26 keeps the
/// band, whose status bar follows `toolbarColorScheme` as before.
private var usesSystemEdgeEffect: Bool {
    #if compiler(>=6.4)
    if #available(iOS 27.0, *) { return true }
    #endif
    return false
}

private extension View {
    /// On iOS 27, shows the system's top scroll edge effect only once the hero
    /// has scrolled away: over the hero it blurred the artwork at rest. On iOS
    /// 26, hides it for good, since the material band stands in for it there.
    /// No-op before iOS 26, which has none.
    @ViewBuilder
    func topScrollEdgeEffect(hidden: Bool) -> some View {
        if #available(iOS 26.0, *) {
            // `.soft` explicitly: left to `.automatic`, iOS 27 on iPhone drew
            // the effect behind the status bar only, not the toolbar.
            scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(hidden || !usesSystemEdgeEffect, for: .top)
        } else {
            self
        }
    }
}

