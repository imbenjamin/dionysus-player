import SwiftUI

/// Which composition the pre-sign-in journey (`OnboardingFlowView`) uses.
///
/// Decided from the size class and the whole window's size, never from the
/// device idiom. An iPad app in a narrow Split View or Slide Over window
/// gets the phone composition, and a foldable iPhone gets both: its outer
/// screen (466x678pt) is a phone, its unfolded inner one (951x669pt, regular
/// size class) is closer to an iPad mini.
enum OnboardingLayout: Equatable {
    /// iPhone, and any narrow iPad window: one column, actions pinned to the
    /// bottom edge where the thumb is.
    case compact
    /// A wide window taller than it is wide (iPad portrait): one centred
    /// block, scaled up, with actions directly under their content. The
    /// bottom edge has no reach advantage on a tablet, and pinning there
    /// left a button ~600pt from what it acted on.
    case regular
    /// A wide window wider than it is tall: brand on the left, the task on
    /// the right.
    case landscape

    /// `windowSize` is the whole window, safe areas included — it's a
    /// question of the window's shape. Measured without them, a foldable's
    /// vertical status bar took enough width off its 951pt inner screen to
    /// drop it under the landscape threshold.
    ///
    /// Landscape starts at 900pt rather than at an iPad's 1133: the unfolded
    /// foldable held sideways is 951x669, and the portrait composition
    /// there overflowed its height.
    static func resolve(windowSize: CGSize, horizontalSizeClass: UserInterfaceSizeClass?) -> OnboardingLayout {
        guard horizontalSizeClass == .regular, windowSize.width >= 600 else { return .compact }
        return windowSize.width > windowSize.height && windowSize.width >= 900 ? .landscape : .regular
    }

    var isRegular: Bool { self != .compact }

    /// The welcome screen's glyph.
    var heroGlyph: CGFloat {
        switch self {
        case .compact: 104
        case .regular: 180
        case .landscape: 200
        }
    }

    /// The glyph above the server-setup and sign-in titles.
    var headerGlyph: CGFloat {
        switch self {
        case .compact: 44
        case .regular: 88
        case .landscape: 120
        }
    }

    /// The brand screens' content width — wider than the forms' 500pt
    /// (`SignInLayout.credentialsWidth`) on iPad, where 500 read as small.
    var contentWidth: CGFloat {
        switch self {
        case .compact: SignInLayout.credentialsWidth
        case .regular: 720
        case .landscape: 600
        }
    }

    /// Actions stop being edge-to-edge once they aren't in a thumb bar.
    var actionWidth: CGFloat { isRegular ? 380 : .infinity }

    var avatar: CGFloat { isRegular ? 120 : 84 }
    var tileWidth: CGFloat { isRegular ? 150 : 104 }

    /// A landscape window short enough that full-size tiles and gutters crowd
    /// it: the unfolded foldable (951x669pt) and iPad mini (1133x744), not the
    /// larger iPads (820pt tall and up).
    static func isShortLandscape(_ layout: OnboardingLayout, windowSize: CGSize) -> Bool {
        layout == .landscape && windowSize.height < 800
    }
}

extension EnvironmentValues {
    @Entry var onboardingLayout: OnboardingLayout = .compact
    /// The whole window's size, for the few metrics that depend on more than
    /// which composition is in use.
    @Entry var onboardingWindowSize: CGSize = .zero
    /// Set by `OnboardingFlowView` so each screen's glyph can take part in
    /// one matched-geometry transition — the glyph moves between screens
    /// rather than cutting. `nil` outside the flow (previews).
    @Entry var onboardingGlyphNamespace: Namespace.ID?
}
