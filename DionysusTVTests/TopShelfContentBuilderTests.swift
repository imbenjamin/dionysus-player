import XCTest
@testable import Dionysus

/// The shelf's order and fill (Benjamin, 2026-10-14): the first 3 Continue
/// Watching items, then Next Up not already shown, then Recently Added,
/// 10 at most; nothing without art.
final class TopShelfContentBuilderTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://jf.local")!)
    private let server = "http://jf.local"

    private func movie(_ id: String, backdrop: Bool = true) -> BaseItemDto {
        var dto = BaseItemDto(id: id, name: "Movie \(id)", type: .movie)
        if backdrop { dto.backdropImageTags = ["tag-\(id)"] }
        return dto
    }

    private func episode(_ id: String, series: String, season: Int = 1, number: Int = 1) -> BaseItemDto {
        var dto = BaseItemDto(id: id, name: "Episode \(id)", type: .episode)
        dto.seriesId = series
        dto.seriesName = "Show \(series)"
        dto.parentIndexNumber = season
        dto.indexNumber = number
        dto.parentBackdropItemId = series
        dto.parentBackdropImageTags = ["tag-\(series)"]
        return dto
    }

    private func build(resume: [BaseItemDto] = [], nextUp: [BaseItemDto] = [], latest: [BaseItemDto] = []) -> [TopShelfEntry] {
        TopShelfContentBuilder.entries(resume: resume, nextUp: nextUp, latest: latest, images: images, serverID: server)
    }

    func test_takesTheFirstThreeResumeItems_thenNextUp_thenLatest_upToTen() {
        let resume = (1...5).map { movie("r\($0)") }
        let nextUp = (1...4).map { episode("n\($0)", series: "s\($0)") }
        let latest = (1...6).map { movie("l\($0)") }
        let ids = build(resume: resume, nextUp: nextUp, latest: latest).map(\.id)
        XCTAssertEqual(ids, ["r1", "r2", "r3", "n1", "n2", "n3", "n4", "l1", "l2", "l3"])
    }

    func test_fewerThanThreeResume_fillsFromNextUp() {
        let ids = build(resume: [movie("r1")], nextUp: [episode("n1", series: "s1")], latest: [movie("l1")]).map(\.id)
        XCTAssertEqual(ids, ["r1", "n1", "l1"])
    }

    func test_neverRepeatsAnItem_orAShowAlreadyResumed() {
        let resumed = episode("e1", series: "s1")
        let sameShowNext = episode("e2", series: "s1", number: 2)
        let ids = build(resume: [resumed], nextUp: [sameShowNext, episode("e9", series: "s9")], latest: [movie("e9"), movie("l1")]).map(\.id)
        XCTAssertEqual(ids, ["e1", "e9", "l1"])
    }

    /// Latest groups a TV library's new episodes into the show itself, whose
    /// id is the show's and which has no `seriesId`.
    func test_neverRepeatsAShowFromLatest_alreadyShownByItsEpisode() {
        var show = BaseItemDto(id: "s1", name: "Show s1", type: .series)
        show.backdropImageTags = ["tag-s1"]
        var otherShow = BaseItemDto(id: "s2", name: "Show s2", type: .series)
        otherShow.backdropImageTags = ["tag-s2"]
        let ids = build(resume: [episode("e1", series: "s1")], nextUp: [episode("e3", series: "s3")],
                        latest: [show, otherShow, movie("l1")]).map(\.id)
        XCTAssertEqual(ids, ["e1", "e3", "s2", "l1"])
    }

    func test_dropsItemsWithNoArt_andSeasonsOrShowsFromResume() {
        var season = BaseItemDto(id: "season", name: "Season 1", type: .season)
        season.backdropImageTags = ["t"]
        let ids = build(resume: [movie("bare", backdrop: false), season, movie("r1")]).map(\.id)
        XCTAssertEqual(ids, ["r1"])
    }

    func test_empty_isEmpty() {
        XCTAssertTrue(build().isEmpty)
    }

    func test_episode_isTitledByItsShow_withNumberInTheContextLine() throws {
        let entry = try XCTUnwrap(build(nextUp: [episode("e4", series: "s1", season: 2, number: 4)]).first)
        XCTAssertEqual(entry.title, "Show s1")
        XCTAssertEqual(entry.contextTitle, "Next Up · S2:E4 · Episode e4")
    }

    func test_contextLines_nameTheirSource() {
        let entries = build(resume: [movie("r1")], latest: [movie("l1")])
        XCTAssertEqual(entries.map(\.contextTitle), ["Continue Watching", "Recently Added"])
    }

    func test_art_isTheBackdropAt1080And4K() throws {
        let entry = try XCTUnwrap(build(resume: [movie("r1")]).first)
        XCTAssertTrue(entry.image1x.absoluteString.contains("/Items/r1/Images/Backdrop"))
        XCTAssertTrue(entry.image1x.absoluteString.contains("maxWidth=1920"))
        XCTAssertTrue(entry.image2x.absoluteString.contains("maxWidth=3840"))
    }

    func test_actions_areDeepLinksForThisServer() throws {
        let entry = try XCTUnwrap(build(resume: [movie("r1")]).first)
        XCTAssertEqual(TVDeepLink(url: entry.displayURL), TVDeepLink(action: .item, itemID: "r1", serverID: server))
        XCTAssertEqual(TVDeepLink(url: entry.playURL), TVDeepLink(action: .play, itemID: "r1", serverID: server))
    }

    func test_logo_isTheItemsOwn_elseItsShows_elseNone() throws {
        var own = movie("r1")
        own.imageTags = ["Logo": "logo-r1"]
        var ep = episode("e1", series: "s1")
        ep.parentLogoItemId = "s1"
        ep.parentLogoImageTag = "logo-s1"
        let entries = build(resume: [own, ep, movie("r2")])
        XCTAssertTrue(entries[0].logoURL?.absoluteString.contains("/Items/r1/Images/Logo") == true)
        XCTAssertTrue(entries[1].logoURL?.absoluteString.contains("/Items/s1/Images/Logo") == true)
        XCTAssertNil(entries[2].logoURL)
    }

    private func resumed(_ id: String, runtimeMinutes: Double, watchedMinutes: Double) -> BaseItemDto {
        var dto = movie(id)
        dto.runTimeTicks = Int64(runtimeMinutes * 60 * 10_000_000)
        dto.userData = UserItemDataDto(playbackPositionTicks: Int64(watchedMinutes * 60 * 10_000_000))
        return dto
    }

    /// Continue Watching says how long is left (Benjamin, 2026-10-14), in
    /// Home's "1h 45m" form, rounded up so the last seconds still say 1m.
    func test_remaining_onlyForContinueWatching() throws {
        let entries = build(
            resume: [resumed("r1", runtimeMinutes: 130, watchedMinutes: 25), resumed("r2", runtimeMinutes: 50, watchedMinutes: 49.5)],
            latest: [resumed("l1", runtimeMinutes: 130, watchedMinutes: 25)]
        )
        XCTAssertEqual(entries[0].remainingText, "1h 45m remaining")
        XCTAssertEqual(entries[1].remainingText, "1m remaining")
        XCTAssertNil(entries[2].remainingText)
    }

    func test_remaining_isNil_withoutARuntime() {
        var dto = movie("r1")
        dto.userData = UserItemDataDto(playbackPositionTicks: 600_000_000)
        XCTAssertNil(build(resume: [dto]).first?.remainingText)
    }

    /// The composited art is cached under this key, so it must change with
    /// anything drawn and stay put otherwise.
    func test_artworkKey_followsWhatIsDrawn() throws {
        let a = resumed("r1", runtimeMinutes: 100, watchedMinutes: 10)
        let b = resumed("r1", runtimeMinutes: 100, watchedMinutes: 10.2)
        let c = resumed("r1", runtimeMinutes: 100, watchedMinutes: 30)
        var d = a
        d.backdropImageTags = ["other"]
        let key = { (dto: BaseItemDto) in try XCTUnwrap(self.build(resume: [dto]).first).artworkKey }
        XCTAssertEqual(try key(a), try key(b), "The same minutes left draws the same art")
        XCTAssertNotEqual(try key(a), try key(c))
        XCTAssertNotEqual(try key(a), try key(d))
        XCTAssertFalse(try key(a).contains("/"), "The key is a file name")
    }

    func test_mediaOptions_comeFromTheDefaultSource() throws {
        var dto = movie("r1")
        dto.mediaSources = [MediaSourceInfo(id: "src", mediaStreams: [
            MediaStream(index: 0, type: "Video", width: 3840, videoRangeType: "DOVIWithHDR10"),
            MediaStream(index: 1, type: "Audio", codec: "eac3", audioSpatialFormat: "DolbyAtmos"),
            MediaStream(index: 2, type: "Subtitle", isForced: false)
        ])]
        let entry = try XCTUnwrap(build(resume: [dto]).first)
        XCTAssertEqual(entry.mediaOptions, [.uhd4K, .dolbyVision, .atmos, .closedCaptions])
    }
}
