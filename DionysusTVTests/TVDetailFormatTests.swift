import XCTest
@testable import Dionysus

final class TVDetailFormatTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    private func item(_ dto: BaseItemDto) -> MediaItem { MediaItem(dto: dto, images: images) }

    func test_timeLeft_roundsUpToWholeMinutes() {
        // 95 minutes long, 48 minutes in: 47 left.
        XCTAssertEqual(TVDetailFormat.timeLeft(runTimeTicks: 95 * 600_000_000, resumeSeconds: 48 * 60), "47 min left")
        // 30 seconds left still reads as a minute, never "0 min left".
        XCTAssertEqual(TVDetailFormat.timeLeft(runTimeTicks: 600_000_000, resumeSeconds: 30), "1 min left")
    }

    func test_timeLeft_isNilWithoutAResumePoint_orARuntime() {
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: 600_000_000, resumeSeconds: nil))
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: 600_000_000, resumeSeconds: 0))
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: nil, resumeSeconds: 30))
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: 0, resumeSeconds: 30))
    }

    /// A position past the end (a stale resume point on a re-encoded file)
    /// must not read as a negative time.
    func test_timeLeft_isNilWhenThePositionIsPastTheEnd() {
        XCTAssertNil(TVDetailFormat.timeLeft(runTimeTicks: 600_000_000, resumeSeconds: 120))
    }

    func test_playTitle_forAMovie() {
        let fresh = item(BaseItemDto(id: "m", name: "Arrival", type: .movie))
        XCTAssertEqual(TVDetailFormat.playTitle(target: fresh, isShow: false), "Play")
        var dto = BaseItemDto(id: "m", name: "Arrival", type: .movie)
        dto.runTimeTicks = 95 * 600_000_000
        var userData = UserItemDataDto()
        userData.playbackPositionTicks = 48 * 600_000_000
        dto.userData = userData
        XCTAssertEqual(TVDetailFormat.playTitle(target: item(dto), isShow: false), "Resume")
    }

    func test_playTitle_forAShow_namesTheEpisode() {
        var dto = BaseItemDto(id: "e", name: "Alone in the Night", type: .episode)
        dto.parentIndexNumber = 1
        dto.indexNumber = 3
        XCTAssertEqual(TVDetailFormat.playTitle(target: item(dto), isShow: true), "Play S1:E3")
    }

    /// Review Focus 4: a show with seasons and no episodes has nothing to
    /// play, so there is no title and the page draws no Play button.
    func test_showWithoutEpisodes_hasNoPlayTitle() {
        XCTAssertNil(TVDetailFormat.playTitle(target: nil, isShow: true))
    }

    func test_metadata_skipsWhatTheItemLacks() {
        var dto = BaseItemDto(id: "m", name: "Arrival", type: .movie)
        dto.officialRating = "PG-13"
        dto.genres = ["Sci-Fi", "Drama", "Mystery"]
        // No year and no runtime: neither leaves a gap or a stray separator.
        XCTAssertEqual(TVDetailFormat.metadata(for: item(dto)), ["PG-13", "Sci-Fi, Drama"])
    }
}
