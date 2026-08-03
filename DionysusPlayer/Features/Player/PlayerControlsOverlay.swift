import SwiftUI

struct PlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    var onClose: () -> Void
    var onShowTracks: () -> Void

    var body: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.title2)
                }

                Spacer()

                if let title = viewModel.item?.name {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onShowTracks) {
                    Image(systemName: "captions.bubble")
                        .font(.title2)
                }
            }
            .foregroundStyle(.white)
            .padding()

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

            VStack(spacing: 4) {
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

                HStack {
                    Text(Self.formatTime(displayedTime))
                    Spacer()
                    if let format = viewModel.videoFormatDescription {
                        Text(format)
                    }
                    Spacer()
                    Text(Self.formatTime(viewModel.duration))
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
