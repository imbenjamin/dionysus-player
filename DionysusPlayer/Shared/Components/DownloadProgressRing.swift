import SwiftUI

/// A download-progress indicator — a determinate `Circle().trim(from:to:)`
/// ring, or a plain indeterminate spinner when the total size genuinely
/// isn't known (Jellyfin's live-transcode download stream commonly doesn't
/// report one — see `DownloadProgress.totalBytesExpected`'s doc comment —
/// so this has to be the common case this view handles gracefully, not a
/// rare fallback). SwiftUI's built-in `ProgressView(value:)` restyled with
/// `.circular` only spins indeterminately on iOS regardless of `value`
/// (unlike watchOS, which does render a determinate ring for it), which is
/// why the determinate case below is hand-rolled instead.
///
/// Tried `Image(systemName: "arrow.down.circle", variableValue:)` instead
/// of this hand-rolled shape (iOS 16's native "Variable Color" SF Symbol
/// API) for visual consistency with the button's own idle/complete-state
/// glyphs — reverted, confirmed live (2026-08-19): the API silently
/// accepts a `variableValue` for *any* symbol without erroring, but only
/// actually renders a graduated fill for symbols Apple specifically
/// annotated with that capability in the system symbol data, and
/// `"arrow.down.circle"` isn't one of them — the icon rendered essentially
/// static regardless of the real percentage. Don't retry that approach for
/// this specific glyph without first confirming in the SF Symbols app that
/// *this exact symbol* (not a same-shaped one) has "Variable Color"
/// annotated layers, not just that the app's UI lets a value be set.
///
/// Used by `DownloadButton` (detail pages) and the Downloads tab's list
/// rows/detail page. Deliberately no percentage label (every call site
/// already shows one as adjacent text) and no `.animation(...)` on the
/// trim — an earlier version had both; the animation in particular caused
/// a real, confirmed-live desync: with progress updates arriving several
/// times a second, each one restarted a fresh animation toward the new
/// target before the previous one finished, so the ring perpetually
/// chased a moving target and visibly lagged behind the true value.
/// Snapping straight to the exact current fraction, same as the adjacent
/// percentage text, is what keeps the two in sync.
struct DownloadProgressRing: View {
    var progress: DownloadProgress
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            if progress.isTotalKnown {
                Circle()
                    .stroke(Color.dionysusPrimary.opacity(0.2), lineWidth: lineWidth)
                Circle()
                    // A sliver (2%) floor rather than 0 — a fresh download
                    // reads as "nothing's happening" at a literal empty
                    // ring rather than "just started".
                    .trim(from: 0, to: max(0.02, min(1, progress.fractionCompleted)))
                    .stroke(Color.dionysusPrimary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.dionysusPrimary)
            }
        }
    }
}
