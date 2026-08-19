import XCTest
@testable import Dionysus

final class DownloadTypesTests: XCTestCase {
    // MARK: DownloadResolution.videoBitrate — the bitrate ladder table

    func test_videoBitrate_matchesLadderTable() {
        XCTAssertEqual(DownloadResolution.uhd4K.videoBitrate(preset: .high), 20_000_000)
        XCTAssertEqual(DownloadResolution.uhd4K.videoBitrate(preset: .normal), 12_000_000)
        XCTAssertEqual(DownloadResolution.uhd4K.videoBitrate(preset: .dataSaver), 6_000_000)

        XCTAssertEqual(DownloadResolution.hd1080p.videoBitrate(preset: .high), 6_000_000)
        XCTAssertEqual(DownloadResolution.hd1080p.videoBitrate(preset: .normal), 3_000_000)
        XCTAssertEqual(DownloadResolution.hd1080p.videoBitrate(preset: .dataSaver), 1_500_000)

        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .high), 1_200_000)
        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .normal), 600_000)
        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .dataSaver), 350_000)
    }

    func test_audioBitrate_matchesLadderTable() {
        XCTAssertEqual(DownloadBitratePreset.high.audioBitrate, 192_000)
        XCTAssertEqual(DownloadBitratePreset.normal.audioBitrate, 160_000)
        XCTAssertEqual(DownloadBitratePreset.dataSaver.audioBitrate, 96_000)
    }

    // MARK: DownloadTranscodeCalculator.target

    func test_target_capsToTierWhenSourceIsLargerOrUnknown() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .hd1080p, preset: .high, isSourceHDR: false,
            sourceWidth: 3840, sourceHeight: 2160, sourceBitrate: 50_000_000
        )
        XCTAssertEqual(target.maxWidth, 1920)
        XCTAssertEqual(target.maxHeight, 1080)
        XCTAssertEqual(target.videoBitrate, 6_000_000)
        XCTAssertEqual(target.videoProfile, "main")
    }

    /// Never upscale/inflate: a source below the requested tier keeps its
    /// own (lower) dimensions/bitrate.
    func test_target_neverExceedsSourceWhenSourceIsSmaller() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .uhd4K, preset: .high, isSourceHDR: false,
            sourceWidth: 1280, sourceHeight: 720, sourceBitrate: 2_000_000
        )
        XCTAssertEqual(target.maxWidth, 1280)
        XCTAssertEqual(target.maxHeight, 720)
        XCTAssertEqual(target.videoBitrate, 2_000_000)
    }

    /// The real bug this pins (confirmed live, 2026-08-19, "Pokemon" — a
    /// 480p-only source with "1080p HD" requested): dimensions correctly
    /// capped down to the source's own 480p, but the bitrate was still
    /// looked up from the *requested* 1080p tier's own "Normal" rung
    /// (3 Mbps) rather than 480p's own Normal rung — a real quality-setting
    /// mismatch, not just an oversized file, and not something `min(...,
    /// sourceBitrate)` alone catches: `sourceBitrate` here (5 Mbps) is
    /// *above* the requested tier's own 3 Mbps rung, so the old code's cap
    /// against it never engaged at all.
    func test_target_bitrateMatchesAchievedTierNotRequestedTier() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .hd1080p, preset: .normal, isSourceHDR: false,
            sourceWidth: 720, sourceHeight: 480, sourceBitrate: 5_000_000
        )
        XCTAssertEqual(target.maxWidth, 720)
        XCTAssertEqual(target.maxHeight, 480)
        XCTAssertEqual(target.videoBitrate, 600_000, "must use 480p's own Normal rung, not 1080p's")
    }

    /// A source that partially fills a gap between named tiers (720p, with
    /// no dedicated ladder rung of its own) rounds up to the next tier that
    /// can actually contain it (1080p), not down to a smaller one that
    /// would clip it (480p) — same "never upscale, but also never
    /// under-provision" reasoning, just for bitrate instead of dimensions.
    func test_target_bitrateForInBetweenSource_roundsUpToContainingTier() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .uhd4K, preset: .normal, isSourceHDR: false,
            sourceWidth: 1280, sourceHeight: 720, sourceBitrate: 50_000_000
        )
        XCTAssertEqual(target.maxHeight, 720)
        XCTAssertEqual(target.videoBitrate, 3_000_000, "must use 1080p's own Normal rung, the smallest tier that still covers 720p")
    }

    /// A requested tier smaller than the source (deliberately choosing a
    /// lower quality) still uses its own bitrate rung, not stepped down any
    /// further — `effectiveTier` never exceeds `requested`, but the
    /// existing behavior of matching it exactly when the source is at
    /// least as big must be unaffected by this fix.
    func test_target_bitrateWhenSourceAtLeastAsBigAsRequested_matchesRequestedTierExactly() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .sd480p, preset: .high, isSourceHDR: false,
            sourceWidth: 3840, sourceHeight: 2160, sourceBitrate: 50_000_000
        )
        XCTAssertEqual(target.maxHeight, 480)
        XCTAssertEqual(target.videoBitrate, 1_200_000, "480p's own High rung")
    }

    /// Missing source metadata (nil) skips that particular cap rather than
    /// failing — the tier's own max is used as-is.
    func test_target_missingSourceMetadata_fallsBackToTierMax() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .hd1080p, preset: .normal, isSourceHDR: false,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertEqual(target.maxWidth, 1920)
        XCTAssertEqual(target.maxHeight, 1080)
        XCTAssertEqual(target.videoBitrate, 3_000_000)
    }

    func test_target_videoProfile_main10OnlyForHDRSource() {
        let hdr = DownloadTranscodeCalculator.target(
            resolution: .hd1080p, preset: .normal, isSourceHDR: true,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertEqual(hdr.videoProfile, "main10")

        let sdr = DownloadTranscodeCalculator.target(
            resolution: .hd1080p, preset: .normal, isSourceHDR: false,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertEqual(sdr.videoProfile, "main")
    }

    // MARK: DownloadBitratePreset.displayName(in:)

    func test_displayNameInResolution_showsWholeNumberMbpsWithoutDecimal() {
        XCTAssertEqual(DownloadBitratePreset.high.displayName(in: .hd1080p), "High (6 Mbps)")
    }

    func test_displayNameInResolution_showsFractionalMbps() {
        XCTAssertEqual(DownloadBitratePreset.dataSaver.displayName(in: .hd1080p), "Data Saver (1.5 Mbps)")
    }
}
