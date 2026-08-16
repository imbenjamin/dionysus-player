import SwiftUI

/// Covers the video surface while this session's picture is showing in a
/// system PiP window instead — see `PlaybackEngine
/// .onPictureInPictureActiveChange`'s doc comment for why the surface itself
/// stays mounted underneath rather than being swapped out (the AVPlayerLayer
/// it wraps has to keep rendering for PiP to keep working).
///
/// Always mounted by `PlayerView`, with `isVisible` driving `.opacity` —
/// same reasoning as `PlaybackStatsOverlay`'s own doc comment on why a
/// conditionally-inserted/removed sibling here would force a relayout of the
/// whole `ZStack`, the video surface included. Sits above
/// `PlayerControlsOverlay` in that stack: nothing under it is interactive
/// while the video isn't visible in the app's own window, so it also
/// deliberately doesn't fade with `showControls`.
struct PictureInPictureOverlay: View {
    let isVisible: Bool

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 12) {
                Image(systemName: "pip.fill")
                    .font(.system(size: 44))
                Text("Playing in Picture in Picture")
                    .font(.headline)
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .accessibilityElement(children: .combine)
    }
}
