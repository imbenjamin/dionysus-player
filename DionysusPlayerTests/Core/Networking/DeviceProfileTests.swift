import XCTest
@testable import Dionysus

final class DeviceProfileTests: XCTestCase {
    // MARK: Wire encoding

    /// `TranscodingProfile.protocol` is the one field in this schema that
    /// needs backtick-escaping (a Swift keyword) — this is the one place
    /// its wire encoding needs a direct assertion, since nothing else
    /// exercises it.
    func test_encoding_producesPascalCaseKeysIncludingProtocol() throws {
        let profile = DeviceProfileBuilder.build(maxStreamingBitrate: nil)
        let data = try JellyfinJSON.encoder.encode(profile)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["DirectPlayProfiles"])
        XCTAssertNotNil(json["TranscodingProfiles"])
        XCTAssertNotNil(json["CodecProfiles"])
        XCTAssertNotNil(json["SubtitleProfiles"])

        let transcodingProfiles = try XCTUnwrap(json["TranscodingProfiles"] as? [[String: Any]])
        XCTAssertEqual(transcodingProfiles.first?["Protocol"] as? String, "hls")
    }

    /// `nil` (Unlimited) must NOT stay absent from the wire — confirmed
    /// live (2026-08-28) that Jellyfin's own `DeviceProfile
    /// .MaxStreamingBitrate` model defaults an absent value to a hardcoded
    /// 8 Mbps server-side, which is the field that actually governs
    /// direct-play/stream eligibility. `MaxStaticBitrate`'s "always
    /// present, always generous" fix already covered this for itself —
    /// this pins the same fix for `MaxStreamingBitrate`.
    func test_encoding_nilMaxStreamingBitrate_sendsGenerousValueNotOmitted() throws {
        let profile = DeviceProfileBuilder.build(maxStreamingBitrate: nil)
        let data = try JellyfinJSON.encoder.encode(profile)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["MaxStreamingBitrate"] as? Int, 120_000_000)
    }

    // MARK: DeviceProfileBuilder

    /// No HEVC `VideoCodecTag` gate — deliberately removed (2026-08-28).
    /// Reference clients (Swiftfin) require `hvc1`/`dvh1` because AVPlayer
    /// mishandles the common `hev1` tag's B-frame reordering, but
    /// AetherEngine's direct-play route never touches AVPlayer (its own
    /// FFmpeg pipeline decodes it regardless of tag) — confirmed live that
    /// borrowing the restriction anyway needlessly forced a `hev1`-tagged
    /// source to transcode.
    func test_build_codecProfiles_hasNoHevcTagRestriction() {
        let profile = DeviceProfileBuilder.build(maxStreamingBitrate: nil)
        XCTAssertNil(profile.codecProfiles.first { $0.codec == "hevc" })
    }

    /// PGS is bitmap-only and only exists as an in-container stream —
    /// asking the server to deliver it externally would break it.
    func test_build_subtitleProfiles_bitmapFormatsAreEmbedTextFormatsAreExternal() throws {
        let profile = DeviceProfileBuilder.build(maxStreamingBitrate: nil)
        func method(for format: String) -> String? { profile.subtitleProfiles.first { $0.format == format }?.method }

        XCTAssertEqual(method(for: "pgssub"), "Embed")
        XCTAssertEqual(method(for: "dvdsub"), "Embed")
        XCTAssertEqual(method(for: "dvbsub"), "Embed")
        XCTAssertEqual(method(for: "srt"), "External")
        XCTAssertEqual(method(for: "ass"), "External")
        XCTAssertEqual(method(for: "vtt"), "External")
    }

    func test_build_maxStreamingBitrate_flowsThrough() {
        let profile = DeviceProfileBuilder.build(maxStreamingBitrate: 10_000_000)
        XCTAssertEqual(profile.maxStreamingBitrate, 10_000_000)
    }

    /// Confirmed live (2026-08-28, server-side debug log): a `nil`
    /// `maxStreamingBitrate` must NOT leave `DeviceProfile.maxStreamingBitrate`
    /// absent from the wire — Jellyfin's own model defaults an absent
    /// value to a hardcoded 8 Mbps server-side, and this is the field that
    /// actually governs direct-play/stream eligibility (`Context` is
    /// hardcoded `EncodingContext.Streaming` for that check, so
    /// `MaxStaticBitrate` is never consulted for it despite its name).
    /// A real 41 Mbps source was rejected against that silent default.
    func test_build_nilMaxStreamingBitrate_fallsBackToGenerousCeilingNotNil() {
        let profile = DeviceProfileBuilder.build(maxStreamingBitrate: nil)
        XCTAssertEqual(profile.maxStreamingBitrate, 120_000_000)
    }

    /// Confirmed live (2026-08-28): a `nil`/absent `MaxStaticBitrate` did
    /// NOT behave as unlimited on a real server — a real 4K/34.2 Mbps
    /// source was rejected for direct play/stream
    /// (`ContainerBitrateExceedsLimit`) even with no server-side bitrate
    /// limit configured at all, isolating the cause to this field. Must
    /// always be a generous fixed value, completely independent of the
    /// user's `StreamingMaxBitrate` setting (which only bounds a
    /// transcode's target quality, a different question from whether
    /// direct play/stream is even eligible).
    func test_build_maxStaticBitrate_isAlwaysGenerousRegardlessOfStreamingCap() {
        XCTAssertEqual(DeviceProfileBuilder.build(maxStreamingBitrate: nil).maxStaticBitrate, 120_000_000)
        XCTAssertEqual(DeviceProfileBuilder.build(maxStreamingBitrate: 4_000_000).maxStaticBitrate, 120_000_000)
        XCTAssertEqual(DeviceProfileBuilder.build(maxStreamingBitrate: nil).maxStaticMusicBitrate, 120_000_000)
    }

    /// The HLS transcoding target uses fragmented MP4 (`"mp4"`), not
    /// MPEG-TS (`"ts"`) — per Apple's HLS Authoring Specification, AVPlayer
    /// only supports HEVC over fMP4 carriage, never HEVC-in-MPEG-TS. Both
    /// H.264 and HEVC are offered as transcode targets on this one `"mp4"`
    /// profile (H.264-in-fMP4 is an existing-good combination too, per
    /// AetherEngine's own AE#268 changelog entry — no need for a separate
    /// TS profile just for it). See `DeviceProfile.swift`'s doc comment on
    /// `hlsTranscode` for the full research trail (Apple's spec, Jellyfin's
    /// own web client precedent, AetherEngine's changelog). Audio stays
    /// AAC/AC3/EAC3 — unaffected.
    func test_build_transcodingProfile_containerIsFmp4VideoCodecsAreH264AndHevc() throws {
        let profile = DeviceProfileBuilder.build(maxStreamingBitrate: nil)
        let hls = try XCTUnwrap(profile.transcodingProfiles.first)
        XCTAssertEqual(hls.protocol, "hls")
        XCTAssertEqual(hls.container, "mp4")
        XCTAssertEqual(hls.videoCodec, "h264,hevc")
        XCTAssertEqual(hls.audioCodec, "aac,ac3,eac3")
    }
}
