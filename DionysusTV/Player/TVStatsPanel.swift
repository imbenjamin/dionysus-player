import SwiftUI

/// The playback stats panel on the Apple TV: one glass page top-right, every
/// row of iOS's three pages (`PlaybackStatsReport`), refreshed twice a second.
/// A toggle on its icon; it takes no presses (Benjamin, 2026-10-06).
struct TVStatsPanel: View {
    let viewModel: PlayerViewModel

    @State private var stats: PlaybackStats?
    @State private var readings = PlaybackStatsReport.DeviceReadings()

    private static let pollInterval: Duration = .milliseconds(500)
    /// `/Sessions` is a network round-trip; every 5s is plenty.
    private static let streamingPollTicks = 10

    var body: some View {
        Group {
            if let stats {
                HStack(alignment: .top, spacing: 36) {
                    column([
                        PlaybackStatsReport.video(stats, sourceVideoStream: viewModel.sourceVideoStream),
                        PlaybackStatsReport.audio(stats, sourceAudioStream: viewModel.sourceAudioStream, readings: readings)
                    ])
                    column([
                        PlaybackStatsReport.playback(stats, state: viewModel.state, zoomMode: nil),
                        PlaybackStatsReport.display(stats, readings: readings),
                        PlaybackStatsReport.streaming(isOffline: false, serverVersion: viewModel.serverVersion, session: viewModel.streamingSession),
                        PlaybackStatsReport.build()
                    ])
                }
            } else {
                Text("Gathering stats…").font(.callout)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.TV.Player.statsPanel)
        .task { await poll() }
    }

    private func column(_ sections: [PlaybackStatsReport.Section]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Text(section.title)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.top, index == 0 ? 0 : 10)
                ForEach(section.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 190, alignment: .leading)
                        Text(row.value)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                    }
                    .font(.system(size: 18))
                    // One element per row, read "EDR Headroom, 1.00x": a value
                    // alone ("1.00x") isn't human-readable, which the
                    // accessibility audit fails.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.label)
                    .accessibilityValue(row.value)
                    .accessibilityIdentifier(A11yID.TV.Player.statsValue(row.id))
                }
            }
        }
        // Sized so the panel clears the icon row with every row showing,
        // a transcode's included, and stays right of the title block (460pt
        // from x 80).
        .frame(width: 470, alignment: .leading)
    }

    private func poll() async {
        var tick = 0
        while !Task.isCancelled {
            stats = viewModel.stats
            readings = .current()
            if tick % Self.streamingPollTicks == 0 {
                await viewModel.refreshServerVersion()
                await viewModel.refreshStreamingSession()
            }
            tick += 1
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
