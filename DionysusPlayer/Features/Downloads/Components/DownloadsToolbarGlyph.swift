import SwiftUI

extension View {
    /// Grows an icon-only Downloads toolbar button to HIG's **default**
    /// mobile control size of 44x44pt.
    ///
    /// Measured during the iPad HIG review (2026-09-03): the Downloads
    /// trash button reported a 28x36pt accessibility frame — above HIG's
    /// absolute 28x28pt floor, but below the 44x44pt default it asks for,
    /// and visibly the smallest tap target on the screen. Every Downloads
    /// screen's toolbar uses a bare `Image(systemName: "trash")` label,
    /// which sizes itself to the glyph; this pads the target out without
    /// changing the glyph's own appearance.
    ///
    /// Same "visible mark smaller than its tappable area" idiom
    /// `SearchResultGridCard`'s remove button and `DownloadsGridCard`'s
    /// retry button both use — see either for the identical rationale.
    func downloadsToolbarTapTarget() -> some View {
        frame(width: 44, height: 44).contentShape(Rectangle())
    }
}
