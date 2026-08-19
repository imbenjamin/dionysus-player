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

        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .high), 2_000_000)
        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .normal), 1_200_000)
        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .dataSaver), 600_000)
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
