import XCTest
@testable import Dionysus

/// `PlaybackStatsOverlay`'s stream-format rows. The inputs are libav's names,
/// which AetherEngine's probe and Jellyfin's both report; the Jellyfin cases
/// use values read off the LAN test server (10.11.11) on 2026-09-28.
final class StreamFormatDescriptionTests: XCTestCase {
    // MARK: Codec

    func test_codec_joinsTheViewerNameAndProfile() {
        XCTAssertEqual(StreamFormatDescription.codec(name: "hevc", profile: "Main 10"), "HEVC Main 10")
        XCTAssertEqual(StreamFormatDescription.codec(name: "h264", profile: "High"), "H.264 High")
    }

    func test_codec_leavesAnUndeclaredProfileOff() {
        XCTAssertEqual(StreamFormatDescription.codec(name: "av1", profile: nil), "AV1")
        XCTAssertEqual(StreamFormatDescription.codec(name: "mpeg2video", profile: ""), "MPEG-2")
    }

    func test_codec_passesAnUnknownCodecThroughUppercased() {
        XCTAssertEqual(StreamFormatDescription.codec(name: "prores", profile: nil), "PRORES")
    }

    func test_codec_isNilWithoutACodec() {
        XCTAssertNil(StreamFormatDescription.codec(name: nil, profile: "Main 10"))
    }

    // MARK: Pixel format

    func test_pixelFormat_carriesTheDepth() {
        XCTAssertEqual(StreamFormatDescription.pixelFormat(name: "yuv420p10le", bitDepth: 10), "yuv420p10le (10-bit)")
    }

    func test_pixelFormat_fallsBackToWhicheverHalfIsKnown() {
        XCTAssertEqual(StreamFormatDescription.pixelFormat(name: "yuv420p", bitDepth: nil), "yuv420p")
        XCTAssertEqual(StreamFormatDescription.pixelFormat(name: nil, bitDepth: 10), "10-bit")
        XCTAssertEqual(StreamFormatDescription.pixelFormat(name: "yuv420p", bitDepth: 0), "yuv420p")
        XCTAssertNil(StreamFormatDescription.pixelFormat(name: nil, bitDepth: nil))
    }

    // MARK: Colour

    func test_color_usesAetherEnginesLabelsInOrder() {
        XCTAssertEqual(
            StreamFormatDescription.color(primaries: "bt2020", transfer: "smpte2084", matrix: "bt2020nc", range: "tv"),
            "BT.2020 · PQ (SMPTE ST 2084) · BT.2020 NCL · Limited"
        )
        XCTAssertEqual(
            StreamFormatDescription.color(primaries: "bt2020", transfer: "arib-std-b67", matrix: "bt2020nc", range: nil),
            "BT.2020 · HLG · BT.2020 NCL"
        )
    }

    /// An untagged SDR file is common (3:10 to Yuma on the test server). It
    /// must read as a gap, not as BT.709 it never declared.
    func test_color_isNilForAnUntaggedStream() {
        XCTAssertNil(StreamFormatDescription.color(primaries: nil, transfer: nil, matrix: nil, range: nil))
    }

    // MARK: Audio sampling

    func test_audioSampling_carriesTheRateAndDepth() {
        XCTAssertEqual(StreamFormatDescription.audioSampling(sampleRate: 48000, bitsPerSample: 24), "48 kHz · 24-bit")
    }

    /// AAC, AC-3, E-AC-3 and Opus decode to float: AetherEngine reports 0,
    /// Jellyfin omits the field.
    func test_audioSampling_leavesAFloatCodecsDepthOff() {
        XCTAssertEqual(StreamFormatDescription.audioSampling(sampleRate: 48000, bitsPerSample: 0), "48 kHz")
        XCTAssertEqual(StreamFormatDescription.audioSampling(sampleRate: 48000, bitsPerSample: nil), "48 kHz")
    }

    func test_audioSampling_keepsAFractionalRate() {
        XCTAssertEqual(StreamFormatDescription.audioSampling(sampleRate: 44100, bitsPerSample: 16), "44.1 kHz · 16-bit")
    }

    func test_audioSampling_isNilWhenNothingIsDeclared() {
        XCTAssertNil(StreamFormatDescription.audioSampling(sampleRate: 0, bitsPerSample: 0))
    }

    // MARK: Container

    func test_container_namesTheCommonDemuxers() {
        XCTAssertEqual(StreamFormatDescription.container("matroska,webm"), "Matroska")
        XCTAssertEqual(StreamFormatDescription.container("mov,mp4,m4a,3gp,3g2,mj2"), "MP4")
        XCTAssertEqual(StreamFormatDescription.container("mpegts"), "MPEG-TS")
        XCTAssertEqual(StreamFormatDescription.container("flv"), "flv")
        XCTAssertNil(StreamFormatDescription.container(nil))
    }

    // MARK: Jellyfin fallback

    /// A Dolby Vision title's video stream and a TrueHD Atmos track as
    /// Jellyfin sends them. Pins that the new `MediaStream` fields decode, and
    /// that the fallback formats them exactly as the engine's probe would.
    func test_jellyfinStreams_decodeAndFormatLikeTheEnginesProbe() throws {
        let json = """
        [
          {"Index": 0, "Type": "Video", "Codec": "hevc", "Profile": "Main 10",
           "PixelFormat": "yuv420p10le", "BitDepth": 10, "ColorPrimaries": "bt2020",
           "ColorTransfer": "smpte2084", "ColorSpace": "bt2020nc", "VideoRangeType": "DOVIWithHDR10"},
          {"Index": 1, "Type": "Audio", "Codec": "truehd", "Profile": "Dolby TrueHD + Dolby Atmos",
           "SampleRate": 48000, "BitDepth": 24, "ChannelLayout": "7.1", "AudioSpatialFormat": "DolbyAtmos"}
        ]
        """
        let streams = try JellyfinJSON.decoder.decode([MediaStream].self, from: Data(json.utf8))
        let video = streams[0], audio = streams[1]

        XCTAssertEqual(StreamFormatDescription.codec(video), "HEVC Main 10")
        XCTAssertEqual(StreamFormatDescription.pixelFormat(video), "yuv420p10le (10-bit)")
        XCTAssertEqual(StreamFormatDescription.color(video), "BT.2020 · PQ (SMPTE ST 2084) · BT.2020 NCL")
        XCTAssertEqual(audio.profile, "Dolby TrueHD + Dolby Atmos")
        XCTAssertEqual(StreamFormatDescription.audioSampling(audio), "48 kHz · 24-bit")
    }

    func test_jellyfinFallback_isNilWithoutAStream() {
        XCTAssertNil(StreamFormatDescription.codec(nil as MediaStream?))
        XCTAssertNil(StreamFormatDescription.pixelFormat(nil as MediaStream?))
        XCTAssertNil(StreamFormatDescription.color(nil as MediaStream?))
        XCTAssertNil(StreamFormatDescription.audioSampling(nil as MediaStream?))
    }
}
