import XCTest
@testable import Dionysus

/// `dionysus://` links (#406; docs/superpowers/specs/2026-11-11-deep-linking-design.md).
final class DeepLinkTests: XCTestCase {
    private func parse(_ string: String) -> DeepLink? {
        DeepLink(url: URL(string: string)!)
    }

    private func playOptions(_ string: String) -> DeepLink.PlaybackOptions? {
        guard case .play(_, let options) = parse(string)?.destination else { return nil }
        return options
    }

    // MARK: - The Top Shelf's links, unchanged

    func test_topShelfLinks_stillParse_withTheirServer() {
        let item = parse("dionysus://item/abc123?server=http://jf.local:8096")
        XCTAssertEqual(item?.destination, .item(id: "abc123", options: .init()))
        XCTAssertEqual(item?.serverID, "http://jf.local:8096")
        let play = parse("dionysus://play/abc123?server=http://jf.local:8096")
        XCTAssertEqual(play?.destination, .play(id: "abc123", options: .init()))
    }

    func test_topShelfURLs_keepTheirShape() {
        let url = DeepLink(.play(id: "abc123", options: .init()), serverID: "http://jf.local").url
        XCTAssertEqual(url.scheme, "dionysus")
        XCTAssertEqual(url.host(), "play")
        XCTAssertEqual(url.path(), "/abc123")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "server", value: "http://jf.local")])
    }

    // MARK: - Server and user

    func test_serverAndUser_areOptional_andEmptyMeansAbsent() {
        let link = parse("dionysus://item/abc")
        XCTAssertEqual(link?.destination, .item(id: "abc", options: .init()))
        XCTAssertNil(link?.serverID)
        XCTAssertNil(link?.userID)
        XCTAssertNil(parse("dionysus://item/abc?server=&user=")?.serverID)
        XCTAssertEqual(parse("dionysus://item/abc?user=u1")?.userID, "u1")
    }

    // MARK: - Places

    func test_places() {
        XCTAssertEqual(parse("dionysus://home")?.destination, .home)
        XCTAssertEqual(parse("dionysus://home/")?.destination, .home)
        XCTAssertEqual(parse("dionysus://search")?.destination, .search(query: nil))
        XCTAssertEqual(parse("dionysus://search?q=Big%20Buck")?.destination, .search(query: "Big Buck"))
        XCTAssertEqual(parse("dionysus://search?q=")?.destination, .search(query: nil))
        XCTAssertEqual(parse("dionysus://downloads")?.destination, .downloads)
        XCTAssertEqual(parse("dionysus://profile")?.destination, .profile(path: []))
        XCTAssertEqual(parse("dionysus://profile/playback/advanced")?.destination, .profile(path: ["playback", "advanced"]))
        XCTAssertEqual(parse("dionysus://quickconnect/approve?code=123456")?.destination, .quickConnectApproval(code: "123456"))
        XCTAssertEqual(parse("dionysus://quickconnect/approve")?.destination, .quickConnectApproval(code: nil))
    }

    func test_hostsAreCaseInsensitive() {
        XCTAssertEqual(parse("dionysus://Home")?.destination, .home)
        XCTAssertEqual(parse("DIONYSUS://item/abc")?.destination, .item(id: "abc", options: .init()))
    }

    // MARK: - Libraries

    func test_library_withSortOrderFacetsAndFilter() {
        let link = parse("dionysus://library/lib1?sort=dateAdded&order=desc&genre=Drama&studio=HBO&filter=unwatched")
        XCTAssertEqual(link?.destination, .library(id: "lib1", options: .init(
            sort: .dateAdded, order: .descending, genre: "Drama", studio: "HBO", filter: .unwatched
        )))
        XCTAssertEqual(link?.issues, [])
    }

    func test_library_unknownSortOrderOrFilter_isAnIssue_andIgnored() {
        let link = parse("dionysus://library/lib1?sort=rating&order=sideways&filter=liked")
        XCTAssertEqual(link?.destination, .library(id: "lib1", options: .init()))
        XCTAssertEqual(link?.issues, [.unknownSort, .unknownOrder, .unknownFilter])
    }

    // MARK: - Items

    func test_item_withSeasonAndSection() {
        XCTAssertEqual(parse("dionysus://item/s1?season=2&section=cast")?.destination,
                       .item(id: "s1", options: .init(season: "2", section: .cast)))
        let unknown = parse("dionysus://item/s1?section=trivia")
        XCTAssertEqual(unknown?.destination, .item(id: "s1", options: .init()))
        XCTAssertEqual(unknown?.issues, [.unknownSection])
    }

    func test_downloaded() {
        XCTAssertEqual(parse("dionysus://downloaded/m1")?.destination, .downloaded(id: "m1"))
    }

    // MARK: - Playback

    func test_play_everyParameter() {
        let options = playOptions("dionysus://play/m1?t=1:02:03&source=v2&audio=1&subtitle=3&stats=1&offline=1&playlist=p1")
        XCTAssertEqual(options, .init(
            start: .time(3723), mediaSourceID: "v2", audioStreamIndex: 1, subtitle: .stream(3),
            showsStats: true, prefersDownload: true, playlistID: "p1"
        ))
    }

    func test_play_subtitleOff() {
        XCTAssertEqual(playOptions("dionysus://play/m1?subtitle=off")?.subtitle, .off)
    }

    func test_startTime_formats() {
        let cases: [(String, TimeInterval)] = [
            ("0", 0), ("90", 90), ("90.5", 90.5), ("1:30", 90), ("0:05", 5),
            ("1:02:03", 3723), ("10:00:00", 36000), ("01:02:03", 3723),
        ]
        for (text, seconds) in cases {
            XCTAssertEqual(DeepLink.seconds(from: text), seconds, text)
        }
    }

    func test_startTime_rejects() {
        for text in ["", "-5", "abc", "1:60", "1:5", "1:2:3:4", "1:60:00", "nan", "inf", "1e3", ":30", "1:", "+5", " 5"] {
            XCTAssertNil(DeepLink.seconds(from: text), text)
        }
    }

    func test_unreadableStartTime_isAnIssue_andPlaysAsPlayWould() {
        let link = parse("dionysus://play/m1?t=-5")
        XCTAssertEqual(link?.destination, .play(id: "m1", options: .init()))
        XCTAssertEqual(link?.issues, [.unreadableStartTime])
    }

    func test_chapter_isOneBased_andIgnoredUnderATime() {
        XCTAssertEqual(playOptions("dionysus://play/m1?chapter=3")?.start, .chapter(3))
        XCTAssertEqual(playOptions("dionysus://play/m1?chapter=3&t=10")?.start, .time(10))
        let zero = parse("dionysus://play/m1?chapter=0")
        XCTAssertNil(playOptions("dionysus://play/m1?chapter=0")?.start)
        XCTAssertEqual(zero?.issues, [.unreadableChapter])
    }

    func test_unreadableTracks_areIssues() {
        let link = parse("dionysus://play/m1?audio=x&subtitle=-1")
        XCTAssertEqual(link?.destination, .play(id: "m1", options: .init()))
        XCTAssertEqual(link?.issues, [.unreadableAudio, .unreadableSubtitle])
    }

    func test_sessionOverrides_areDebugOnly() {
        let options = playOptions("dionysus://play/m1?mode=transcode&bitrate=8000000")
        #if DEBUG
        XCTAssertEqual(options?.decisionMode, .transcode)
        XCTAssertEqual(options?.maxBitrate, 8_000_000)
        XCTAssertEqual(parse("dionysus://play/m1?mode=fast&bitrate=lots")?.issues, [.unknownMode, .unreadableBitrate])
        #else
        XCTAssertNil(options?.decisionMode)
        XCTAssertNil(options?.maxBitrate)
        #endif
    }

    func test_serverSetup_isDebugOnly() {
        let link = parse("dionysus://server?url=https://jf.example:8920")
        #if DEBUG
        XCTAssertEqual(link?.destination, .serverSetup(address: "https://jf.example:8920"))
        XCTAssertNil(parse("dionysus://server"))
        #else
        XCTAssertNil(link)
        #endif
    }

    func test_unknownParameters_areIgnoredSilently() {
        let link = parse("dionysus://play/m1?t=5&shuffle=1")
        XCTAssertEqual(link?.destination, .play(id: "m1", options: .init(start: .time(5))))
        XCTAssertEqual(link?.issues, [])
    }

    // MARK: - Malformed

    func test_malformedLinks_parseToNil() {
        for string in [
            "https://item/abc",               // another scheme
            "dionysus://delete/abc",          // unknown destination (never one that changes data)
            "dionysus://signout",
            "dionysus://item",                // missing id
            "dionysus://item/",
            "dionysus://item/a/b",            // one id only
            "dionysus://play/",
            "dionysus://library",
            "dionysus://downloaded",
            "dionysus://home/extra",          // places take no id
            "dionysus://downloads/extra",
            "dionysus://quickconnect",        // only approve
            "dionysus://quickconnect/deny",
            "dionysus://profile/a/b/c",       // two levels at most
            "dionysus:item/abc",              // no host
        ] {
            XCTAssertNil(parse(string), string)
        }
    }

    // MARK: - Building

    func test_url_roundTripsEveryDestination() {
        var destinations: [DeepLink.Destination] = [
            .home, .search(query: nil), .search(query: "a b&c"), .downloads,
            .profile(path: []), .profile(path: ["about", "license"]),
            .quickConnectApproval(code: nil), .quickConnectApproval(code: "123456"),
            .library(id: "lib1", options: .init()),
            .library(id: "lib1", options: .init(sort: .releaseDate, order: .ascending, genre: "Sci-Fi & Fantasy", studio: "BBC", filter: .favorites)),
            .item(id: "s1", options: .init()),
            .item(id: "s1", options: .init(season: "sea1", section: .chapters)),
            .downloaded(id: "m1"),
            .play(id: "m1", options: .init()),
            .play(id: "m1", options: .init(start: .time(90.5), mediaSourceID: "v", audioStreamIndex: 0, subtitle: .off, showsStats: true, prefersDownload: true, playlistID: "p")),
            .play(id: "m1", options: .init(start: .chapter(2), subtitle: .stream(4))),
        ]
        #if DEBUG
        destinations += [
            .play(id: "m1", options: .init(decisionMode: .direct, maxBitrate: 4_000_000)),
            .serverSetup(address: "http://10.0.0.2:8096"),
        ]
        #endif
        for destination in destinations {
            for (server, user) in [(nil, nil), ("http://jf.local:8096", "u1")] as [(String?, String?)] {
                let link = DeepLink(destination, serverID: server, userID: user)
                XCTAssertEqual(DeepLink(url: link.url), link, link.url.absoluteString)
            }
        }
    }
}
