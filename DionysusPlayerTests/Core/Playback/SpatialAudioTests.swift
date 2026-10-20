import XCTest
@testable import Dionysus

final class SpatialAudioTests: XCTestCase {
    private func audio(
        _ index: Int, codec: String, spatial: String? = nil, language: String? = "eng",
        title: String? = nil, isDefault: Bool = false
    ) -> MediaStream {
        var stream = MediaStream(index: index, type: "Audio")
        stream.codec = codec
        stream.audioSpatialFormat = spatial
        stream.language = language
        stream.title = title
        stream.isDefault = isDefault
        return stream
    }

    private let video = MediaStream(index: 0, type: "Video")

    private func settings(atmos: SpeakerLayout? = nil, dtsX: SpeakerLayout? = nil) -> SpatialAudioSettings {
        var settings = SpatialAudioSettings()
        if let atmos { settings.atmosEnabled = true; settings.atmosLayout = atmos }
        if let dtsX { settings.dtsXEnabled = true; settings.dtsXLayout = dtsX }
        return settings
    }

    // MARK: layouts

    func test_layouts_perFormat() {
        XCTAssertEqual(SpatialAudioFormat.dolbyAtmos.layouts, [.l512, .l514, .l712, .l714, .l916])
        XCTAssertEqual(SpatialAudioFormat.dtsX.layouts, [.l714, .l916])
        XCTAssertEqual(SpatialAudioFormat.defaultLayout, .l714)
        XCTAssertEqual(SpeakerLayout.l512.rawValue, "5.1.2")
    }

    /// "7.1.4" alone has no words, which the accessibility audit rejects.
    func test_layout_accessibilityLabel_namesSpeakers() {
        XCTAssertEqual(SpeakerLayout.l916.accessibilityLabel, "9.1.6 speakers")
        XCTAssertEqual(SpeakerLayout.l714.accessibilityLabel, "7.1.4 speakers (Default)")
    }

    /// Both pickers, on both platforms, mark the default (Benjamin, 2026-10-20).
    func test_layout_optionLabel_marksTheDefault() {
        XCTAssertEqual(SpeakerLayout.l714.optionLabel, "7.1.4 (Default)")
        XCTAssertEqual(SpeakerLayout.l916.optionLabel, "9.1.6")
    }

    func test_settings_defaultOff_at714() {
        let settings = SpatialAudioSettings()
        XCTAssertFalse(settings.atmosEnabled)
        XCTAssertFalse(settings.dtsXEnabled)
        XCTAssertEqual(settings.atmosLayout, .l714)
        XCTAssertEqual(settings.dtsXLayout, .l714)
        XCTAssertNil(settings.layout(for: .dolbyAtmos))
        XCTAssertNil(settings.layout(for: .dtsX))
    }

    // MARK: format(of:)

    func test_format_trueHDAtmos() {
        XCTAssertEqual(SpatialAudioRules.format(of: audio(1, codec: "truehd", spatial: "DolbyAtmos")), .dolbyAtmos)
    }

    func test_format_dtsX() {
        XCTAssertEqual(SpatialAudioRules.format(of: audio(1, codec: "dts", spatial: "DTSX")), .dtsX)
    }

    /// E-AC-3 JOC is stream-copied with its objects already; it needs no
    /// rendering.
    func test_format_eac3Atmos_isNil() {
        XCTAssertNil(SpatialAudioRules.format(of: audio(1, codec: "eac3", spatial: "DolbyAtmos")))
    }

    func test_format_unlabelledTrueHD_isNil() {
        XCTAssertNil(SpatialAudioRules.format(of: audio(1, codec: "truehd")))
        XCTAssertNil(SpatialAudioRules.format(of: video))
    }

    // MARK: rendering(for:settings:)

    func test_rendering_atmosOn_usesAtmosLayout() {
        let stream = audio(1, codec: "truehd", spatial: "DolbyAtmos")
        XCTAssertEqual(SpatialAudioRules.rendering(for: stream, settings: settings(atmos: .l512)), .layout(.l512))
    }

