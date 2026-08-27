import XCTest
#if os(iOS)
import UIKit
#endif
@testable import Dionysus

final class DownloadTypesTests: XCTestCase {
    // MARK: DownloadResolution.videoBitrate — the bitrate ladder table

    func test_videoBitrate_matchesLadderTable() {
        XCTAssertEqual(DownloadResolution.uhd4K.videoBitrate(preset: .high), 16_000_000)
        XCTAssertEqual(DownloadResolution.uhd4K.videoBitrate(preset: .normal), 10_000_000)
        XCTAssertEqual(DownloadResolution.uhd4K.videoBitrate(preset: .dataSaver), 6_000_000)

        XCTAssertEqual(DownloadResolution.hd1080p.videoBitrate(preset: .high), 4_500_000)
        XCTAssertEqual(DownloadResolution.hd1080p.videoBitrate(preset: .normal), 3_000_000)
        XCTAssertEqual(DownloadResolution.hd1080p.videoBitrate(preset: .dataSaver), 1_500_000)

        XCTAssertEqual(DownloadResolution.hd720p.videoBitrate(preset: .high), 2_250_000)
        XCTAssertEqual(DownloadResolution.hd720p.videoBitrate(preset: .normal), 1_500_000)
        XCTAssertEqual(DownloadResolution.hd720p.videoBitrate(preset: .dataSaver), 750_000)

        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .high), 1_100_000)
        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .normal), 700_000)
        XCTAssertEqual(DownloadResolution.sd480p.videoBitrate(preset: .dataSaver), 350_000)
    }

    /// The ladder's actual design constraint, asserted directly rather than
    /// left implicit in the table above: every rung of a given preset lands
    /// on that preset's bits-per-pixel-per-frame target (at 24fps), within
    /// the tolerance rounding to tidy numbers allows. This is what makes
    /// "Normal" mean the same thing at 480p as at 4K — if a future edit
    /// nudges a number for a reason that seems locally sensible, this is the
    /// test that should stop it. See `DOWNLOADS.md`.
    func test_videoBitrate_everyRungLandsOnItsPresetBitsPerPixelTarget() {
        // Tier -> the bpp multiplier it carries (less spatial redundancy to
        // exploit at low resolutions, so smaller tiers get a higher target).
        let tierFactors: [DownloadResolution: Double] = [
            .uhd4K: 0.85, .hd1080p: 1.0, .hd720p: 1.08, .sd480p: 1.15
        ]
        let presetTargets: [DownloadBitratePreset: Double] = [
            .high: 0.095, .normal: 0.062, .dataSaver: 0.032
        ]

        for (tier, factor) in tierFactors {
            for (preset, baseTarget) in presetTargets {
                let pixelsPerSecond = Double(tier.maxWidth * tier.maxHeight * 24)
                let actual = Double(tier.videoBitrate(preset: preset)) / pixelsPerSecond
                let expected = baseTarget * factor
                XCTAssertEqual(
                    actual, expected, accuracy: expected * 0.13,
                    "\(tier.rawValue)/\(preset.rawValue) is \(actual) bpp, off its \(expected) target"
                )
            }
        }
    }

    func test_audioBitrate_matchesLadderTable() {
        XCTAssertEqual(DownloadBitratePreset.high.audioBitrate, 160_000)
        XCTAssertEqual(DownloadBitratePreset.normal.audioBitrate, 128_000)
        XCTAssertEqual(DownloadBitratePreset.dataSaver.audioBitrate, 96_000)
    }

    /// Only Data Saver caps frame rate — halving a genuinely 60fps source is
    /// a visible change, and only acceptable when the user has explicitly
    /// asked for the smallest possible file.
    func test_maxFramerate_cappedOnlyOnDataSaver() {
        XCTAssertNil(DownloadBitratePreset.high.maxFramerate)
        XCTAssertNil(DownloadBitratePreset.normal.maxFramerate)
        XCTAssertEqual(DownloadBitratePreset.dataSaver.maxFramerate, 30)
    }

    // MARK: DownloadResolution.deviceClassDefault

    /// Phones default to 720p, tablets to 1080p — see the property's own doc
    /// comment for the pixels-per-degree reasoning.
    func test_deviceClassDefault_isSmallerOnPhoneThanTablet() {
        #if os(iOS)
        let expected: DownloadResolution = UIDevice.current.userInterfaceIdiom == .pad ? .hd1080p : .hd720p
        XCTAssertEqual(DownloadResolution.deviceClassDefault, expected)
        #endif
        // Whichever class this suite runs on, the default must never be a
        // tier the ladder treats as an extreme.
        XCTAssertTrue([.hd720p, .hd1080p].contains(DownloadResolution.deviceClassDefault))
    }

    // MARK: DownloadTranscodeCalculator.target

    func test_target_capsToTierWhenSourceIsLargerOrUnknown() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .hd1080p, preset: .high, isSourceHDR: false,
            sourceWidth: 3840, sourceHeight: 2160, sourceBitrate: 50_000_000
        )
        XCTAssertEqual(target.maxWidth, 1920)
        XCTAssertEqual(target.maxHeight, 1080)
        XCTAssertEqual(target.videoBitrate, 4_500_000)
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
    /// 480p-only source with a 1080p tier requested): dimensions correctly
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
        XCTAssertEqual(target.videoBitrate, 700_000, "must use 480p's own Normal rung, not 1080p's")
    }

    /// Before the 720p tier existed this rounded a 720p source up to 1080p's
    /// rung and downloaded it at 3 Mbps — which is why adding the tier
    /// shrinks downloads for every 720p source in a library, including for
    /// users who never touch the resolution setting.
    func test_target_720pSourceUsesItsOwnRungNotThe1080pOne() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .uhd4K, preset: .normal, isSourceHDR: false,
            sourceWidth: 1280, sourceHeight: 720, sourceBitrate: 50_000_000
        )
        XCTAssertEqual(target.maxHeight, 720)
        XCTAssertEqual(target.videoBitrate, 1_500_000, "720p's own Normal rung, not 1080p's 3 Mbps")
    }

    /// A source that falls between named tiers still rounds *up* to the
    /// smallest tier that can contain it, rather than down to one that would
    /// clip it — same "never upscale, but also never under-provision"
    /// reasoning as the dimension cap.
    func test_target_bitrateForInBetweenSource_roundsUpToContainingTier() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .uhd4K, preset: .normal, isSourceHDR: false,
            sourceWidth: 1600, sourceHeight: 900, sourceBitrate: 50_000_000
        )
        XCTAssertEqual(target.maxHeight, 900)
        XCTAssertEqual(target.videoBitrate, 3_000_000, "must use 1080p's own Normal rung, the smallest tier that still covers 900p")
    }

    /// A requested tier smaller than the source (deliberately choosing a
    /// lower quality) still uses its own bitrate rung, not stepped down any
    /// further — `effectiveTier` never exceeds `requested`.
    func test_target_bitrateWhenSourceAtLeastAsBigAsRequested_matchesRequestedTierExactly() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .sd480p, preset: .high, isSourceHDR: false,
            sourceWidth: 3840, sourceHeight: 2160, sourceBitrate: 50_000_000
        )
        XCTAssertEqual(target.maxHeight, 480)
        XCTAssertEqual(target.videoBitrate, 1_100_000, "480p's own High rung")
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

    /// `main10` unconditionally, including for SDR sources — 10-bit HEVC is
    /// a few percent more efficient than 8-bit regardless of the source's
    /// own bit depth, and every HEVC-capable iOS device decodes it.
    func test_target_videoProfile_isAlwaysMain10() {
        for isHDR in [true, false] {
            let target = DownloadTranscodeCalculator.target(
                resolution: .hd1080p, preset: .normal, isSourceHDR: isHDR,
                sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
            )
            XCTAssertEqual(target.videoProfile, "main10")
        }
    }

    func test_target_maxFramerate_setOnlyForDataSaver() {
        let dataSaver = DownloadTranscodeCalculator.target(
            resolution: .hd720p, preset: .dataSaver, isSourceHDR: false,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertEqual(dataSaver.maxFramerate, 30)

        let normal = DownloadTranscodeCalculator.target(
            resolution: .hd720p, preset: .normal, isSourceHDR: false,
            sourceWidth: nil, sourceHeight: nil, sourceBitrate: nil
        )
        XCTAssertNil(normal.maxFramerate)
    }

    // MARK: Stream-copy passthrough

    /// A source already inside the requested tier is copied, not re-encoded
    /// — no second generation of lossy encoding, no server CPU spent for
    /// nothing.
    func test_target_streamCopyEligible_whenSourceAlreadyFitsTier() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .hd720p, preset: .normal, isSourceHDR: false,
            sourceWidth: 1280, sourceHeight: 720, sourceBitrate: 1_200_000,
            sourceVideoCodec: "h264"
        )
        XCTAssertTrue(target.videoStreamCopyEligible)
    }

    func test_target_streamCopyEligible_acceptsHevcSource() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .hd1080p, preset: .normal, isSourceHDR: false,
            sourceWidth: 1920, sourceHeight: 1080, sourceBitrate: 2_500_000,
            sourceVideoCodec: "hevc"
        )
        XCTAssertTrue(target.videoStreamCopyEligible)
    }

    /// Each condition, checked one at a time by breaking exactly one of them
    /// against an otherwise-eligible baseline. Every one of these has to
    /// fail closed: copying when we shouldn't hands the user an uncapped
    /// original, which is the failure the whole capping path exists to stop.
    func test_target_streamCopyIneligible_whenAnySingleConditionFails() {
        func eligibility(
            isSourceHDR: Bool = false,
            width: Int? = 1280, height: Int? = 720,
            bitrate: Int? = 1_200_000, codec: String? = "h264"
        ) -> Bool {
            DownloadTranscodeCalculator.target(
                resolution: .hd720p, preset: .normal, isSourceHDR: isSourceHDR,
                sourceWidth: width, sourceHeight: height, sourceBitrate: bitrate,
                sourceVideoCodec: codec
            ).videoStreamCopyEligible
        }

        XCTAssertTrue(eligibility(), "baseline must be eligible or the rest of this test proves nothing")
        XCTAssertFalse(eligibility(isSourceHDR: true), "HDR: a copy would preserve HDR that DownloadedItem.isHDR claims is gone")
        XCTAssertFalse(eligibility(bitrate: 3_000_000), "bitrate above the tier rung")
        XCTAssertFalse(eligibility(width: 1920, height: 1080), "resolution above the tier")
        XCTAssertFalse(eligibility(codec: "vp9"), "codec that can't be muxed into MP4")
        XCTAssertFalse(eligibility(codec: nil), "unknown codec must fail closed")
        XCTAssertFalse(eligibility(bitrate: nil), "unknown bitrate must fail closed")
        XCTAssertFalse(eligibility(width: nil), "unknown width must fail closed")
        XCTAssertFalse(eligibility(height: nil), "unknown height must fail closed")
    }

    /// Callers that don't know the source codec (the parameter defaults to
    /// `nil`) get the old always-transcode behaviour rather than an
    /// accidental copy.
    func test_target_streamCopyIneligible_whenCodecNotSupplied() {
        let target = DownloadTranscodeCalculator.target(
            resolution: .hd720p, preset: .normal, isSourceHDR: false,
            sourceWidth: 1280, sourceHeight: 720, sourceBitrate: 1_200_000
        )
        XCTAssertFalse(target.videoStreamCopyEligible)
    }

    // MARK: DownloadBitratePreset.displayName(in:)

    func test_displayNameInResolution_showsWholeNumberMbpsWithoutDecimal() {
        XCTAssertEqual(DownloadBitratePreset.normal.displayName(in: .hd1080p), "Normal (3 Mbps)")
    }

    func test_displayNameInResolution_showsFractionalMbps() {
        XCTAssertEqual(DownloadBitratePreset.high.displayName(in: .hd1080p), "High (4.5 Mbps)")
        XCTAssertEqual(DownloadBitratePreset.dataSaver.displayName(in: .hd1080p), "Data Saver (1.5 Mbps)")
    }

    /// Two decimal places, not one — the ladder has rungs at both 2.25 and
    /// 1.5 Mbps, and one place would render 2.25 as "2.3".
    func test_displayNameInResolution_keepsTwoDecimalPlacesWhenNeeded() {
        XCTAssertEqual(DownloadBitratePreset.high.displayName(in: .hd720p), "High (2.25 Mbps)")
        XCTAssertEqual(DownloadBitratePreset.dataSaver.displayName(in: .hd720p), "Data Saver (0.75 Mbps)")
    }
}
