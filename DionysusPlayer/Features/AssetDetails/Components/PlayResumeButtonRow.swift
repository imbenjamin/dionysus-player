import SwiftUI

/// The Play/Resume + Restart button row on the movie and show detail pages.
///
/// - Not-yet-watched: single "Play" button.
/// - Part-watched: "Resume" button (shortened to make room), a small
///   icon-only "Restart" button next to it, and a thin `dionysusProgress`
///   bar along the bottom of the primary button showing playback progress.
struct PlayResumeButtonRow: View {
    let item: MediaItem
    var onPlay: () -> Void
    var onRestart: () -> Void

    /// Corner radius applied to both the button's border shape AND the outer
    /// clip. Matching the two is what makes the progress bar tuck in behind
    /// the button's curved edges instead of poking past them.
    private let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                Label(item.isPartWatched ? "Resume" : "Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
            .tint(.dionysusPrimary)
            .controlSize(.large)
            .overlay(alignment: .bottom) {
                if item.isPartWatched, let fraction = item.playedFraction {
                    GeometryReader { geo in
                        Color.dionysusProgress
                            .frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 3)
                    .allowsHitTesting(false)
                }
            }
            // Clips button + overlay together to the same rounded rect the
            // button's border shape uses, so the progress bar's rectangular
            // corners get masked by the button's curve rather than poking out.
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            if item.isPartWatched {
                Button(action: onRestart) {
                    Image(systemName: "arrow.counterclockwise")
                        // Manual foreground: `.borderedProminent` picks white
                        // by default, but on a 70%-lightened tint white has
                        // poor contrast, so use the primary shade instead.
                        .foregroundStyle(Color.dionysusPrimary)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
                .tint(.dionysusPrimaryLight)
                .controlSize(.large)
            }
        }
    }
}
