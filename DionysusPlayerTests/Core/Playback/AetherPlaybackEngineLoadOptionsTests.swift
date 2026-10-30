import AVFoundation
import XCTest
import AetherEngine
@testable import Dionysus

final class AetherPlaybackEngineLoadOptionsTests: XCTestCase {
    /// tvOS's Match Content setting and the panel's live HDR state reach the
    /// engine, as AetherEngine's "Host setup on tvOS" and Sodalite pass them.
    func test_displayContext_isPassedThrough() {
        let options = AetherPlaybackEngine.makeLoadOptions(
            isRemoteHLS: false, externalSubtitles: [],
            display: DisplayContext(matchContentEnabled: false, panelIsInHDRMode: true)
        )
        XCTAssertFalse(options.matchContentEnabled)
        XCTAssertTrue(options.panelIsInHDRMode)
        XCTAssertFalse(options.suppressDisplayCriteria, "The engine must stay the only criteria writer")
    }

    /// With no window to ask (Review Focus 2), the engine's own defaults apply:
    /// matching assumed on, panel state unproven.
    func test_unknownDisplay_keepsEngineDefaults() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: false, externalSubtitles: [], display: .unknown)
        XCTAssertTrue(options.matchContentEnabled)
        XCTAssertFalse(options.panelIsInHDRMode)
        XCTAssertTrue(options.attemptsHDRMasterOnUnprovenPanel)
    }

    /// The iOS behaviour is unchanged: the same remote-HLS and subtitle flags as before.
    func test_existingFlags_unchanged() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: true, externalSubtitles: [], display: .unknown)
        XCTAssertTrue(options.nativeRemoteHLS)
        XCTAssertTrue(options.prepareNativeSubtitles)
        XCTAssertFalse(options.isLive)
    }
    /// A direct-play remux has one fixed bitrate, so the read-ahead is its
    /// only cushion: five minutes by default (75 of the engine's ~4 s
    /// segments), not the engine's ~40 s (Benjamin, 2026-10-21).
    func test_forwardBuffer_defaultsToFiveMinutes() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: false, externalSubtitles: [], display: .unknown)
        XCTAssertEqual(options.forwardBufferSegments, 75)
    }

    /// The Read-Ahead Buffer setting reaches the engine.
    func test_forwardBuffer_followsTheSetting() {
        let options = AetherPlaybackEngine.makeLoadOptions(
            isRemoteHLS: false, externalSubtitles: [], display: .unknown, readAheadSeconds: 30
        )
        XCTAssertEqual(options.forwardBufferSegments, 8)
    }

    // MARK: Spatial Audio

    func test_spatialAudio_defaultsToOff() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: false, externalSubtitles: [], display: .unknown)
        XCTAssertEqual(options.objectAudioRendering, .off)
    }

    /// `.render`, not `.apac`: the bed goes out as lossless PCM, and
    /// AetherEngine falls back to APAC by itself where AirPlay is in the route.
    func test_spatialAudio_layout714_rendersForTheRoute() {
        let options = AetherPlaybackEngine.makeLoadOptions(
            isRemoteHLS: false, externalSubtitles: [], display: .unknown, spatialAudio: .layout(.l714)
        )
        XCTAssertEqual(options.objectAudioRendering, .render(.l714))
    }

    // MARK: Spatial Audio across an AirPlay route change

    func test_routeIsAirPlay_onlyWithAnAirPlayPort() {
        XCTAssertTrue(AetherPlaybackEngine.routeIsAirPlay([.airPlay]))
        XCTAssertTrue(AetherPlaybackEngine.routeIsAirPlay([.HDMI, .airPlay]))
        XCTAssertFalse(AetherPlaybackEngine.routeIsAirPlay([.HDMI]))
        XCTAssertFalse(AetherPlaybackEngine.routeIsAirPlay([.bluetoothA2DP]))
        XCTAssertFalse(AetherPlaybackEngine.routeIsAirPlay([]))
    }

    /// Speakers or HDMI to a HomePod mid-film: the PCM bed chosen at load
    /// would reach AirPlay as stereo, so the session is rebuilt as APAC.
    func test_bedRebuild_whenTheRouteGainsAirPlay() {
        XCTAssertTrue(AetherPlaybackEngine.spatialBedNeedsRebuild(
            rendering: .layout(.l714),
            chosenFor: .init(isAirPlay: false, isExternalPlayback: false),
            now: .init(isAirPlay: true, isExternalPlayback: false)
        ))
    }

    /// And back: APAC chosen for AirPlay goes back to lossless PCM.
    func test_bedRebuild_whenTheRouteLosesAirPlay() {
        XCTAssertTrue(AetherPlaybackEngine.spatialBedNeedsRebuild(
            rendering: .layout(.l714),
            chosenFor: .init(isAirPlay: true, isExternalPlayback: false),
            now: .init(isAirPlay: false, isExternalPlayback: false)
        ))
    }

    func test_noBedRebuild_whileTheRouteKeepsItsKind() {
        XCTAssertFalse(AetherPlaybackEngine.spatialBedNeedsRebuild(
            rendering: .layout(.l714),
            chosenFor: .init(isAirPlay: false, isExternalPlayback: false),
            now: .init(isAirPlay: false, isExternalPlayback: false)
        ))
        XCTAssertFalse(AetherPlaybackEngine.spatialBedNeedsRebuild(
            rendering: .layout(.l714),
            chosenFor: .init(isAirPlay: true, isExternalPlayback: false),
            now: .init(isAirPlay: true, isExternalPlayback: false)
        ))
    }

    /// Nothing is rendered, so there's no bed to re-choose.
    func test_noBedRebuild_withSpatialAudioOff() {
        XCTAssertFalse(AetherPlaybackEngine.spatialBedNeedsRebuild(
            rendering: .off,
            chosenFor: .init(isAirPlay: false, isExternalPlayback: false),
            now: .init(isAirPlay: true, isExternalPlayback: false)
        ))
    }

    /// No session has chosen a bed yet (or it has stopped).
    func test_noBedRebuild_beforeALoad() {
        XCTAssertFalse(AetherPlaybackEngine.spatialBedNeedsRebuild(
            rendering: .layout(.l714),
            chosenFor: nil,
            now: .init(isAirPlay: true, isExternalPlayback: false)
        ))
    }

    /// AirPlaying the video to a TV, either way: AetherEngine reloads the
    /// session itself on that edge, which re-chooses the bed. A second reload
    /// from here would race it.
    func test_noBedRebuild_acrossAnExternalPlaybackEdge() {
        XCTAssertFalse(AetherPlaybackEngine.spatialBedNeedsRebuild(
            rendering: .layout(.l714),
            chosenFor: .init(isAirPlay: false, isExternalPlayback: false),
            now: .init(isAirPlay: true, isExternalPlayback: true)
        ))
        XCTAssertFalse(AetherPlaybackEngine.spatialBedNeedsRebuild(
            rendering: .layout(.l714),
            chosenFor: .init(isAirPlay: true, isExternalPlayback: true),
            now: .init(isAirPlay: false, isExternalPlayback: false)
        ))
    }

    /// Every app layout names one of the engine's, by the same raw value.
    func test_everySpeakerLayout_mapsToTheEngines() {
        for layout in SpeakerLayout.allCases {
            XCTAssertEqual(AetherPlaybackEngine.engineLayout(layout).rawValue, layout.rawValue)
        }
    }

    func test_spatialAudioStats_atmos_countsObjects() {
        let activity = ObjectAudioActivity(layout: .l714, objects: 15, activeObjects: 13, elevatedObjects: 4, heightChannels: 0)
        XCTAssertEqual(AetherPlaybackEngine.describeObjectAudio(activity), "7.1.4 · 13 objects, 4 overhead")
    }

    /// DTS:X plays its standard presentation: heights, no objects.
    func test_spatialAudioStats_dtsX_countsHeights() {
        let activity = ObjectAudioActivity(layout: .l916, objects: 0, activeObjects: 0, elevatedObjects: 0, heightChannels: 4)
        XCTAssertEqual(AetherPlaybackEngine.describeObjectAudio(activity), "9.1.6 · 4 height channels")
    }

    /// One of each reads in the singular (the String Catalog's plural variants).
    func test_spatialAudioStats_singularCounts() {
        let object = ObjectAudioActivity(layout: .l714, objects: 1, activeObjects: 1, elevatedObjects: 1, heightChannels: 0)
        XCTAssertEqual(AetherPlaybackEngine.describeObjectAudio(object), "7.1.4 · 1 object, 1 overhead")
        let height = ObjectAudioActivity(layout: .l916, objects: 0, activeObjects: 0, elevatedObjects: 0, heightChannels: 1)
        XCTAssertEqual(AetherPlaybackEngine.describeObjectAudio(height), "9.1.6 · 1 height channel")
    }

    func test_audioOffset_isPassedAsAudioDelaySeconds() {
        let options = AetherPlaybackEngine.makeLoadOptions(
            isRemoteHLS: false, externalSubtitles: [], display: .unknown, audioOffset: 0.04
        )
        XCTAssertEqual(options.audioDelaySeconds, 0.04, accuracy: 0.0001)
    }

    func test_audioOffset_defaultsToZero() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: false, externalSubtitles: [], display: .unknown)
        XCTAssertEqual(options.audioDelaySeconds, 0)
    }

    /// The offset applies where AetherEngine holds the timestamps.
    func test_audioOffsetAvailability_perRoute() {
        XCTAssertTrue(AetherPlaybackEngine.isAudioOffsetAvailable(on: .loopback))
        XCTAssertTrue(AetherPlaybackEngine.isAudioOffsetAvailable(on: .software))
        XCTAssertFalse(AetherPlaybackEngine.isAudioOffsetAvailable(on: .remoteBypass))
        XCTAssertFalse(AetherPlaybackEngine.isAudioOffsetAvailable(on: .audio))
        XCTAssertFalse(AetherPlaybackEngine.isAudioOffsetAvailable(on: .none))
    }

    /// Final review, Important 1: a native-route change reloads the session,
    /// and the route reads `.none` while it's rebuilt. That says nothing about
    /// the offset, so the controls must not blink out with it.
    func test_audioOffsetAvailability_ignoresTheRebuildGap() {
        XCTAssertNil(AetherPlaybackEngine.audioOffsetAvailability(on: .none))
        XCTAssertEqual(AetherPlaybackEngine.audioOffsetAvailability(on: .loopback), true)
        XCTAssertEqual(AetherPlaybackEngine.audioOffsetAvailability(on: .remoteBypass), false)
    }
}
