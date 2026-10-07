import SwiftUI

extension View {
    /// Menu away from a page's landing view goes back to it (Benjamin,
    /// 2026-10-07): the page scrolls to its top and focus goes to the item it
    /// opens on. At the landing view the handler is `nil`, so Menu reaches
    /// the shell, which pops a pushed page or opens the sidebar.
    ///
    /// A lazy stack may have torn the landing item down after a long scroll,
    /// so `scrollToTop` runs first and focus is set until it holds.
    func tvMenuReturnsToLanding<ID: Hashable>(
        _ focus: FocusState<ID?>.Binding, landing: ID?, isAway: Bool, scrollToTop: @escaping () -> Void
    ) -> some View {
        onExitCommand(perform: isAway ? landing.map { target in
            {
                scrollToTop()
                Task { @MainActor in
                    for _ in 0..<20 {
                        if focus.wrappedValue == target { return }
                        focus.wrappedValue = target
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
        } : nil)
    }

    /// Sends a scroll view back to its top whenever `request` changes, and
    /// reports whether it has left its top. Applied to the `ScrollView`.
    func tvScrollsToTop(on request: Int, isScrolled: Binding<Bool>? = nil) -> some View {
        modifier(TVScrollsToTop(request: request, isScrolled: isScrolled))
    }
}

private struct TVScrollsToTop: ViewModifier {
    let request: Int
    let isScrolled: Binding<Bool>?
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, scrolled in
                isScrolled?.wrappedValue = scrolled
            }
            .onChange(of: request) {
                withAnimation(.easeInOut(duration: 0.3)) { position.scrollTo(edge: .top) }
            }
    }
}
