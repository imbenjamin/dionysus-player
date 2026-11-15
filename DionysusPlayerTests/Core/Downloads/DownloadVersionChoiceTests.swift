import XCTest
@testable import Dionysus

/// Which version a single-title download fetches (#289): asked every time
/// there are two or more, unless the long-press sheet already chose one.
final class DownloadVersionChoiceTests: XCTestCase {
    private func source(_ id: String, width: Int, hdr: Bool = false) -> MediaSourceInfo {
        var video = MediaStream(index: 0, type: "Video", codec: "hevc", width: width, height: width * 9 / 16)
        video.videoRangeType = hdr ? "HDR10" : "SDR"
        return MediaSourceInfo(id: id, mediaStreams: [video])
    }

    private var twoVersions: [MediaSourceInfo] {
        [source("m-4k", width: 3840, hdr: true), source("m-1080p", width: 1920)]
    }

    func test_oneSource_downloadsItWithNoLabelAndNoQuestion() {
        let decision = DownloadVersionChoice.decide(
            sources: [source("only", width: 1920)], preselectedSourceID: nil, rememberedSourceID: "only"
        )
        XCTAssertEqual(decision, .download(mediaSourceID: "only", versionLabel: nil))
    }

    func test_noSources_hasNothingToDownload() {
        XCTAssertEqual(
            DownloadVersionChoice.decide(sources: [], preselectedSourceID: nil, rememberedSourceID: nil),
            .noSource
        )
    }

    /// A download isn't a resume: even with a remembered playback pick it
    /// asks, and marks that pick (D8).
    func test_twoVersions_asksEveryTime_markingTheRememberedPlaybackPick() {
        let decision = DownloadVersionChoice.decide(
            sources: twoVersions, preselectedSourceID: nil, rememberedSourceID: "m-1080p"
        )
        XCTAssertEqual(decision, .ask(
            versions: [MediaVersion(id: "m-4k", label: "4K HDR10"), MediaVersion(id: "m-1080p", label: "1080p")],
            lastPlayedID: "m-1080p"
        ))
    }

    func test_twoVersions_aStaleRememberedPick_marksNothing() {
        let decision = DownloadVersionChoice.decide(
            sources: twoVersions, preselectedSourceID: nil, rememberedSourceID: "gone"
        )
        guard case .ask(_, let lastPlayedID) = decision else { return XCTFail("expected a question, got \(decision)") }
        XCTAssertNil(lastPlayedID)
    }

    /// The long-press sheet's Version picker already answered (D9): no
    /// question follows it.
    func test_preselectedBySheet_downloadsThatVersionWithItsLabel() {
        let decision = DownloadVersionChoice.decide(
            sources: twoVersions, preselectedSourceID: "m-1080p", rememberedSourceID: "m-4k"
        )
        XCTAssertEqual(decision, .download(mediaSourceID: "m-1080p", versionLabel: "1080p"))
    }

    /// The sheet's pick vanished between the sheet and the fetch: the sheet's
    /// answer no longer names a version, so the question asks rather than
    /// silently downloading another one.
    func test_preselectedButGone_asks() {
        let decision = DownloadVersionChoice.decide(
            sources: twoVersions, preselectedSourceID: "gone", rememberedSourceID: "m-1080p"
        )
        XCTAssertEqual(decision, .ask(
            versions: [MediaVersion(id: "m-4k", label: "4K HDR10"), MediaVersion(id: "m-1080p", label: "1080p")],
            lastPlayedID: "m-1080p"
        ))
    }

    /// The sheet showed no Version picker (its `/PlaybackInfo` failed, or the
    /// item listed one source), then the download's fetch found two: the
    /// sheet answered nothing about versions, so the question follows it.
    func test_sheetWithoutAPicker_asksAfterIt() {
        let decision = DownloadVersionChoice.decide(
            sources: twoVersions, preselectedSourceID: nil, rememberedSourceID: nil
        )
        XCTAssertEqual(decision, .ask(
            versions: [MediaVersion(id: "m-4k", label: "4K HDR10"), MediaVersion(id: "m-1080p", label: "1080p")],
            lastPlayedID: nil
        ))
    }

    func test_answer_labelsTheChosenVersion() {
        XCTAssertEqual(
            DownloadVersionChoice.answer("m-1080p", sources: twoVersions),
            .download(mediaSourceID: "m-1080p", versionLabel: "1080p")
        )
    }

    // MARK: The sheet's Version picker

    func test_sheetSelection_seedsWithTheRememberedPick() {
        let versions = MediaVersion.versions(of: twoVersions)
        XCTAssertEqual(DownloadVersionChoice.initialSheetSelection(versions: versions, rememberedSourceID: "m-1080p"), "m-1080p")
    }

    func test_sheetSelection_withNothingRemembered_isTheFirst() {
        let versions = MediaVersion.versions(of: twoVersions)
        XCTAssertEqual(DownloadVersionChoice.initialSheetSelection(versions: versions, rememberedSourceID: nil), "m-4k")
        XCTAssertEqual(DownloadVersionChoice.initialSheetSelection(versions: versions, rememberedSourceID: "gone"), "m-4k")
    }

    func test_sheetSelection_singleVersion_isNil() {
        XCTAssertNil(DownloadVersionChoice.initialSheetSelection(versions: [], rememberedSourceID: "x"))
    }

    /// The estimate reads the selected version's specs, falling back to the
    /// first source when nothing is selected (a single-version title).
    func test_sourceForSelection_followsTheSelectedVersion() {
        XCTAssertEqual(DownloadVersionChoice.source(for: "m-1080p", in: twoVersions)?.id, "m-1080p")
        XCTAssertEqual(DownloadVersionChoice.source(for: nil, in: twoVersions)?.id, "m-4k")
        XCTAssertEqual(DownloadVersionChoice.source(for: "gone", in: twoVersions)?.id, "m-4k")
    }
}
