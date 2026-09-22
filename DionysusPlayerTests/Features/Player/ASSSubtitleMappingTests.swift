import XCTest
@testable import Dionysus

/// Pins the two pure decisions behind authored-ASS rendering: which subtitle
/// tracks go to libass at all, and which Jellyfin `MediaStream` a given engine
/// track came from.
///
/// The mapping is the fragile half. AetherEngine numbers an embedded track by
/// its `AVStream` index and Jellyfin numbers the same track by its own
/// `MediaStream.index`; the two disagree in practice (engine id 2 against
/// Jellyfin index 3 on one file, id 5 against index 6 on another), so the app
/// pairs them by ordinal among embedded ASS tracks. That holds only while both
/// sides are filtered identically, which is what most of these cover — an
/// unfiltered count shifts the ordinal and silently fetches the wrong track's
/// script, which looks like a subtitle-timing bug rather than a mapping one.
@MainActor
final class ASSSubtitleMappingTests: XCTestCase {

    // MARK: - Codec predicate

    func test_isAuthoredASS_acceptsASSAndSSA() {
        XCTAssertTrue(PlayerViewModel.isAuthoredASS("ass"))
        XCTAssertTrue(PlayerViewModel.isAuthoredASS("ssa"))
    }

    /// Case folded: `MediaStream.codec` is lower-case from Jellyfin but
    /// `DisplayTitle` and some containers upper-case it.
    func test_isAuthoredASS_isCaseInsensitive() {
        XCTAssertTrue(PlayerViewModel.isAuthoredASS("ASS"))
        XCTAssertTrue(PlayerViewModel.isAuthoredASS("Ssa"))
    }

    /// Everything else keeps rendering through `SubtitleOverlayView`'s own path
    /// on AetherEngine's cues. Getting this wrong doesn't degrade styling — it
    /// sends a track to libass that has no ASS script to fetch.
    func test_isAuthoredASS_rejectsEveryOtherSubtitleCodec() {
        for codec in ["subrip", "webvtt", "mov_text", "pgssub", "dvdsub", "dvbsub", "", "assx", "sub"] {
            XCTAssertFalse(PlayerViewModel.isAuthoredASS(codec), "expected \(codec) to be rejected")
        }
        XCTAssertFalse(PlayerViewModel.isAuthoredASS(nil))
    }

    /// A downloaded sidecar records no codec, so the file extension stands in —
    /// `DownloadManager` names it via `JellyfinAPIClient.subtitleFileExtension`.
    func test_isAuthoredASSPath_readsTheExtension() {
        XCTAssertTrue(PlayerViewModel.isAuthoredASSPath("subs/movie.ass"))
        XCTAssertTrue(PlayerViewModel.isAuthoredASSPath("subs/movie.SSA"))
        XCTAssertFalse(PlayerViewModel.isAuthoredASSPath("subs/movie.srt"))
        XCTAssertFalse(PlayerViewModel.isAuthoredASSPath("subs/movie"))
    }

    // MARK: - The styling setting

    /// **Styling is on unless the user turned it off.** An unset key must read
    /// as enabled: `UserDefaults.bool(forKey:)` reports `false` for a key that
    /// was never written, so reading it directly would ship the feature off for
    /// everyone who never opened Settings.
    func test_isStyledASSEnabled_defaultsToOnWhenNeverSet() {
        XCTAssertTrue(PlayerViewModel.isStyledASSEnabled(emptyDefaults()))
    }

    /// And the declared default itself is on — asserted separately from the
    /// unset-key behaviour above, since the two could drift apart.
    func test_styledASSSubtitlesEnabledDefault_isOn() {
        XCTAssertTrue(styledASSSubtitlesEnabledDefault)
    }

    func test_isStyledASSEnabled_honoursAnExplicitFalse() {
        let defaults = emptyDefaults()
        defaults.set(false, forKey: styledASSSubtitlesEnabledStorageKey)
        XCTAssertFalse(PlayerViewModel.isStyledASSEnabled(defaults))
    }

    func test_isStyledASSEnabled_honoursAnExplicitTrue() {
        let defaults = emptyDefaults()
        defaults.set(true, forKey: styledASSSubtitlesEnabledStorageKey)
        XCTAssertTrue(PlayerViewModel.isStyledASSEnabled(defaults))
    }

    /// The setting gates the renderer, not the codec predicate — the mapping
    /// below stays truthful about what a track *is* either way. Turning
    /// styling off makes an ASS track render through the app's own cue path,
    /// which is a decision `handleSubtitleTrackChange` makes from both answers
    /// together; conflating them here would make "is this ASS?" mean two
    /// different things in two different places.
    func test_theSettingDoesNotChangeWhatCountsAsAuthoredASS() {
        let defaults = emptyDefaults()
        defaults.set(false, forKey: styledASSSubtitlesEnabledStorageKey)
        XCTAssertFalse(PlayerViewModel.isStyledASSEnabled(defaults))
        XCTAssertTrue(PlayerViewModel.isAuthoredASS("ass"))
    }

    // MARK: - Track → stream mapping

