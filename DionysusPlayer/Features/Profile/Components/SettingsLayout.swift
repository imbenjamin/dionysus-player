import SwiftUI

/// Shared layout rules for the Profile/Settings screens.
///
/// ## Why these screens test *both* size classes
///
/// Home, Search and Downloads all adapt on `horizontalSizeClass ==
/// .regular` alone (see `DownloadsGrid`'s doc comment). The settings
/// screens deliberately don't: they additionally require
/// `verticalSizeClass == .regular`, i.e. a real iPad rather than any
/// regular-width container.
///
/// An iPhone Pro Max in landscape reports **regular width, compact
/// height** — 932pt across but only 430pt tall. A wider grid is
/// harmless there (a row of posters doesn't care how short the screen
/// is), which is why the grids don't bother distinguishing. A
/// sidebar-plus-detail split very much does care: it would put two
/// scrolling columns into 430pt of height, which is worse than the
/// single-column list it replaced. So the split is gated on iPad only.
///
/// There's no shared `isPad` environment value for this — each screen
/// declares the two `@Environment` properties and ANDs them itself.
/// A computed `EnvironmentValues` property reading two other
/// environment keys would be tidier to call, but relies on SwiftUI
/// registering a dependency on both underlying keys through the
/// indirection; the explicit version is three lines and has no such
/// question hanging over it.
enum SettingsLayout {
    /// Cap for explanatory footer paragraphs on iPad — see
    /// `readableSettingsFooter()`.
    ///
    /// Grounded in this app's own measured rendering rather than a
    /// round number: the Playback footer's ~230-character string wraps
    /// into exactly 2 lines at a measured 780pt width, i.e. ~115
    /// characters per line, i.e. ~6.8pt per character at footnote size.
    /// The conventional readable maximum is 75 characters, so
    /// 75 x 6.8 ~= 510pt, rounded to 520.
    static let readableFooterWidth: CGFloat = 520
}

/// Constrains a `List` section footer to a readable measure on iPad.
///
/// Unconstrained, these paragraphs run the full width of whatever
/// contains them — 780pt in iPad portrait and 1140pt in landscape on an
/// 11-inch device, which works out at roughly 120 and 175 characters per
/// line respectively, against a 45-75 optimum. Apple's own guidance is
/// that system layout guides exist partly to "restrict the width of text
/// for optimal readability"; nothing in a plain `List` footer does that
/// for you.
///
/// Deliberately scoped to *footers only*, not to the rows above them.
/// Settings.app lets its rows fill the detail pane, so leaving rows
/// full-width is genuine platform parity; it's the long explanatory
/// prose, not the label/control pairs, where the line length actually
/// hurts.
private struct ReadableSettingsFooter: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// See this file's top-of-file comment for why this is an AND of
    /// both size classes rather than the width-only test used elsewhere.
    private var isPadLayout: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    func body(content: Content) -> some View {
        content.frame(
            maxWidth: isPadLayout ? SettingsLayout.readableFooterWidth : .infinity,
            alignment: .leading
        )
    }
}

extension View {
    /// See `ReadableSettingsFooter`. No-op outside iPad, so it's safe to
    /// apply unconditionally to any settings footer.
    func readableSettingsFooter() -> some View {
        modifier(ReadableSettingsFooter())
    }
}
