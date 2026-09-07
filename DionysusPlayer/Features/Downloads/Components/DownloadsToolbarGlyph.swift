import SwiftUI

extension View {
    /// Grows an icon-only Downloads toolbar button toward HIG's
    /// **default** mobile control size of 44x44pt.
    ///
    /// "Toward", not "to": the nav bar clamps a toolbar item's height to
    /// its own, so the 44x44 frame below actually lands as 48x36pt
    /// (measured on every adopter). The width the frame asks for is
    /// honoured and then some; the height isn't. That still clears HIG's
    /// 28x28pt floor on both axes and roughly doubles the tappable area,
    /// which is what this is for — a taller target would need the button
    /// out of the toolbar entirely.
    ///
    /// Measured during the iPad HIG review (2026-09-03): the Downloads
    /// trash button reported a 28x36pt accessibility frame — above HIG's
    /// absolute 28x28pt floor, but below the 44x44pt default it asks for,
    /// and visibly the smallest tap target on the screen. Every Downloads
    /// screen's toolbar uses a bare `Image(systemName: "trash")` label,
    /// which sizes itself to the glyph; this pads the target out without
    /// changing the glyph's own appearance.
    ///
    /// Apply it to *every* such button. `DownloadedAssetDetailView`'s
    /// Delete Download button was missed when this was introduced and
    /// stayed at 28x36pt for a further page of the same review
    /// (2026-09-04) — it's the one Downloads toolbar that isn't a
    /// `DownloadsView`-family list, which is exactly why it fell out of
    /// the sweep.
    ///
    /// Same "visible mark smaller than its tappable area" idiom
    /// `SearchResultGridCard`'s remove button and `DownloadsGridCard`'s
    /// retry button both use — see either for the identical rationale.
    func downloadsToolbarTapTarget() -> some View {
        frame(width: 44, height: 44).contentShape(Rectangle())
    }
}
