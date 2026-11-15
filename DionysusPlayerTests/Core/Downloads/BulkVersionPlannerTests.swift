import XCTest
@testable import Dionysus

/// Whether a bulk download asks which version once, per item, or not at all
/// (#289): only items with two or more versions count (D6).
final class BulkVersionPlannerTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: nil)

    private func episode(_ id: String) -> MediaItem {
        MediaItem(dto: BaseItemDto(id: id, name: id, type: .episode), images: images)
    }

    private func source(_ id: String, width: Int, hdr: Bool = false) -> MediaSourceInfo {
        var video = MediaStream(index: 0, type: "Video", codec: "hevc", width: width, height: width * 9 / 16)
        video.videoRangeType = hdr ? "HDR10" : "SDR"
        return MediaSourceInfo(id: id, mediaStreams: [video])
    }

    /// A 4K HDR10 and a 1080p file, labelled "4K HDR10" and "1080p".
    private func twoResolutions(_ id: String) -> EpisodeScan {
        EpisodeScan(
            episode: episode(id), sources: [source("\(id)-4k", width: 3840, hdr: true), source("\(id)-1080p", width: 1920)]
        )
    }

    private func single(_ id: String) -> EpisodeScan {
        EpisodeScan(episode: episode(id), sources: [source("\(id)-only", width: 1920)])
    }

    func test_plan_allSingleVersion_noChoice() {
        XCTAssertEqual(BulkVersionPlanner.plan([single("e1"), single("e2")]), .noChoice)
        XCTAssertEqual(BulkVersionPlanner.plan([]), .noChoice)
    }

    func test_plan_matchingLabels_uniform() {
        XCTAssertEqual(
            BulkVersionPlanner.plan([twoResolutions("e1"), twoResolutions("e2"), twoResolutions("e3")]),
            .uniform(labels: ["4K HDR10", "1080p"])
        )
    }

    func test_plan_differentLabels_perEpisode() {
        let other = EpisodeScan(episode: episode("e2"), sources: [source("e2-a", width: 1280), source("e2-b", width: 1920)])
        XCTAssertEqual(BulkVersionPlanner.plan([twoResolutions("e1"), other]), .perEpisode(["e1", "e2"]))
    }

    /// The same versions listed in another order are a different list: the
    /// question's first option is the server's default, which differs.
    func test_plan_sameLabelsDifferentOrder_perEpisode() {
        let reversed = EpisodeScan(
            episode: episode("e2"), sources: [source("e2-1080p", width: 1920), source("e2-4k", width: 3840, hdr: true)]
        )
        XCTAssertEqual(BulkVersionPlanner.plan([twoResolutions("e1"), reversed]), .perEpisode(["e1", "e2"]))
    }

    /// A single-version episode neither breaks a uniform season nor is
    /// listed for a pick.
    func test_plan_singleVersionEpisodesIgnored_uniform() {
        XCTAssertEqual(
            BulkVersionPlanner.plan([twoResolutions("e1"), single("e2"), twoResolutions("e3")]),
            .uniform(labels: ["4K HDR10", "1080p"])
        )
        let mixed = EpisodeScan(episode: episode("e4"), sources: [source("e4-a", width: 1280), source("e4-b", width: 1920)])
        XCTAssertEqual(
            BulkVersionPlanner.plan([twoResolutions("e1"), single("e2"), mixed]),
            .perEpisode(["e1", "e4"])
        )
    }

    /// Two 1080p files per episode label as "1080p" and "1080p (2)"; the
    /// uniform answer maps to each episode's own source of that label.
    func test_plan_uniform_mapsDuplicateLabelsPerEpisode() {
        func twin(_ id: String) -> EpisodeScan {
            EpisodeScan(episode: episode(id), sources: [source("\(id)-a", width: 1920), source("\(id)-b", width: 1920)])
        }
        let scans = [twin("e1"), twin("e2")]
        XCTAssertEqual(BulkVersionPlanner.plan(scans), .uniform(labels: ["1080p", "1080p (2)"]))
        XCTAssertEqual(BulkVersionPlanner.source(in: scans[0], forLabel: "1080p (2)")?.id, "e1-b")
        XCTAssertEqual(BulkVersionPlanner.source(in: scans[1], forLabel: "1080p (2)")?.id, "e2-b")
        XCTAssertEqual(BulkVersionPlanner.source(in: scans[1], forLabel: "1080p")?.id, "e2-a")
        XCTAssertNil(BulkVersionPlanner.source(in: scans[1], forLabel: "4K HDR10"))
    }

    func test_source_singleVersionScan_returnsItsOnlySource() {
        XCTAssertEqual(BulkVersionPlanner.source(in: single("e1"), forLabel: "1080p")?.id, "e1-only")
        XCTAssertNil(BulkVersionPlanner.source(in: EpisodeScan(episode: episode("e2"), sources: []), forLabel: "1080p"))
    }
}
