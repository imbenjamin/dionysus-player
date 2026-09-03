import SwiftUI

/// Small floating preview shown above the scrubber thumb while dragging —
/// a decoded video still at the drag position
/// (`AetherPlaybackEngine.scrubThumbnail(atSeconds:maxWidth:)`, native/
/// AVPlayer route only — see `PlaybackEngine.supportsScrubThumbnails`'s doc
/// comment for why this silently never appears on the software route),
/// plus the drag-position timestamp, so the preview doubles as a magnified
/// read of the exact position a finger is currently covering.
///
/// Mounted conditionally by `PlayerControlsOverlay.scrubberTrack` (an
/// `if isDraggingScrubber { ... }`), unlike `NextUpOverlay`/
/// `PlaybackStatsOverlay`'s "always mounted, opacity-driven" convention —
/// this view only exists during a user-initiated drag, not the continuous
/// ~10Hz playback-clock re-render those two are built to survive, so a
/// plain conditional mount is simpler and sufficient here.
struct ScrubThumbnailPreview: View {
    /// `nil` while the debounced fetch in `scrubberTrack` hasn't resolved
    /// yet for the current drag — shows just the timestamp pill over a
    /// plain dark placeholder rather than nothing, so the bubble doesn't
    /// visibly pop in a beat after the drag itself starts.
    let image: CGImage?
    let timeText: String
    /// The chapter the drag position currently falls in (or has magnetically
    /// snapped to) — prefixed to the timestamp as `"Name · 12:34"` so a
    /// scrub reads as a position in the *story*, not just on a clock. `nil`
    /// for an item with no chapters, which collapses back to the bare
    /// timestamp this pill has always shown.
    var chapterName: String? = nil

    static let width: CGFloat = 160
    private static let height: CGFloat = width * 9 / 16

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                if let image {
                    // Same technique `SubtitleOverlayView.imageCueView(_:position:canvasSize:video:)`
                    // already uses for raw `CGImage` cues — `Image(decorative:)`,
                    // not `UIImage(cgImage:)`.
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)

            // `.monospacedDigit()` only on the timestamp half — applying it
            // to a chapter *name* too would render its letters in the
            // monospaced variant, which reads as a different typeface from
            // every other label in this overlay.
            HStack(spacing: 4) {
                if let chapterName {
                    Text(chapterName)
                        .font(.caption2)
                        .lineLimit(1)
                    Text(verbatim: "\u{00B7}")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(timeText)
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.white)
            // Keeps a long chapter name from widening this pill past the
            // preview image it sits under (which the caller's own clamping
            // math positions against).
            .frame(maxWidth: Self.width)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.6), in: Capsule())
        }
        // Purely visual — the scrubber track underneath already carries
        // its own accessibility element/adjustable action.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        Color.gray
        ScrubThumbnailPreview(image: nil, timeText: "12:34")
    }
}
