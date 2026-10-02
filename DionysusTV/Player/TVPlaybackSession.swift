/// Starts and ends one playback for the player host.
///
/// Holds the start as a task so ending can cancel it: `PlayerViewModel.start()`
/// backs out of a superseded load on cancellation, and without it Menu during
/// loading dismissed the player while the load carried on and played
/// (Review Focus 4). On iOS, `PlayerView`'s `.task` gets that cancellation from
/// SwiftUI; a UIKit host has to do it itself.
@MainActor
final class TVPlaybackSession {
    let viewModel: PlayerViewModel
    private var startTask: Task<Void, Never>?
    private(set) var hasEnded = false

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    /// Starts once; a second call (the host reappearing) does nothing, and so
    /// does a call after `end()` — Menu can arrive while the host is still
    /// being presented, before the `viewDidAppear` that begins.
    func begin() {
        guard startTask == nil, !hasEnded else { return }
        startTask = Task { [viewModel] in await viewModel.start() }
    }

    /// Safe in any state, `.loading` included. Returns where playback
    /// stopped, the first time only: read before `stop()`, which reports the
    /// same position to the server.
    @discardableResult
    func end() -> PlaybackSessionOutcome? {
        guard !hasEnded else { return nil }
        hasEnded = true
        startTask?.cancel()
        let outcome = PlaybackSessionOutcome(
            itemID: viewModel.itemID, positionSeconds: viewModel.currentTime, durationSeconds: viewModel.duration
        )
        Task { [viewModel] in await viewModel.stop() }
        return outcome
    }
}
