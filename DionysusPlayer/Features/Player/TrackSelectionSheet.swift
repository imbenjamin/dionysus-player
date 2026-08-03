import SwiftUI

/// Audio and subtitle track picker, presented as a sheet from the player.
struct TrackSelectionSheet: View {
    let viewModel: PlayerViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    ForEach(viewModel.audioTracks) { track in
                        trackRow(title: track.displayTitle, isSelected: track.isSelected) {
                            viewModel.selectAudioTrack(id: track.id)
                        }
                    }
                }

                Section("Subtitles") {
                    trackRow(title: "Off", isSelected: !viewModel.subtitleTracks.contains { $0.isSelected }) {
                        viewModel.selectSubtitleTrack(id: nil)
                    }
                    ForEach(viewModel.subtitleTracks) { track in
                        trackRow(title: track.displayTitle, isSelected: track.isSelected) {
                            viewModel.selectSubtitleTrack(id: track.id)
                        }
                    }
                }
            }
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func trackRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isSelected { Image(systemName: "checkmark") }
            }
        }
        .foregroundStyle(.primary)
    }
}
