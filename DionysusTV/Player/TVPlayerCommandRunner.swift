import Foundation

/// The only code that acts on `PlayerViewModel` for a press.
@MainActor
struct TVPlayerCommandRunner {
    let viewModel: PlayerViewModel
    let close: () -> Void
    let playNext: () -> Void

    func run(_ commands: [TVPlayerCommand]) {
        for command in commands {
            switch command {
            case .play: viewModel.play()
            case .pause: viewModel.pause()
            case .togglePlayPause: viewModel.togglePlayPause()
            case .seek(let time): viewModel.seek(to: time)
            case .skipSegment(let id):
                if let segment = viewModel.mediaSegments.first(where: { $0.id == id }) {
                    viewModel.skipSegment(segment)
                }
            case .playNext: playNext()
            case .dismissNextUp: viewModel.dismissNextUp()
            case .selectAudio(let id): viewModel.selectAudioTrack(id: id)
            case .selectSubtitle(let id): viewModel.selectSubtitleTrack(id: id)
            case .close: close()
            }
        }
    }
}
