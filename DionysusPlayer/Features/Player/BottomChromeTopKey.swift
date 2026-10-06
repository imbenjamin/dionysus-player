import SwiftUI

/// Global y of the top edge of the player's bottom chrome — the scrubber row
/// plus the chapter/format row beneath it — published so the subtitle overlay
/// can sit clear of it. On the Apple TV, the transport's bottom bar. See
/// `SubtitleOverlayView.bottomInset(controlsVisible:controlsTop:overlayMaxY:metrics:)`.
///
/// `.infinity` when nothing reports, which reads as "no chrome to clear" and
/// leaves the subtitle at its resting position.
struct BottomChromeTopKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    /// Topmost wins: the clearance has to cover everything reporting.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}
