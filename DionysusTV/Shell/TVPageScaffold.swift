import SwiftUI

/// The shell's measurements, from the prototype (`tv.css`'s `.rail-nav` and
/// the Sidebar board), in points from the screen's own edges.
enum TVShellMetrics {
    /// The collapsed rail: 40pt in from the left, 104pt wide.
    static let railLeading: CGFloat = 40
    static let railWidth: CGFloat = 104
    /// Where page content starts: the rail's right edge and a 56pt gap.
    /// Content never runs under the rail (Benjamin, 2026-10-01). The gap is
    /// what a focused control's shape needs on its left: at 40pt the system's
    /// focus platter around a plain button (the detail page's Details panel)
    /// was sliced off at the clip (Benjamin, 2026-10-02).
    static let contentInset: CGFloat = railLeading + railWidth + 56
    /// Room left of the content before it's clipped, for a focused first
    /// column's lift, platter and shadow. The clip stays 10pt clear of the
    /// rail.
    static let clipSlack: CGFloat = 46
    /// How far the open sidebar pushes the content right, and how much it
    /// dims the screen behind it.
    static let pushDistance: CGFloat = 440
    /// How far left the collapsed rail slides to leave the screen
    /// (`TVShellNavigation.hidesCollapsedRail`). Measured: at its frame's
    /// width and a margin (204pt) about 18pt of its glass still showed.
    static let railOffScreen: CGFloat = 400
    static let dimOpacity = 0.45
}

/// Every signed-in page's frame: its background fills the screen, behind
/// the rail too, while its content starts right of the rail and is clipped
/// there, so a scrolled row never slides under it. While the sidebar is open
/// the content (not the background) is pushed right, as the prototype draws
/// it. Without a background of its own, a page sits on the shell's plum glow
/// (Benjamin, 2026-10-01); Home and the detail pages bring their own backdrop.
struct TVPageScaffold<Background: View, Content: View>: View {
    enum Layout {
        /// Right of the rail, clipped there.
        case besideRail
        /// The whole screen within its safe area, for a page drawn on screens
        /// where the shell hides the collapsed rail (Search).
        case fullScreen
    }

    @Environment(\.tvSidebarExpanded) private var sidebarExpanded
    private let layout: Layout
    private let background: Background
    private let content: Content

    init(layout: Layout = .besideRail, @ViewBuilder background: () -> Background, @ViewBuilder content: () -> Content) {
        self.layout = layout
        self.background = background()
        self.content = content()
    }

    var body: some View {
        switch layout {
        case .besideRail: besideRail
        case .fullScreen:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
                .offset(x: sidebarExpanded ? TVShellMetrics.pushDistance : 0)
                .background { background.ignoresSafeArea() }
        }
    }

    private var besideRail: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The whole content area, so Right from any sidebar row enters
            // the page, even where nothing sits level with the row (Profile's
            // buttons are mid-screen, its row at the top).
            .focusSection()
            .padding(.leading, TVShellMetrics.clipSlack)
            // Clipped on the left only: a focused tile still lifts past the
            // top, bottom and right of the page.
            .mask(alignment: .leading) {
                Rectangle()
                    .padding(.vertical, -400)
                    .padding(.trailing, -400)
            }
            .padding(.leading, TVShellMetrics.contentInset - TVShellMetrics.clipSlack)
            .ignoresSafeArea(edges: .leading)
            .offset(x: sidebarExpanded ? TVShellMetrics.pushDistance : 0)
            .background { background.ignoresSafeArea() }
    }
}

extension TVPageScaffold where Background == EmptyView {
    /// A page on the shell's own background (`TVPageBackground`), which the
    /// shell draws once beneath every page rather than each page drawing its
    /// own: a page fades in when chosen, and its own copy fading in with it
    /// showed the window's plain black for a frame.
    init(layout: Layout = .besideRail, @ViewBuilder content: () -> Content) {
        self.init(layout: layout, background: { EmptyView() }, content: content)
    }
}

/// The default page ground, drawn once by the shell beneath every page: a
/// plum glow from the top left.
struct TVPageBackground: View {
    var body: some View {
        RadialGradient(
            colors: [Color(red: 42 / 255, green: 10 / 255, blue: 28 / 255), Color(red: 11 / 255, green: 2 / 255, blue: 8 / 255)],
            center: UnitPoint(x: 0.2, y: 0),
            startRadius: 0,
            endRadius: 1300
        )
    }
}
