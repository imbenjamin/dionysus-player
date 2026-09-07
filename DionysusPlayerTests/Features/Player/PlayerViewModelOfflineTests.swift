import UIKit
import XCTest
@testable import Dionysus

/// `PlayerViewModel`'s offline playback path (`init(downloadedItem:
/// downloadStore:...)`/`start()`'s early branch) — split into its own file
/// from `PlayerViewModelTests.swift` (already large) rather than folded in.
/// See the offline-downloads plan's "Offline playback wiring" section:
/// local `file://` video/subtitle URLs instead of `client.streamURL`/
/// `subtitleURL`, `mediaSegments` seeded from the download's own stored
/// snapshot instead of a live fetch, and progress/stop writing straight to
/// the `DownloadedItem` row (`pendingSync = true`) instead of any network
/// call. Uses `FakePlaybackEngine` (Support/), same as `PlayerViewModelTests`.
@MainActor
final class PlayerViewModelOfflineTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeOfflineViewModel(
        downloadedItem: DownloadedItem, store: DownloadStore, engine: FakePlaybackEngine = FakePlaybackEngine()
    ) -> (PlayerViewModel, FakePlaybackEngine) {
        // A network call from this path would be a bug in itself (see
        // `test_startOffline_neverHitsTheNetwork`) — failing any request
        // that does slip through makes that failure loud in every other
        // offline test too, not just the one dedicated to checking it.
        MockURLProtocol.requestHandler = { _ in throw URLError(.badURL) }
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let viewModel = PlayerViewModel(
            client: client, userID: downloadedItem.userID, itemID: downloadedItem.itemID, engine: engine,
            downloadedItem: downloadedItem, downloadStore: store
        )
        return (viewModel, engine)
    }

    func test_startOffline_loadsLocalFileURLForTheStoredVideoPath() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let (viewModel, engine) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertEqual(engine.loadedURLs, [DownloadFileStore.url(forRelativePath: item.videoFilePath)])
        XCTAssertEqual(engine.playCallCount, 1)
    }

    func test_startOffline_buildsExternalSubtitlesFromStoredFiles() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.subtitleFiles = [
            DownloadedSubtitleFile(index: 2, language: "eng", displayTitle: "English", isForced: false, isDefault: true, isHearingImpaired: false, relativePath: "item-1/subs/2-eng.srt")
        ]
        store.insert(item)
        let (viewModel, engine) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertEqual(engine.loadedExternalSubtitles.first?.count, 1)
        let subtitle = engine.loadedExternalSubtitles.first?.first
        XCTAssertEqual(subtitle?.url, DownloadFileStore.url(forRelativePath: "item-1/subs/2-eng.srt"))
        XCTAssertEqual(subtitle?.language, "eng")
        XCTAssertEqual(subtitle?.isDefault, true)
    }

    func test_startOffline_resumePositionSeeksUnlessStartFromBeginning() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.resumePositionTicks = 900_000_000 // 90s
        store.insert(item)
        let (viewModel, engine) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertEqual(engine.seekedTimes, [90])
    }

    func test_startOffline_startFromBeginning_ignoresResumePosition() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.resumePositionTicks = 900_000_000
        store.insert(item)
        let engine = FakePlaybackEngine()
        MockURLProtocol.requestHandler = { _ in throw URLError(.badURL) }
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let viewModel = PlayerViewModel(
            client: client, userID: item.userID, itemID: item.itemID, engine: engine,
            startFromBeginning: true, downloadedItem: item, downloadStore: store
        )

        await viewModel.start()

        XCTAssertTrue(engine.seekedTimes.isEmpty)
    }

    func test_startOffline_seedsMediaSegmentsFromStoredSnapshot() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.segments = [DownloadedSegment(kind: .intro, startSeconds: 0, endSeconds: 30)]
        store.insert(item)
        let (viewModel, _) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertEqual(viewModel.mediaSegments.map(\.kind), [.intro])
        XCTAssertEqual(viewModel.mediaSegments.first?.startSeconds, 0)
        XCTAssertEqual(viewModel.mediaSegments.first?.endSeconds, 30)
    }

    // MARK: offlineLogoURL — see PlayerViewModel.startOffline's doc comment

    /// A downloaded item's synthetic `BaseItemDto` carries no `imageTags`,
    /// so `item.logoImageURL` alone can never resolve for offline playback
    /// — `offlineLogoURL` is the separate local-file path
    /// `PlayerControlsOverlay.titleRow` checks first. This was a real bug,
    /// confirmed live (2026-08-27): before `offlineLogoURL` existed, every
    /// downloaded item's Player screen fell back to plain title text, even
    /// when a Logo image had been downloaded and cached at enqueue time.
    func test_startOffline_logoImagePathStored_setsOfflineLogoURLToLocalFile() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.logoImagePath = "item-1/logo.png"
        store.insert(item)
        let (viewModel, _) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertEqual(viewModel.offlineLogoURL, DownloadFileStore.url(forRelativePath: "item-1/logo.png"))
        XCTAssertTrue(viewModel.offlineLogoURL?.isFileURL == true)
    }

    /// A download that predates logo caching, or never had a Logo image on
    /// the server, leaves `offlineLogoURL` `nil` — `titleRow` falls back to
    /// plain title text, same as a live item with no logo.
    func test_startOffline_noStoredLogoPath_offlineLogoURLIsNil() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let (viewModel, _) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertNil(viewModel.offlineLogoURL)
    }

    // MARK: trickplay

    func test_startOffline_noStoredTrickplayInfo_scrubThumbnailsUnsupported() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let (viewModel, _) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertFalse(viewModel.supportsScrubThumbnails)
        let thumbnail = await viewModel.scrubThumbnail(atSeconds: 1)
        XCTAssertNil(thumbnail)
    }

    func test_startOffline_storedTrickplayInfo_readsLocalTileSheet() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let info = TrickplayInfo(width: 4, height: 4, tileWidth: 2, tileHeight: 2, thumbnailCount: 4, interval: 1000, bandwidth: 1)
        let item = DownloadTestHelpers.makeItem(itemID: "item-1", trickplayInfo: info)
        store.insert(item)
        defer { DownloadFileStore.deleteItemFiles(itemID: "item-1") }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sheetData = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
        try DownloadFileStore.write(sheetData, toRelativePath: DownloadFileStore.trickplayTileRelativePath(itemID: "item-1", width: 4, sheetIndex: 0))
        let (viewModel, _) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertTrue(viewModel.supportsScrubThumbnails)
        let fetched = await viewModel.scrubThumbnail(atSeconds: 1)
        let thumbnail = try XCTUnwrap(fetched)
        XCTAssertEqual(thumbnail.width, 4)
        XCTAssertEqual(thumbnail.height, 4)
    }

    func test_startOffline_setsNowPlayingInfoFromStoredTitle() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        item.title = "Offline Movie"
        store.insert(item)
        let (viewModel, engine) = makeOfflineViewModel(downloadedItem: item, store: store)

        await viewModel.start()

        XCTAssertEqual(engine.nowPlayingInfoCalls.first?.title, "Offline Movie")
    }

    /// The whole point of this path: it must not depend on network at all.
    /// `makeOfflineViewModel` already fails any request that reaches
    /// `MockURLProtocol` — this just makes that the explicit assertion,
    /// rather than relying on every other test incidentally not triggering
    /// one.
    func test_startOffline_neverHitsTheNetwork() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        var requestMade = false
        let engine = FakePlaybackEngine()
        MockURLProtocol.requestHandler = { request in
            requestMade = true
            return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data())
        }
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let viewModel = PlayerViewModel(
            client: client, userID: item.userID, itemID: item.itemID, engine: engine,
            downloadedItem: item, downloadStore: store
        )

        await viewModel.start()
        await viewModel.stop()

        XCTAssertFalse(requestMade)
    }

    // MARK: error handling

    /// Mirrors `PlayerViewModelTests
    /// .test_start_engineLoadThrows_cancellationError_leavesErrorMessageNil`
    /// for the offline (`startOffline`) path.
    func test_startOffline_engineLoadThrows_cancellationError_leavesErrorMessageNil() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let engine = FakePlaybackEngine()
        engine.loadError = CancellationError()
        let (viewModel, _) = makeOfflineViewModel(downloadedItem: item, store: store, engine: engine)

        await viewModel.start()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.failureCategory)
        XCTAssertEqual(engine.playCallCount, 0)
    }

    /// Mirrors `PlayerViewModelTests
    /// .test_start_engineLoadThrows_playbackLoadFailure_setsErrorMessageAndFailureCategoryFromIt`
    /// for the offline (`startOffline`) path.
    func test_startOffline_engineLoadThrows_playbackLoadFailure_setsErrorMessageAndFailureCategoryFromIt() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let engine = FakePlaybackEngine()
        engine.loadError = PlaybackLoadFailure(failure: PlaybackFailure(message: "The server refused this stream.", category: .refused))
        let (viewModel, _) = makeOfflineViewModel(downloadedItem: item, store: store, engine: engine)

        await viewModel.start()

        XCTAssertEqual(viewModel.errorMessage, "The server refused this stream.")
        XCTAssertEqual(viewModel.failureCategory, .refused)
        XCTAssertEqual(engine.playCallCount, 0)
    }

    // MARK: isOfflinePlayback / PlaybackStatsOverlay's Streaming section

    func test_isOfflinePlayback_trueForADownloadedItemSession() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let (viewModel, _) = makeOfflineViewModel(downloadedItem: item, store: store)

        XCTAssertTrue(viewModel.isOfflinePlayback)
    }

    /// `refreshServerVersion()`/`refreshStreamingSession()` back
    /// `PlaybackStatsOverlay`'s Streaming section — a real bug this session
    /// fixed: they used to dispatch a doomed network request every time the
    /// overlay polled, even during offline playback, where there's no live
    /// server to ask. Both must now no-op entirely, leaving
    /// `serverVersion`/`streamingSession` `nil` rather than attempting
    /// (and silently swallowing the failure of) a request that can never
    /// succeed.
    func test_refreshServerVersionAndStreamingSession_offlinePlayback_noOpWithoutHittingNetwork() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        var requestMade = false
        MockURLProtocol.requestHandler = { request in
            requestMade = true
            return MockURLProtocol.jsonResponse(for: request, status: 200, body: Data())
        }
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let viewModel = PlayerViewModel(
            client: client, userID: item.userID, itemID: item.itemID, engine: FakePlaybackEngine(),
            downloadedItem: item, downloadStore: store
        )

        await viewModel.refreshServerVersion()
        await viewModel.refreshStreamingSession()

        XCTAssertFalse(requestMade)
        XCTAssertNil(viewModel.serverVersion)
        XCTAssertNil(viewModel.streamingSession)
    }

    // MARK: writeOfflineProgress (via stop())

    func test_stop_writesResumePositionAndMarksPendingSync() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let (viewModel, engine) = makeOfflineViewModel(downloadedItem: item, store: store)
        await viewModel.start()
        engine.onTimeUpdate?(120, 3600) // 2 minutes into a 1-hour item — well under the watched threshold

        await viewModel.stop()

        XCTAssertEqual(item.resumePositionTicks, 120 * 10_000_000)
        XCTAssertEqual(item.pendingSync, true)
        XCTAssertEqual(item.isPlayed, false)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    /// No server to defer the "mark as watched" judgement call to, unlike
    /// the live path — see `writeOfflineProgress`'s own doc comment for the
    /// 90% client-side threshold this pins.
    func test_stop_pastWatchedThreshold_marksPlayedAndClearsResumePosition() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let (viewModel, engine) = makeOfflineViewModel(downloadedItem: item, store: store)
        await viewModel.start()
        engine.onTimeUpdate?(3500, 3600) // 97% through

        await viewModel.stop()

        XCTAssertEqual(item.isPlayed, true)
        XCTAssertEqual(item.resumePositionTicks, 0)
        XCTAssertEqual(item.playedPercentage, 100)
        XCTAssertEqual(item.pendingSync, true)
    }

    func test_stop_belowThreshold_leavesIsPlayedFalseAndRecordsFraction() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1")
        store.insert(item)
        let (viewModel, engine) = makeOfflineViewModel(downloadedItem: item, store: store)
        await viewModel.start()
        engine.onTimeUpdate?(1800, 3600) // 50%

        await viewModel.stop()

        XCTAssertEqual(item.isPlayed, false)
        XCTAssertEqual(item.playedPercentage, 50, accuracy: 0.01)
    }
}
