import Foundation

extension TVPlayerContext {
    /// A snapshot of the player and the settings, taken on every input.
    @MainActor
    init(viewModel: PlayerViewModel, defaults: UserDefaults = .standard) {
        self.init()
        playback = Self.playback(viewModel.state)
        currentTime = viewModel.currentTime
        duration = viewModel.duration
        chapterStarts = viewModel.chapters.map(\.startSeconds)
        let audio = viewModel.audioTracks
        audioTrackIDs = audio.map(\.id)
        selectedAudioIndex = audio.firstIndex(where: \.isSelected)
        let subtitles = viewModel.subtitleTracks
        subtitleTrackIDs = subtitles.map(\.id)
        selectedSubtitleIndex = subtitles.firstIndex(where: \.isSelected)
        statsButtonEnabled = Self.flag(showPlaybackStatsButtonEnabledStorageKey, default: showPlaybackStatsButtonEnabledDefault, in: defaults)
        chaptersInScrubber = Self.flag(chaptersInScrubberEnabledStorageKey, default: chaptersInScrubberEnabledDefault, in: defaults)
        skipSegment = viewModel.currentSkipSegment.map { SkipSegment(id: $0.id, endSeconds: $0.endSeconds) }
        nextUpSecondsRemaining = viewModel.nextUpSecondsRemaining
        closesWhenPlaybackEnds = viewModel.closesWhenPlaybackEnds
        #if DEBUG
        autoHideDisabled = UITestConfiguration.disablesControlAutoHide
        #endif
    }

    /// `object(forKey:)` before `bool(forKey:)`, as
    /// `PlayerViewModel.isStyledASSEnabled` does: `bool` reads an unwritten
    /// key as `false`, and a launch argument ("-key YES") arrives as a
    /// string that only `bool` understands.
    static func flag(_ key: String, default fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    static func playback(_ state: PlaybackState) -> Playback {
        switch state {
        case .idle, .loading: .loading
        case .playing, .seeking, .buffering, .reconnecting: .playing
        case .paused: .paused
        case .ended: .ended
        case .failed: .failed
        }
    }
}
