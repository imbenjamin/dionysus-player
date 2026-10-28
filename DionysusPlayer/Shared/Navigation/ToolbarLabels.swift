import SwiftUI

/// Whether the toolbar this sits in is a vertical bar. `toolbarVerticalEdge` is
/// `nil` wherever the system never places one, every device but an iPhone Duo.
/// A view of its own because the key is iOS 27.1 and a stored `@Environment`
/// can't be gated.
@available(iOS 27.1, *)
struct VerticalBarReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(edge != nil) }
}

/// Which edge an iPhone Duo's vertical bar is on, or `nil` without one. See
/// `VerticalBarReader`.
@available(iOS 27.1, *)
struct VerticalBarEdgeReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    @ViewBuilder let content: (HorizontalEdge?) -> Content

    var body: some View { content(edge) }
}

extension View {
    /// A toolbar button that reads as its title on a horizontal bar and as its
    /// symbol in an iPhone Duo's vertical bar. Give the button both
    /// (`Button("Select", systemImage: "checkmark.circle", …)`).
    ///
    /// iOS 26 draws a toolbar button with a symbol as the symbol alone, and
    /// "Select" or "Cancel" say what they do more clearly than a glyph
    /// (Benjamin, 2026-10-27). But the vertical bar shows symbols only: an item
    /// with just a title, or `.labelStyle(.titleOnly)` everywhere, is left
    /// behind in a horizontal bar of its own (measured on the Duo held wide).
    func toolbarTitleUnlessVertical() -> some View {
        modifier(ToolbarTitleUnlessVertical())
    }
}

private struct ToolbarTitleUnlessVertical: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            VerticalBarReader { isVertical in
                if isVertical {
                    content
                } else {
                    content.labelStyle(.titleOnly)
                }
            }
        } else {
            content.labelStyle(.titleOnly)
        }
    }
}
