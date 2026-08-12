import SwiftUI

struct PlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    var onClose: () -> Void
    var onShowTracks: () -> Void

    /// Whether the scrubber's trailing timestamp reads as the asset's total
    /// duration (the default) or a `-`-prefixed countdown to the end —
    /// flipped by tapping that timestamp. Local `@State`: nothing outside
    /// this overlay needs to know which mode is showing.
    @State private var showRemainingTime = false

    var body: some View {
        VStack {
            HStack {
                // A proper close button, not a minimize/collapse affordance —
                // `onClose` always stops playback and reports a resume point
                // to the server (`PlayerViewModel.stop()`), it never leaves
                // the session running in the background, so the icon should
                // read as "exit playback" rather than "tuck this away".
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title2)
                }

                Spacer()

                Button(action: onShowTracks) {
                    Image(systemName: "captions.bubble")
                        .font(.title2)
                }
            }
            .foregroundStyle(.white)
            .padding()

            titleRow

            Spacer()

            HStack(spacing: 40) {
                Button {
                    viewModel.seek(to: max(0, displayedTime - 15))
                } label: {
                    Image(systemName: "gobackward.15").font(.title)
                }

                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 44))
                }

                Button {
                    viewModel.seek(to: min(viewModel.duration, displayedTime + 30))
                } label: {
                    Image(systemName: "goforward.30").font(.title)
                }
            }
            .foregroundStyle(.white)

            Spacer()

            scrubberBar
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Logo preferred, pinned top-left — the same "logo over text-title
    /// fallback" convention `BackdropLogoOverlay` uses on the detail pages.
    /// Falls back to the plain title text when the item has no logo image at
    /// all, or when `LogoImageView` fails to load the one it has (a 404, a
    /// timeout after retries — see that type's doc comment).
    @ViewBuilder
    private var titleRow: some View {
        if let item = viewModel.item {
            HStack {
                if let logoURL = item.logoImageURL {
                    LogoImageView(url: logoURL, fallback: titleText(item))
                        .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
                } else {
                    titleText(item)
                }
                Spacer()
            }
            .padding(.horizontal)
        }
    }

    private func titleText(_ item: MediaItem) -> some View {
        Text(item.name)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    /// Progress slider with its timestamps at either end, rather than on
    /// their own row below it. The trailing timestamp doubles as a button —
    /// see `showRemainingTime`.
    private var scrubberBar: some View {
        VStack(spacing: 4) {
            if let format = viewModel.videoFormatDescription {
                Text(format)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack(spacing: 8) {
                Text(Self.formatTime(displayedTime))
                    .monospacedDigit()

                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(viewModel.duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { viewModel.seek(to: scrubTime) }
                    }
                )
                .tint(.white)

                Button {
                    showRemainingTime.toggle()
                } label: {
                    Text(endTimeText)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding()
    }

    /// The scrubber's trailing timestamp — the asset's total duration by
    /// default, or a countdown to the end once `showRemainingTime` is
    /// toggled on. Reads off `displayedTime` (the scrub-in-progress position
    /// while dragging, otherwise live playback position — see
    /// `displayedTime`), so the countdown keeps counting down as the user
    /// scrubs, not just during normal playback.
    private var endTimeText: String {
        guard showRemainingTime else { return Self.formatTime(viewModel.duration) }
        return "-" + Self.formatTime(max(0, viewModel.duration - displayedTime))
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : viewModel.currentTime
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
