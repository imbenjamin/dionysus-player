import Foundation

/// What a `dionysus://play` link asks of its one session beyond what Play
/// does (#406): where to start, which version and tracks, and Playback Stats.
///
/// Applied once, to the session the link started, and never written to track
/// memory or the version preference: the next title in the queue, or the
/// same one played again, plays as it always would. Each part is checked
/// against the title once it has loaded; whatever it doesn't have is left to
/// the usual choice and said in one toast (`notices`), with anything the
/// link said before the player opened.
struct PlaybackLinkOverrides: Hashable, Sendable {
    var start: DeepLink.PlaybackOptions.Start?
    /// The version the link named. The player is asked for it as for any
    /// version; kept here to say so when the title doesn't have it.
    var mediaSourceID: String?
    /// Jellyfin's `MediaStream.Index`, as Playback Stats and the server show it.
    var audioStreamIndex: Int?
    var subtitle: DeepLink.PlaybackOptions.Subtitle?
    var showsStats = false
    /// Said already, before the player opened (a part of the link that
    /// couldn't be read, a title not in the playlist), shown with what the
    /// session finds.
    var notices: [String] = []

    init(
        start: DeepLink.PlaybackOptions.Start? = nil, mediaSourceID: String? = nil,
        audioStreamIndex: Int? = nil, subtitle: DeepLink.PlaybackOptions.Subtitle? = nil,
        showsStats: Bool = false, notices: [String] = []
    ) {
        self.start = start
        self.mediaSourceID = mediaSourceID
        self.audioStreamIndex = audioStreamIndex
        self.subtitle = subtitle
        self.showsStats = showsStats
        self.notices = notices
    }

    /// A link's options, with what it couldn't read said up front.
    init(_ options: DeepLink.PlaybackOptions, issues: [DeepLink.Issue] = []) {
        self.init(
            start: options.start, mediaSourceID: options.mediaSourceID,
            audioStreamIndex: options.audioStreamIndex, subtitle: options.subtitle,
            showsStats: options.showsStats, notices: issues.compactMap(\.playbackNotice)
        )
    }

    /// Whether the link names an audio or subtitle track.
    var choosesTracks: Bool { audioStreamIndex != nil || subtitle != nil }

    /// Nothing to apply or say: plays exactly as Play would.
    var isEmpty: Bool { self == PlaybackLinkOverrides() }

    // MARK: - Resolution

    /// Where the link's start lands, or why it doesn't. `duration` is the
    /// title's runtime when known; without it a time is trusted (the engine
    /// clamps it).
    static func startSeconds(
        for start: DeepLink.PlaybackOptions.Start, chapters: [Chapter], duration: TimeInterval?
    ) -> (seconds: TimeInterval?, notice: String?) {
        switch start {
        case .time(let seconds):
            if let duration, duration > 0, seconds >= duration {
                return (nil, String(localized: "The start time is past the end."))
            }
            return (seconds, nil)
        case .chapter(let number):
            guard chapters.indices.contains(number - 1) else {
                return (nil, String(localized: "This title has no chapter \(number)."))
            }
            return (chapters[number - 1].startSeconds, nil)
        }
    }

    /// The engine's id for the audio stream Jellyfin numbers `index`, if the
    /// engine lists it. Engine ids are container positions, so external
    /// streams before it shift Jellyfin's number (`PlayerViewModel
    /// .physicalIndex(of:in:)`).
    static func audioTrackID(
        forStreamIndex index: Int, mediaStreams: [MediaStream], engineTracks: [PlaybackTrack]
    ) -> Int? {
        guard let stream = mediaStreams.first(where: { $0.type == "Audio" && $0.index == index && $0.isExternal != true })
        else { return nil }
        let id = PlayerViewModel.physicalIndex(of: stream.index, in: mediaStreams)
        return engineTracks.contains { $0.id == id } ? id : nil
    }

    /// The engine's id for the subtitle stream Jellyfin numbers `index`, if
    /// the engine lists it. A stream the player registered as a sidecar
    /// (`sidecars`, in registration order) is the engine's external track in
    /// the same place, as `PlayerViewModel.registeredSidecar` maps them; any
    /// other is a container position, like audio.
    static func subtitleTrackID(
        forStreamIndex index: Int, mediaStreams: [MediaStream], sidecars: [MediaStream], engineTracks: [PlaybackTrack]
    ) -> Int? {
        if let ordinal = sidecars.firstIndex(where: { $0.index == index }) {
            let external = engineTracks.filter(\.isExternal)
            guard external.count == sidecars.count else { return nil }
            return external[ordinal].id
        }
        guard let stream = mediaStreams.first(where: { $0.type == "Subtitle" && $0.index == index && $0.isExternal != true })
        else { return nil }
        let id = PlayerViewModel.physicalIndex(of: stream.index, in: mediaStreams)
        return engineTracks.contains { $0.id == id && !$0.isExternal } ? id : nil
    }

    /// One toast for several notices, in the order they arose.
    static func combined(_ notices: [String]) -> String? {
        notices.isEmpty ? nil : notices.joined(separator: " ")
    }
}

extension DeepLink.Issue {
    /// What a play link says about a part it couldn't read; nil for a part
    /// that isn't about playback.
    var playbackNotice: String? {
        switch self {
        case .unreadableStartTime: String(localized: "Couldn't read the start time.")
        case .unreadableChapter: String(localized: "Couldn't read the chapter.")
        case .unreadableAudio: String(localized: "Couldn't read the audio track.")
        case .unreadableSubtitle: String(localized: "Couldn't read the subtitle track.")
        case .unknownSort, .unknownOrder, .unknownFilter, .unknownSection, .unknownMode, .unreadableBitrate: nil
        }
    }
}
