import Observation

/// Whether the transport is showing. A press shows it for four seconds; the
/// overlay also keeps it up while paused or loading.
@Observable
@MainActor
final class TVTransportChrome {
    private(set) var isVisible = true
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private let visibleDuration: Duration

    init(visibleDuration: Duration = .seconds(4)) {
        self.visibleDuration = visibleDuration
    }

    func poke() {
        isVisible = true
        hideTask?.cancel()
        #if DEBUG
        // A UI test reading the transport can't race its auto-hide.
        if UITestConfiguration.disablesControlAutoHide { return }
        #endif
        hideTask = Task { [weak self, visibleDuration] in
            try? await Task.sleep(for: visibleDuration)
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }

    /// The first fade is timed from playback starting, not from the player
    /// appearing, so a slow load doesn't use up the title's time on screen.
    func playbackStateChanged(from old: PlaybackState, to new: PlaybackState) {
        if old == .loading, new != .loading { poke() }
    }
}