    func test_rendering_atmosOff_isOff() {
        let stream = audio(1, codec: "truehd", spatial: "DolbyAtmos")
        XCTAssertEqual(SpatialAudioRules.rendering(for: stream, settings: settings(dtsX: .l916)), .off)
    }

    func test_rendering_dtsXOn_usesDTSXLayout() {
        let stream = audio(1, codec: "dts", spatial: "DTSX")
        XCTAssertEqual(SpatialAudioRules.rendering(for: stream, settings: settings(atmos: .l512, dtsX: .l916)), .layout(.l916))
    }

    func test_rendering_noStream_isOff() {
        XCTAssertEqual(SpatialAudioRules.rendering(for: nil, settings: settings(atmos: .l714, dtsX: .l714)), .off)
    }

    // MARK: predictedAudioStream

    func test_predict_rememberedTrackWins() {
        let streams = [video, audio(1, codec: "truehd", spatial: "DolbyAtmos", isDefault: true), audio(2, codec: "dts", spatial: "DTSX")]
        let predicted = SpatialAudioRules.predictedAudioStream(in: streams, rememberedTrackID: 2, settings: settings(atmos: .l714))
        XCTAssertEqual(predicted?.index, 2)
    }

    func test_predict_rememberedTrackMissing_fallsBackToDefault() {
        let streams = [video, audio(1, codec: "ac3", isDefault: true), audio(2, codec: "aac")]
        let predicted = SpatialAudioRules.predictedAudioStream(in: streams, rememberedTrackID: 9, settings: SpatialAudioSettings())
        XCTAssertEqual(predicted?.index, 1)
    }

    func test_predict_noDefault_isFirstAudio() {
        let streams = [video, audio(1, codec: "ac3"), audio(2, codec: "aac")]
        XCTAssertEqual(SpatialAudioRules.predictedAudioStream(in: streams, rememberedTrackID: nil, settings: SpatialAudioSettings())?.index, 1)
    }

    /// With rendering on, the engine prefers the TrueHD Atmos track of the
    /// default's language over the default.
    func test_predict_atmosOn_prefersSameLanguageAtmos() {
        let streams = [video, audio(1, codec: "dts", isDefault: true), audio(2, codec: "truehd", spatial: "DolbyAtmos")]
        XCTAssertEqual(SpatialAudioRules.predictedAudioStream(in: streams, rememberedTrackID: nil, settings: settings(atmos: .l714))?.index, 2)
    }

    func test_predict_dtsXOn_prefersSameLanguageDTSX() {
        let streams = [video, audio(1, codec: "ac3", isDefault: true), audio(2, codec: "dts", spatial: "DTSX")]
        XCTAssertEqual(SpatialAudioRules.predictedAudioStream(in: streams, rememberedTrackID: nil, settings: settings(dtsX: .l714))?.index, 2)
    }

    func test_predict_bothOff_keepsDefault() {
        let streams = [video, audio(1, codec: "dts", isDefault: true), audio(2, codec: "truehd", spatial: "DolbyAtmos")]
        XCTAssertEqual(SpatialAudioRules.predictedAudioStream(in: streams, rememberedTrackID: nil, settings: SpatialAudioSettings())?.index, 1)
    }

    func test_predict_neverAnotherLanguage() {
        let streams = [video, audio(1, codec: "dts", isDefault: true), audio(2, codec: "truehd", spatial: "DolbyAtmos", language: "fre")]
        XCTAssertEqual(SpatialAudioRules.predictedAudioStream(in: streams, rememberedTrackID: nil, settings: settings(atmos: .l714))?.index, 1)
    }

    func test_predict_neverACommentary() {
        let streams = [
            video, audio(1, codec: "dts", isDefault: true),
            audio(2, codec: "truehd", spatial: "DolbyAtmos", title: "Director's Commentary")
        ]
        XCTAssertEqual(SpatialAudioRules.predictedAudioStream(in: streams, rememberedTrackID: nil, settings: settings(atmos: .l714))?.index, 1)
    }

    func test_predict_noAudio_isNil() {
        XCTAssertNil(SpatialAudioRules.predictedAudioStream(in: [video], rememberedTrackID: nil, settings: SpatialAudioSettings()))
    }
}
