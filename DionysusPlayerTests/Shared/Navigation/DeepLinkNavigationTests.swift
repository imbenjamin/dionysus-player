import XCTest
@testable import Dionysus

/// Where each `dionysus://` destination lands on iPhone and iPad (#406).
final class DeepLinkNavigationTests: XCTestCase {
    func test_places_selectTheirTab() {
        XCTAssertEqual(DeepLinkNavigation.plan(for: .home), .init(tab: .home, homePath: []))
        XCTAssertEqual(DeepLinkNavigation.plan(for: .downloads), .init(tab: .downloads))
    }

    func test_profile_opensTheLinkedPage() {
        XCTAssertEqual(DeepLinkNavigation.plan(for: .profile(path: [])), .init(tab: .profile, profilePage: .root))
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .profile(path: ["about", "license"])), .init(tab: .profile, profilePage: .license)
        )
    }

    /// A page Profile doesn't have opens Profile and says so.
    func test_profile_unknownPage_opensProfile_andSaysSo() {
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .profile(path: ["nope"])),
            .init(tab: .profile, profilePage: .root, notice: "Profile has no such page.")
        )
    }

    func test_quickConnectApproval_opensQuickConnect_withTheCode() {
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .quickConnectApproval(code: "123456")),
            .init(tab: .profile, profilePage: .quickConnect(code: "123456"))
        )
    }

    /// Home's stack is left alone until the library is found
    /// (`MainTabView`), so an unknown one moves nothing.
    func test_library_isFoundBeforeHomesStackChanges() {
        let options = DeepLink.LibraryOptions(sort: .title, filter: .favorites)
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .library(id: "l", options: options)),
            .init(tab: .home, library: .init(id: "l", options: options))
        )
    }

    func test_library_saysWhatItCouldntRead_inOneNotice() {
        let plan = DeepLinkNavigation.plan(for: .library(id: "l", options: .init()), issues: [.unknownSort, .unknownFilter])
        XCTAssertEqual(plan?.notice, "Couldn't read the sort. Couldn't read the filter.")
    }

    func test_search_fillsTheQuery_orJustOpensSearch() {
        XCTAssertEqual(DeepLinkNavigation.plan(for: .search(query: "Aurora")), .init(tab: .search, searchQuery: "Aurora"))
        XCTAssertEqual(DeepLinkNavigation.plan(for: .search(query: nil)), .init(tab: .search))
    }

    func test_item_replacesHomesStackWithThePage() {
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .item(id: "m1", options: .init())),
            .init(tab: .home, homePath: [.assetDetail(itemID: "m1")])
        )
    }

    /// A season or section rides on a cue the page takes once it has loaded.
    func test_item_withASeasonOrSection_cuesThePage() {
        let options = DeepLink.ItemOptions(season: "2", section: .cast)
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .item(id: "s1", options: options)),
            .init(tab: .home, homePath: [.assetDetail(itemID: "s1")], page: .init(pageID: "s1", options: options))
        )
    }

    func test_item_withAnUnreadableSection_cuesThePage_toSaySo() {
        let plan = DeepLinkNavigation.plan(for: .item(id: "m1", options: .init()), issues: [.unknownSection])
        XCTAssertEqual(plan?.page, .init(pageID: "m1", options: .init(), notices: ["Couldn't read the section."]))
    }

    /// Offline, a downloaded title opens its download's page, which has
    /// neither seasons nor sections.
    func test_item_offlineDownload_dropsTheOptions() {
        let plan = DeepLinkNavigation.plan(
            for: .item(id: "m1", options: .init(section: .cast)), isDownloaded: { _ in true }, isOffline: true
        )
        XCTAssertEqual(plan, .init(tab: .home, homePath: [.downloadedAsset(itemID: "m1")]))
    }

    func test_play_pushesThePage_andCuesItToPlay() {
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .play(id: "m1", options: .init())),
            .init(tab: .home, homePath: [.assetDetail(itemID: "m1")], playback: .init(pageID: "m1", overrides: .init()))
        )
    }

    /// The link's start, version, tracks and stats ride on the cue, with what
    /// it couldn't read.
    func test_play_cuesTheLinksOverrides() {
        let options = DeepLink.PlaybackOptions(start: .time(90), audioStreamIndex: 2, showsStats: true)
        let plan = DeepLinkNavigation.plan(for: .play(id: "m1", options: options), issues: [.unreadableSubtitle])
        XCTAssertEqual(plan?.playback?.overrides, PlaybackLinkOverrides(
            start: .time(90), audioStreamIndex: 2, showsStats: true, notices: ["Couldn't read the subtitle track."]
        ))
    }

    /// A playlist member plays from the playlist's page, which queues the rest.
    func test_playAPlaylistMember_pushesThePlaylist_andCuesTheMember() {
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .play(id: "m1", options: .init(playlistID: "p1"))),
            .init(tab: .home, homePath: [.assetDetail(itemID: "p1")],
                  playback: .init(pageID: "p1", memberID: "m1", overrides: .init()))
        )
    }

    /// `offline=1` plays a downloaded title from its download's page; without
    /// a download it streams, and says so.
    func test_playOffline_usesTheDownload_whenThereIsOne() {
        let options = DeepLink.PlaybackOptions(prefersDownload: true)
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .play(id: "m1", options: options), isDownloaded: { $0 == "m1" }),
            .init(tab: .home, homePath: [.downloadedAsset(itemID: "m1")],
                  playback: .init(pageID: "m1", playsDownload: true, overrides: .init()))
        )
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .play(id: "m2", options: options), isDownloaded: { $0 == "m1" }),
            .init(tab: .home, homePath: [.assetDetail(itemID: "m2")], playback: .init(
                pageID: "m2", overrides: .init(notices: ["This title isn't downloaded, so it's streaming."])
            ))
        )
    }

    /// Offline, a downloaded title opens and plays from its download.
    func test_whileOffline_aDownloadedTitleOpensItsDownload() {
        let downloaded: (String) -> Bool = { $0 == "m1" }
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .play(id: "m1", options: .init()), isDownloaded: downloaded, isOffline: true)?.homePath,
            [.downloadedAsset(itemID: "m1")]
        )
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .item(id: "m1", options: .init()), isDownloaded: downloaded, isOffline: true)?.homePath,
            [.downloadedAsset(itemID: "m1")]
        )
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .item(id: "m1", options: .init()), isDownloaded: downloaded)?.homePath,
            [.assetDetail(itemID: "m1")], "Online, the title's own page"
        )
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .play(id: "m2", options: .init()), isDownloaded: downloaded, isOffline: true)?.homePath,
            [.assetDetail(itemID: "m2")], "Not downloaded: the page's own offline state"
        )
    }

    /// The title's page and its download's share the item id; a cue for one
    /// isn't the other's, as the title's page can still be on the stack the
    /// link replaces.
    @MainActor
    func test_aCueForTheDownload_isntTakenByTheTitlesPage() {
        let center = DeepLinkPlaybackCue.shared
        defer { center.clear() }
        center.post(.init(pageID: "m1", playsDownload: true, overrides: .init()))
        XCTAssertNil(center.take(for: "m1"))
        XCTAssertEqual(center.take(for: "m1", download: true)?.playsDownload, true)
        XCTAssertNil(center.take(for: "m1", download: true), "Taken once")
        center.post(itemID: "m1")
        XCTAssertNil(center.take(for: "m1", download: true))
        XCTAssertNotNil(center.take(for: "m1"))
    }

    func test_downloaded_opensTheDownloadsPage() {
        XCTAssertEqual(
            DeepLinkNavigation.plan(for: .downloaded(id: "m1")),
            .init(tab: .home, homePath: [.downloadedAsset(itemID: "m1")])
        )
    }

    func test_serverSetup_isntOpenedYet() {
        XCTAssertNil(DeepLinkNavigation.plan(for: .serverSetup(address: "http://x")))
    }
}
