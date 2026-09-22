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

    // MARK: - Downloaded sidecar mapping

    private func downloadedFile(index: Int, path: String) -> DownloadedSubtitleFile {
        DownloadedSubtitleFile(
            index: index, language: "eng", displayTitle: "Track \(index)",
            isForced: false, isDefault: false, isHearingImpaired: false, relativePath: path
        )
    }

    /// The defect this exists to prevent: a download with several ASS tracks
    /// resolving every one of them to the first file on disk, so picking a
    /// commentary played the SDH script. Real subtitles for the wrong track,
    /// which reads as a bad download rather than a mapping bug.
    func test_downloadedMapping_resolvesEachTrackToItsOwnSidecar() {
        let tracks = [
            engineTrack(id: 10, codec: "ass", isExternal: true),
            engineTrack(id: 11, codec: "ass", isExternal: true),
            engineTrack(id: 12, codec: "ass", isExternal: true)
        ]
        let files = [
            downloadedFile(index: 6, path: "item/subs/6-eng.ass"),
            downloadedFile(index: 7, path: "item/subs/7-eng.ass"),
            downloadedFile(index: 8, path: "item/subs/8-eng.ass")
        ]

        for (track, expected) in zip(tracks, files) {
            XCTAssertEqual(
                PlayerViewModel.registeredSidecar(
                    forTrack: track, engineTracks: tracks, registered: files
                ),
                expected
            )
        }
    }

    /// Engine ids are AetherEngine's own and bear no relation to
    /// `DownloadedSubtitleFile.index`, which is Jellyfin's. A mapping that
    /// matched on the number would find nothing here — or, worse, the wrong
    /// file on a download where the two happened to overlap.
    func test_downloadedMapping_ignoresTheIdsThemselves() {
        let tracks = [
            engineTrack(id: 0, codec: "ass", isExternal: true),
            engineTrack(id: 1, codec: "ass", isExternal: true)
        ]
        let files = [
            downloadedFile(index: 6, path: "item/subs/6-eng.ass"),
            downloadedFile(index: 7, path: "item/subs/7-eng.ass")
        ]

        XCTAssertEqual(
            PlayerViewModel.registeredSidecar(
                forTrack: tracks[1], engineTracks: tracks, registered: files
            )?.index,
            7
        )
    }

    /// A downloaded MP4 can carry subtitle tracks of its own. Counting those
    /// alongside the sidecars shifts the ordinal exactly as a bitmap track
    /// shifts the streaming one.
    func test_downloadedMapping_countsOnlyTheSidecarsThisAppRegistered() {
        let tracks = [
            engineTrack(id: 0, codec: "subrip", isExternal: false),
            engineTrack(id: 10, codec: "ass", isExternal: true),
            engineTrack(id: 11, codec: "ass", isExternal: true)
        ]
        let files = [
            downloadedFile(index: 6, path: "item/subs/6-eng.ass"),
            downloadedFile(index: 7, path: "item/subs/7-eng.ass")
        ]

        XCTAssertEqual(
            PlayerViewModel.registeredSidecar(
                forTrack: tracks[2], engineTracks: tracks, registered: files
            )?.index,
            7
        )
    }

    func test_downloadedMapping_returnsNilForAnEmbeddedTrack() {
        let tracks = [engineTrack(id: 0, codec: "ass", isExternal: false)]
        let files = [downloadedFile(index: 6, path: "item/subs/6-eng.ass")]

        XCTAssertNil(
            PlayerViewModel.registeredSidecar(
                forTrack: tracks[0], engineTracks: tracks, registered: files
            )
        )
    }

    /// Rather than serving an ordinal that has slid. A sidecar the engine
    /// failed to register would shift every file after it by one, which is the
    /// difference between showing no script and confidently showing the wrong
    /// one.
    func test_downloadedMapping_returnsNilWhenTheTwoSidesDisagreeOnCount() {
        let tracks = [
            engineTrack(id: 10, codec: "ass", isExternal: true),
            engineTrack(id: 11, codec: "ass", isExternal: true)
        ]
        let files = [downloadedFile(index: 6, path: "item/subs/6-eng.ass")]

        XCTAssertNil(
            PlayerViewModel.registeredSidecar(
                forTrack: tracks[1], engineTracks: tracks, registered: files
            )
        )
    }

    // MARK: - Which streams become sidecars

    private func subtitleStream(
        index: Int, codec: String, isExternal: Bool?, deliveryMethod: String?
    ) -> MediaStream {
        var stream = MediaStream(index: index, type: "Subtitle")
        stream.codec = codec
        stream.isExternal = isExternal
        stream.deliveryMethod = deliveryMethod
        return stream
    }

    /// The defect: on a server-side transcode the app plays the server's HLS
    /// through AVPlayer, which carries no subtitle rendition for the
    /// container's own tracks, so nothing demuxed them and nothing registered
    /// them — every embedded SubRip and ASS track vanished from the picker.
    /// Jellyfin had been saying `deliveryMethod: "External"` for exactly those
    /// streams all along; the app filtered on `isExternal` instead, which is a
    /// different question.
    func test_sidecarStreams_transcodeIncludesTheContainersOwnTextTracks() {
        let streams = [
            subtitleStream(index: 0, codec: "subrip", isExternal: true, deliveryMethod: "External"),
            subtitleStream(index: 6, codec: "ass", isExternal: false, deliveryMethod: "External"),
            subtitleStream(index: 7, codec: "ass", isExternal: false, deliveryMethod: "External"),
            // Burned into the video by the server, so there is nothing to fetch.
            subtitleStream(index: 9, codec: "PGSSUB", isExternal: false, deliveryMethod: "Encode")
        ]

        XCTAssertEqual(
            PlayerViewModel.externalSubtitleStreams(from: streams, isRemoteHLS: true).map(\.index),
            [0, 6, 7]
        )
    }

    /// The route gate is load-bearing. Direct play reports the same
    /// `"External"` for the same embedded streams, but there AetherEngine has
    /// demuxed the container and lists them already — registering sidecars too
    /// would show every track in the picker twice.
    func test_sidecarStreams_directPlayTakesOnlyTheGenuinelyExternalOnes() {
        let streams = [
            subtitleStream(index: 0, codec: "subrip", isExternal: true, deliveryMethod: "External"),
            subtitleStream(index: 6, codec: "ass", isExternal: false, deliveryMethod: "External"),
            subtitleStream(index: 9, codec: "PGSSUB", isExternal: false, deliveryMethod: "Embed")
        ]

        XCTAssertEqual(
            PlayerViewModel.externalSubtitleStreams(from: streams, isRemoteHLS: false).map(\.index),
            [0]
        )
    }

    /// Direct Play Always sends no `DeviceProfile`, so the server has no route
    /// to describe and reports no delivery method at all. The genuinely
    /// external sidecars must still be registered.
    func test_sidecarStreams_absentDeliveryMethodStillRegistersRealSidecars() {
        let streams = [
            subtitleStream(index: 0, codec: "subrip", isExternal: true, deliveryMethod: nil),
            subtitleStream(index: 6, codec: "ass", isExternal: false, deliveryMethod: nil)
        ]

        for isRemoteHLS in [true, false] {
            XCTAssertEqual(
                PlayerViewModel.externalSubtitleStreams(from: streams, isRemoteHLS: isRemoteHLS).map(\.index),
                [0],
                "isRemoteHLS \(isRemoteHLS)"
            )
        }
    }

    /// Audio and video streams carry delivery methods of their own in some
    /// responses; only subtitles belong in a subtitle sidecar list.
    func test_sidecarStreams_ignoresNonSubtitleStreams() {
        var video = MediaStream(index: 0, type: "Video")
        video.deliveryMethod = "External"
        var audio = MediaStream(index: 1, type: "Audio")
        audio.isExternal = true
        let streams = [video, audio, subtitleStream(index: 2, codec: "ass", isExternal: false, deliveryMethod: "External")]

        XCTAssertEqual(
            PlayerViewModel.externalSubtitleStreams(from: streams, isRemoteHLS: true).map(\.index),
            [2]
        )
    }

    // MARK: - Which fonts render the script

    private func font(_ name: String) -> ASSFontAttachment {
        ASSFontAttachment(filename: name, data: Data(name.utf8))
    }

    /// The common path: a direct-played container is demuxed locally, so
    /// AetherEngine already holds every face the script names and nothing has
    /// to be fetched at all.
    func test_assFonts_prefersTheEnginesOwnAttachments() {
        let engine = [font("Agenda.ttf")]
        let fetched = [font("Sublime Regular.ttf")]
        XCTAssertEqual(PlayerViewModel.assFonts(engineAttachments: engine, fetched: fetched), engine)
    }

    /// The routes this exists for — a server-side transcode and offline
    /// playback — never demux the original container, so the engine reports
    /// nothing and the fetched set is the whole answer.
    func test_assFonts_fallsBackWhenTheEngineHasNone() {
        let fetched = [font("Sublime Regular.ttf")]
        XCTAssertEqual(PlayerViewModel.assFonts(engineAttachments: [], fetched: fetched), fetched)
    }

    /// Deliberately not a union. On a direct play the two lists are the same
    /// faces read out of the same container, so merging would register every
    /// one of them twice for no gain — and a container that carries fonts never
    /// probes to an empty list, so there is no "engine has some, server has the
    /// rest" case to serve.
    func test_assFonts_neverMergesTheTwoSources() {
        let engine = [font("Agenda.ttf")]
        let fetched = [font("Agenda.ttf"), font("Other.ttf")]
        XCTAssertEqual(PlayerViewModel.assFonts(engineAttachments: engine, fetched: fetched), engine)
    }

    /// No fonts anywhere is not a failure: libass renders the script in a
    /// system face, which is how every authored track behaved before any of
    /// this existed.
    func test_assFonts_emptyWhenNeitherSideHasAny() {
        XCTAssertTrue(PlayerViewModel.assFonts(engineAttachments: [], fetched: []).isEmpty)
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