    /// The case measured live: the engine's id and Jellyfin's index differ, and
    /// pairing by id rather than ordinal would miss entirely.
    func test_mapping_pairsByOrdinalNotByID() {
        let tracks = [engineTrack(id: 2, codec: "ass")]
        let streams = [stream(index: 3, codec: "ass")]

        let resolved = PlayerViewModel.jellyfinStream(
            forTrack: tracks[0], engineTracks: tracks, mediaStreams: streams
        )

        XCTAssertEqual(resolved?.index, 3)
    }

    func test_mapping_resolvesEachOfSeveralASSTracks() {
        let tracks = [engineTrack(id: 5, codec: "ass"), engineTrack(id: 6, codec: "ass")]
        let streams = [stream(index: 5, codec: "ass"), stream(index: 6, codec: "ass")]

        XCTAssertEqual(
            PlayerViewModel.jellyfinStream(forTrack: tracks[0], engineTracks: tracks, mediaStreams: streams)?.index, 5
        )
        XCTAssertEqual(
            PlayerViewModel.jellyfinStream(forTrack: tracks[1], engineTracks: tracks, mediaStreams: streams)?.index, 6
        )
    }

    /// The real shape of a retail remux: ASS tracks interleaved with PGS ones.
    /// Counting subtitle streams rather than ASS streams would resolve the
    /// second ASS track to the PGS stream sitting between them.
    func test_mapping_ignoresBitmapStreamsWhenCountingOrdinals() {
        let tracks = [engineTrack(id: 6, codec: "ass"), engineTrack(id: 8, codec: "ass")]
        let streams = [
            stream(index: 6, codec: "ass"),
            stream(index: 7, codec: "pgssub"),
            stream(index: 8, codec: "ass")
        ]

        XCTAssertEqual(
            PlayerViewModel.jellyfinStream(forTrack: tracks[1], engineTracks: tracks, mediaStreams: streams)?.index, 8
        )
    }

    /// External sidecars are registered by this app from these very streams and
    /// need no mapping; counting them would shift every embedded ordinal.
    func test_mapping_ignoresExternalTracksAndStreams() {
        let tracks = [
            engineTrack(id: 100, codec: "subrip", isExternal: true),
            engineTrack(id: 2, codec: "ass")
        ]
        let streams = [
            stream(index: 0, codec: "subrip", isExternal: true),
            stream(index: 3, codec: "ass")
        ]

        XCTAssertEqual(
            PlayerViewModel.jellyfinStream(forTrack: tracks[1], engineTracks: tracks, mediaStreams: streams)?.index, 3
        )
    }

    /// Audio and video streams share the `MediaStream` list and are numbered in
    /// the same sequence, so the filter has to be on type as well as codec.
    func test_mapping_ignoresNonSubtitleStreams() {
        let tracks = [engineTrack(id: 4, codec: "ass")]
        let streams = [
            stream(index: 0, type: "Video", codec: "hevc"),
            stream(index: 1, type: "Audio", codec: "eac3"),
            stream(index: 4, codec: "ass")
        ]

        XCTAssertEqual(
            PlayerViewModel.jellyfinStream(forTrack: tracks[0], engineTracks: tracks, mediaStreams: streams)?.index, 4
        )
    }

    func test_mapping_returnsNilForANonASSTrack() {
        let tracks = [engineTrack(id: 1, codec: "subrip")]
        let streams = [stream(index: 1, codec: "subrip")]

        XCTAssertNil(
            PlayerViewModel.jellyfinStream(forTrack: tracks[0], engineTracks: tracks, mediaStreams: streams)
        )
    }

    /// Rather than guessing at a stream that may not be the right one. Happens
    /// when the two sides genuinely disagree — a container the server probed
    /// differently from the engine.
    func test_mapping_returnsNilWhenJellyfinReportsFewerASSStreams() {
        let tracks = [engineTrack(id: 2, codec: "ass"), engineTrack(id: 3, codec: "ass")]
        let streams = [stream(index: 3, codec: "ass")]

        XCTAssertNil(
            PlayerViewModel.jellyfinStream(forTrack: tracks[1], engineTracks: tracks, mediaStreams: streams)
        )
    }

    func test_mapping_returnsNilWhenJellyfinReportsNoStreams() {
        let tracks = [engineTrack(id: 2, codec: "ass")]

        XCTAssertNil(
            PlayerViewModel.jellyfinStream(forTrack: tracks[0], engineTracks: tracks, mediaStreams: [])
        )
    }

    // MARK: - Helpers

    /// A throwaway suite, so these never touch the shared domain a parallel
    /// test or the Simulator's own state could be reading.
    private func emptyDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private func engineTrack(id: Int, codec: String, isExternal: Bool = false) -> PlaybackTrack {
        PlaybackTrack(
            id: id, kind: .subtitle, title: "Track \(id)", metadata: nil,
            isSelected: false, codec: codec, isExternal: isExternal
        )
    }

    private func stream(
        index: Int, type: String = "Subtitle", codec: String, isExternal: Bool = false
    ) -> MediaStream {
        MediaStream(index: index, type: type, codec: codec, isExternal: isExternal)
    }
}
