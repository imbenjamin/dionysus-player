import XCTest
@testable import Dionysus

final class MediaVersionChoiceTests: XCTestCase {
    private let versions = [
        MediaVersion(id: "4k", label: "4K HDR10"),
        MediaVersion(id: "hd", label: "1080p")
    ]

    func test_singleOrNoVersion_playsServerDefault() {
        XCTAssertEqual(
            MediaVersionChoice.decide(versions: [], isResume: false, preferredSourceID: "4k"),
            .play(mediaSourceID: nil)
        )
        XCTAssertEqual(
            MediaVersionChoice.decide(versions: [], isResume: true, preferredSourceID: nil),
            .play(mediaSourceID: nil)
        )
    }

    func test_freshStart_asks_markingLastPlayed() {
        XCTAssertEqual(
            MediaVersionChoice.decide(versions: versions, isResume: false, preferredSourceID: "hd"),
            .ask(versions: versions, lastPlayedID: "hd")
        )
    }

    func test_freshStart_noPreference_asksWithNoMark() {
        XCTAssertEqual(
            MediaVersionChoice.decide(versions: versions, isResume: false, preferredSourceID: nil),
            .ask(versions: versions, lastPlayedID: nil)
        )
    }

    func test_resume_playsPreferred() {
        XCTAssertEqual(
            MediaVersionChoice.decide(versions: versions, isResume: true, preferredSourceID: "hd"),
            .play(mediaSourceID: "hd")
        )
    }

    func test_resume_noPreference_asks() {
        XCTAssertEqual(
            MediaVersionChoice.decide(versions: versions, isResume: true, preferredSourceID: nil),
            .ask(versions: versions, lastPlayedID: nil)
        )
    }

    func test_resume_preferredIDNoLongerPresent_asksWithNoMark() {
        XCTAssertEqual(
            MediaVersionChoice.decide(versions: versions, isResume: true, preferredSourceID: "gone"),
            .ask(versions: versions, lastPlayedID: nil)
        )
    }

    func test_freshStart_preferredIDNoLongerPresent_asksWithNoMark() {
        XCTAssertEqual(
            MediaVersionChoice.decide(versions: versions, isResume: false, preferredSourceID: "gone"),
            .ask(versions: versions, lastPlayedID: nil)
        )
    }

    // MARK: continuation

    private let nextVersions = [
        MediaVersion(id: "n4k", label: "4K HDR10"),
        MediaVersion(id: "nhd", label: "1080p")
    ]

    func test_continuation_singleVersion_playsWithoutAsking() {
        XCTAssertEqual(
            MediaVersionChoice.continuation(versions: [], preferredSourceID: "x", previousLabel: "1080p"),
            .play(mediaSourceID: nil)
        )
    }

    func test_continuation_prefersRememberedThenSameLabel() {
        XCTAssertEqual(
            MediaVersionChoice.continuation(versions: nextVersions, preferredSourceID: "nhd", previousLabel: "4K HDR10"),
            .play(mediaSourceID: "nhd")
        )
        XCTAssertEqual(
            MediaVersionChoice.continuation(versions: nextVersions, preferredSourceID: nil, previousLabel: "1080p"),
            .play(mediaSourceID: "nhd")
        )
    }

    func test_continuation_noMatch_asks() {
        XCTAssertEqual(
            MediaVersionChoice.continuation(versions: nextVersions, preferredSourceID: nil, previousLabel: "Director's Cut"),
            .ask(versions: nextVersions, lastPlayedID: nil)
        )
        XCTAssertEqual(
            MediaVersionChoice.continuation(versions: nextVersions, preferredSourceID: "missing", previousLabel: nil),
            .ask(versions: nextVersions, lastPlayedID: nil)
        )
    }

    // MARK: labelling

    /// The labels themselves, for every shape of sources, read both from the
    /// raw sources (what the next episode and a download label with) and from
    /// the item (the detail page). Comparing the two calls alone proved
    /// nothing, since `mediaVersions` is `versions(of:)` over the item's
    /// sources.
    func test_versionsOfSources_labelsEachShape() {
        let uhd = MediaSourceInfo(id: "src-4k", mediaStreams: [
            MediaStream(index: 0, type: "Video", codec: "hevc", width: 3840, height: 1606, videoRangeType: "HDR10")
        ])
        let hd = MediaSourceInfo(id: "src-hd", mediaStreams: [
            MediaStream(index: 0, type: "Video", codec: "h264", width: 1920, height: 804)
        ])
        let canonical = "[Bluray-2160p][HDR10]-GROUP"
        let original = MediaSourceInfo(id: "o", name: canonical, mediaStreams: [])
        let extended = MediaSourceInfo(id: "e", name: canonical + " - Extended Version", mediaStreams: [])
        let named = MediaSourceInfo(id: "n", name: "Director's Cut", mediaStreams: [])
        let unnamed = MediaSourceInfo(id: "u", mediaStreams: [])
        let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

        let fixtures: [(sources: [MediaSourceInfo], labels: [String])] = [
            // One file, or none: nothing to choose between.
            ([uhd], []),
            ([], []),
            // Technical variants: labelled by resolution and dynamic range.
            ([uhd, hd], ["4K HDR10", "1080p"]),
            // Two alike: numbered so the entries differ.
            ([hd, hd], ["1080p", "1080p (2)"]),
            // Jellyfin's edition naming: the base file is "Original".
            ([original, extended], ["Original", "Extended Version"]),
            // No shared base name and no video: the name, else "Version N".
            ([named, unnamed], ["Director's Cut", "Version 2"]),
        ]
        for (sources, labels) in fixtures {
            XCTAssertEqual(MediaVersion.versions(of: sources).map(\.label), labels)
            let dto = BaseItemDto(id: "m", name: "M", type: .movie, mediaSources: sources)
            XCTAssertEqual(MediaItem(dto: dto, images: images).mediaVersions.map(\.label), labels)
        }
    }
}
