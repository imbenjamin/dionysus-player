import SwiftUI

/// The in-player "Skip Intro"/"Skip Recap"/"Skip Preview"/"Skip Commercial"/
/// "Skip Credits" button — a bottom-trailing pill shown while `currentTime`
/// is inside a `PlaybackSegment`, per `PlayerViewModel.currentSkipSegment`.
/// Tapping it swaps the same slot to a small spinner (`isBuffering`) rather
/// than reverting to the main transport chrome's own buffering treatment —
/// see `PlayerView.isSkipBuffering`'s doc comment for why a segment skip is
/// deliberately kept from revealing that chrome at all.
///
/// Mounted in the same bottom-trailing slot `NextUpOverlay` occupies, with
/// the identical "always mounted, `isVisible` drives `.opacity`/
/// `.allowsHitTesting`, not gated by `showControls`" treatment that view
/// documents — same reasoning applies verbatim here: this reads
/// `viewModel.currentTime` too, so a mount/unmount toggle would fight the
/// same ~10Hz time-update re-renders, and a skip button (and the spinner
/// that follows it) are meant to be available whether the rest of the
/// transport chrome is faded in or out. The two overlays are mutually
/// exclusive by construction — `currentSkipSegment` suppresses the
/// end-credits segment specifically whenever `NextUpOverlay` is covering
/// that window instead — so sharing a slot never means picking a winner
/// between two visible cards.
struct SkipSegmentOverlay: View {
    let segment: PlaybackSegment?
    let isBuffering: Bool
    let onSkip: (PlaybackSegment) -> Void

    private var isVisible: Bool { segment != nil || isBuffering }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                content
                    .padding(.trailing, 20)
                    // Same bottom clearance as `NextUpOverlay`'s card — see
                    // that view's own doc comment on why it needs to clear
                    // the transport row.
                    .padding(.bottom, 110)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
    }

    @ViewBuilder
    private var content: some View {
        if isBuffering {
            // Same visual language as `PlayerControlsOverlay`'s own
            // buffering spinner, shrunk to fit this slot's pill footprint —
            // shown "if necessary" only (`PlayerView.isSkipBuffering`
            // requires the engine to actually be mid-seek/-buffer right
            // now), not for the whole `isSkippingSegment` suppression
            // window unconditionally.
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .frame(width: 20, height: 20)
                .padding(14)
                .background(Color.black.opacity(0.55), in: Circle())
        } else if let segment {
            Button {
                onSkip(segment)
            } label: {
                Text(segment.kind.skipButtonTitle)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
    }
}
