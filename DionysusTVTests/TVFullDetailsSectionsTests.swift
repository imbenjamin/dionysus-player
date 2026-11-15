import XCTest
@testable import Dionysus

/// What the Apple TV's Details panel and full-screen details list for a title
/// with one version and with several (#289): the full details show one
/// version at a time, chosen by its tab; the panel summarises the remembered
/// one and names every version.
final class TVFullDetailsSectionsTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    private let uhd = MediaSourceInfo(id: "src-4k", container: "mkv", mediaStreams: [
        MediaStream(index: 0, type: "Video", codec: "hevc", width: 3840, height: 2160, videoRangeType: "HDR10"),
        MediaStream(index: 1, type: "Audio", codec: "truehd")
    ])
    private let hd = MediaSourceInfo(id: "src-1080p", container: "mp4", mediaStreams: [
        MediaStream(index: 0, type: "Video", codec: "h264", width: 1920, height: 1080),
        MediaStream(index: 1, type: "Audio", codec: "aac"),
        MediaStream(index: 2, type: "Subtitle", codec: "subrip")
    ])

    private func movie(_ sources: [MediaSourceInfo]) -> MediaItem {
        MediaItem(dto: BaseItemDto(id: "m", name: "Arrival", type: .movie, mediaSources: sources), images: images)
    }

    func test_sections_singleVersion_unchanged() {
        let sections = TVFullDetailsView.sections(for: movie([hd]), versionID: nil)
        XCTAssertEqual(sections.map(\.id), ["video.default", "audio.default", "subtitles.default"])
        XCTAssertEqual(sections.map(\.title), ["Video", "Audio", "Subtitles"])
    }

    func test_sections_selectedVersionOnly_noSuffix() {
        let item = movie([uhd, hd])
        let hdSections = TVFullDetailsView.sections(for: item, versionID: "src-1080p")
        XCTAssertEqual(hdSections.map(\.id), ["video.src-1080p", "audio.src-1080p", "subtitles.src-1080p"])
        XCTAssertEqual(hdSections.map(\.title), ["Video", "Audio", "Subtitles"])
        XCTAssertEqual(hdSections.first?.rows.first { $0.label == "Container" }?.value, "MP4")

        // No pick (or one the title no longer has) shows the first version,
        // the one the server would play.
        for versionID in [nil, "gone"] {
            let sections = TVFullDetailsView.sections(for: item, versionID: versionID)
            XCTAssertEqual(sections.map(\.id), ["video.src-4k", "audio.src-4k"])
            XCTAssertEqual(sections.map(\.title), ["Video", "Audio"])
        }
    }

    func test_selectedVersionID_fallsBackToTheFirstVersion() {
        let item = movie([uhd, hd])
        XCTAssertEqual(TVFullDetailsView.selectedVersionID(in: item, preferred: "src-1080p"), "src-1080p")
        XCTAssertEqual(TVFullDetailsView.selectedVersionID(in: item, preferred: nil), "src-4k")
        XCTAssertEqual(TVFullDetailsView.selectedVersionID(in: item, preferred: "gone"), "src-4k")
        XCTAssertNil(TVFullDetailsView.selectedVersionID(in: movie([hd]), preferred: "src-1080p"))
    }

    func test_panelRows_multiVersion_addsVersionsRow() {
        let item = movie([uhd, hd])
        let rows = TVDetailsPanel.rows(for: item, versionID: "src-1080p")
        XCTAssertEqual(rows.first { $0.label == "Versions" }?.value, "4K HDR10, 1080p")
        // The summary describes the remembered version.
        XCTAssertEqual(rows.first { $0.label == "Video" }?.value, "1920\u{00D7}1080 (1080p)")

        let firstRows = TVDetailsPanel.rows(for: item, versionID: nil)
        XCTAssertEqual(firstRows.first { $0.label == "Video" }?.value, "3840\u{00D7}2160 (4K) \u{00B7} HDR10")
    }

    func test_panelRows_singleVersion_hasNoVersionsRow() {
        let rows = TVDetailsPanel.rows(for: movie([hd]), versionID: nil)
        XCTAssertFalse(rows.contains { $0.label == "Versions" })
    }
}
