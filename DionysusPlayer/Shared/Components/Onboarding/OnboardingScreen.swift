import SwiftUI

/// The three compositions every screen of the pre-sign-in journey shares:
///
/// - Compact: scrolling content with its actions pinned in a bar at the
///   bottom edge, the phone layout.
/// - Regular: one block centred on screen, actions inline under the content.
/// - Landscape: two panes — `brand` (glyph, title) centred on the left, the
///   task and its actions centred on the right.
///
/// See `OnboardingLayout` for how the composition is chosen.
struct OnboardingScreen<Brand: View, Content: View, Actions: View>: View {
    /// Whether the compact composition centres vertically (a picker) or reads
    /// from the top (a page ending in a pinned action).
    var centersCompact = false
    @ViewBuilder let brand: Brand
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    @Environment(\.onboardingLayout) private var layout
    @Environment(\.onboardingWindowSize) private var windowSize

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                composition(viewport: proxy.size)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .modifier(PinnedActionBar(isPinned: layout == .compact && hasActions) {
                actions
                    .padding(.horizontal, SignInLayout.contentPadding)
                    .padding(.vertical, 12)
                    .signInColumn()
            })
        }
    }

    @ViewBuilder
    private func composition(viewport: CGSize) -> some View {
        switch layout {
        case .compact:
            VStack(spacing: 32) {
                brand
                content
            }
            .padding(.horizontal, SignInLayout.contentPadding)
            .padding(.top, centersCompact ? 24 : 40)
            .padding(.bottom, 24)
            .frame(maxWidth: layout.contentWidth)
            // Centred in the screen when it fits, the way a picker sits;
            // scrolling from the top when it doesn't.
            .frame(maxWidth: .infinity, minHeight: centersCompact ? viewport.height * 0.85 : nil)
        case .regular:
            VStack(spacing: 44) {
                brand
                content
                actionColumn
            }
            .padding(48)
            .frame(maxWidth: layout.contentWidth + 96)
            .frame(maxWidth: .infinity, minHeight: viewport.height)
        case .landscape:
            let isShort = OnboardingLayout.isShortLandscape(layout, windowSize: windowSize)
            let gutter: CGFloat = isShort ? 40 : 64
            // The task pane takes a little over half the width, up to its
            // cap: an even split left a short landscape window's pane too
            // narrow for three avatars a row.
            let taskWidth = min(layout.contentWidth, (viewport.width - gutter * 3) * 0.56)
            HStack(spacing: gutter) {
                brand
                    .frame(maxWidth: .infinity)
                VStack(spacing: isShort ? 24 : 36) {
                    content
                    actionColumn
                }
                .frame(width: max(0, taskWidth))
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, isShort ? 24 : 40)
            .frame(maxWidth: .infinity, minHeight: viewport.height)
        }
    }

    /// Nothing at all for a screen without actions: a zero-size frame would
    /// still take a slot in the stack, and the stack's spacing with it.
    @ViewBuilder
    private var actionColumn: some View {
        if hasActions {
            actions.frame(maxWidth: layout.actionWidth)
        }
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }
}

/// Pins the compact composition's actions to the bottom edge.
///
/// iOS 26's `safeAreaBar` rather than `safeAreaInset`: it gives the bar the
/// system scroll-edge effect, so content scrolling under the button fades out
/// behind it. With a plain inset, a short screen (a foldable's outer display,
/// or large text) showed the last feature row's text straight through the
/// button. Before iOS 26 a gradient scrim does the same job.
private struct PinnedActionBar<Bar: View>: ViewModifier {
    let isPinned: Bool
    @ViewBuilder let bar: Bar

    func body(content: Content) -> some View {
        if !isPinned {
            content
        } else if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) { bar }
        } else {
            content.safeAreaInset(edge: .bottom) {
                bar.background {
                    LinearGradient(
                        colors: [.clear, Color.dionysusBurgundy.opacity(0.9)],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .padding(.top, -24)
                    .ignoresSafeArea()
                }
            }
        }
    }
}
