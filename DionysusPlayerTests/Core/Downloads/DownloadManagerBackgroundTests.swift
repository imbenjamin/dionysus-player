import XCTest
@testable import Dionysus

/// `DownloadManager`'s background and relaunch paths, which no other run
/// reaches (TQ-08): adopting the transfers a previous launch left running,
/// answering a background relaunch's completion handler, the trickplay tiles
/// fetched beside a video, and a retry that succeeds.
///
/// The background session is replaced by an in-process one
/// (`makeBackgroundSession`) whose task list each test sets up: a real
/// background configuration transfers in `nsurlsessiond`, out of a test's
/// reach. Its tasks run against `MockURLProtocol`, which holds their requests
/// unanswered (`holdsRequest`), so they stay in flight: `getAllTasks` doesn't
/// list a task that was never resumed.
@MainActor
final class DownloadManagerBackgroundTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!
    private var managers: [DownloadManager] = []
    private var sessions: [URLSession] = []

    override func tearDown() async throws {
        for manager in managers {
            for row in manager.store.allItems() { manager.delete(itemID: row.itemID) }
        }
        managers = []
        sessions.forEach { $0.invalidateAndCancel() }
        sessions = []
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: Helpers

    private func makeLimitPreferences(_ limit: Int) -> DownloadPreferencesStore {
        let suite = "com.dionysusplayer.tests.DownloadManagerBackgroundTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(limit, forKey: downloadMaxConcurrentStorageKey)
        return DownloadPreferencesStore(defaults: defaults)
    }

    /// A manager over `store` whose background session already holds one
    /// in-flight download task per entry of `liveTasks` (a `taskDescription`,
    /// or `nil` for none, and the task's URL). The created tasks come back
    /// through `tasks` once `init` has asked for the session.
    private func makeManager(
        store: DownloadStore,
        liveTasks: [(description: String?, url: URL)] = [],
        maxConcurrentDownloads: Int = 1,
        automaticRetryBackoff: [Duration] = [.zero],
        backgroundEventsBackstop: Duration = .seconds(60),
        started: @escaping (String) -> Void = { _ in }
    ) -> (DownloadManager, () -> (URLSession?, [URLSessionDownloadTask])) {
        var session: URLSession?
        var tasks: [URLSessionDownloadTask] = []
        // The live transfers' requests (host `x`) are never answered.
        MockURLProtocol.holdsRequest = { $0.url?.host == "x" }
        let manager = DownloadManager(
            store: store,
            preferences: makeLimitPreferences(maxConcurrentDownloads),
            automaticRetryBackoff: automaticRetryBackoff,
            startVideoDownloadOverride: { itemID, _, _ in started(itemID) },
            fetchSession: MockURLProtocol.makeSession(),
            makeBackgroundSession: { delegate in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]
                configuration.httpAdditionalHeaders = [MockURLProtocol.generationHeader: String(MockURLProtocol.generation)]
                let made = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                for live in liveTasks {
                    let task = made.downloadTask(with: live.url)
                    task.taskDescription = live.description
                    task.resume()
                    tasks.append(task)
                }
                session = made
                return made
            },
            backgroundEventsBackstop: backgroundEventsBackstop
        )
        managers.append(manager)
        if let session { sessions.append(session) }
        return (manager, { (session, tasks) })
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    private func waitUntil(
        timeout: Duration = .seconds(5), _ message: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out: \(message)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func isCancelled(_ task: URLSessionTask) -> Bool {
        task.state == .canceling || (task.state == .completed && (task.error as? URLError)?.code == .cancelled)
    }

    /// Lets the session's `getAllTasks` callback and the main-actor hop
    /// behind it run: asks the same session for its tasks, then yields.
    private func drain(_ session: URLSession?) async {
        guard let session else { return }
        _ = await session.allTasks
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: Relaunch adoption

    /// A `.downloading` row whose transfer is still live after a plain
    /// relaunch is adopted: it keeps its slot and `delete` can cancel it.
    func test_adoption_liveTask_isAdoptedKeepsItsSlotAndCanBeCancelled() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "live", status: .downloading, pendingDownloadURLString: "https://x/live"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "waiting", status: .queued, pendingDownloadURLString: "https://x/waiting"))
        var started: [String] = []
        let (manager, live) = makeManager(
            store: store, liveTasks: [("live", URL(string: "https://x/live")!)], started: { started.append($0) }
        )

        await waitUntil("the live task is adopted") { manager.test_trackedDownloadTaskItemIDs == ["live"] }

        XCTAssertEqual(store.item(itemID: "live")?.status, .downloading)
        XCTAssertEqual(store.item(itemID: "waiting")?.status, .queued, "The adopted transfer holds the one slot")
        XCTAssertTrue(started.isEmpty)

        let task = try XCTUnwrap(live().1.first)
        manager.delete(itemID: "live")
        await waitUntil("delete cancels the adopted task") { Self.isCancelled(task) }
        XCTAssertEqual(started, ["waiting"], "Deleting it frees the slot for the queued row")
    }

    /// A task with no `taskDescription` is still matched to its row by the
    /// URL the row stored at enqueue.
    func test_adoption_taskWithoutDescription_isMatchedByItsURL() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "by-url", status: .downloading, pendingDownloadURLString: "https://x/by-url"))
        let (manager, _) = makeManager(store: store, liveTasks: [(nil, URL(string: "https://x/by-url")!)])

        await waitUntil("the task is adopted by URL") { manager.test_trackedDownloadTaskItemIDs == ["by-url"] }
        XCTAssertEqual(store.item(itemID: "by-url")?.status, .downloading)
    }

    /// A live transfer whose row is gone (deleted while the app wasn't
    /// running) is cancelled, so it can't keep writing into a directory the
    /// orphan sweep will remove.
    func test_adoption_taskWithNoRow_isCancelled() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "kept", status: .downloading, pendingDownloadURLString: "https://x/kept"))
        let (manager, live) = makeManager(store: store, liveTasks: [
            ("kept", URL(string: "https://x/kept")!),
            ("deleted-meanwhile", URL(string: "https://x/deleted")!),
        ])

        await waitUntil("adoption finishes") { manager.test_trackedDownloadTaskItemIDs == ["kept"] }
        let orphan = try XCTUnwrap(live().1.first { $0.taskDescription == "deleted-meanwhile" })
        await waitUntil("the orphaned task is cancelled") { Self.isCancelled(orphan) }
        let kept = try XCTUnwrap(live().1.first { $0.taskDescription == "kept" })
        XCTAssertEqual(kept.state, .running, "The adopted task is left alone")
    }

    /// A row still `.downloading` with no live task behind it (the transfer
    /// died while the app wasn't running) goes through the automatic retry:
    /// it frees its slot, waits, and is started again.
    func test_adoption_rowWithNoLiveTask_isReArmedAndStartedAgain() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "vanished", status: .downloading, pendingDownloadURLString: "https://x/vanished"))
        var started: [String] = []
        let (manager, _) = makeManager(store: store, started: { started.append($0) })

        await waitUntil("the vanished transfer is started again") { started == ["vanished"] }
        XCTAssertEqual(store.item(itemID: "vanished")?.status, .downloading)
        XCTAssertNil(store.item(itemID: "vanished")?.errorMessage)
        XCTAssertFalse(manager.test_hasPendingRetry(itemID: "vanished"))
    }

    /// With no retry budget, a vanished transfer fails with a written
    /// message rather than sitting at "Downloading…" forever, and the slot
    /// goes to the next queued row.
    func test_adoption_rowWithNoLiveTask_noBudget_failsAndAdmitsTheNext() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "vanished", status: .downloading, pendingDownloadURLString: "https://x/vanished"))
        store.insert(DownloadTestHelpers.makeItem(itemID: "next", status: .queued, pendingDownloadURLString: "https://x/next"))
        var started: [String] = []
        _ = makeManager(store: store, automaticRetryBackoff: [], started: { started.append($0) })

        await waitUntil("the vanished row fails") { store.item(itemID: "vanished")?.status == .failed }
        XCTAssertEqual(
            store.item(itemID: "vanished")?.errorMessage,
            DownloadManager.friendlyDownloadFailureMessage(for: URLError(.backgroundSessionWasDisconnected))
        )
        XCTAssertEqual(started, ["next"])
    }

    // MARK: Background relaunch events

    private static let sessionIdentifier = "com.dionysus.downloads"

    /// Nothing in flight means every event landed before the handler was
    /// stashed, so no "finished events" callback will come to answer it.
    func test_backgroundEvents_nothingInFlight_answersAtOnce() async {
        let (manager, _) = makeManager(store: DownloadTestHelpers.makeInMemoryStore())
        var answered = 0

        manager.handleBackgroundSessionEvents(identifier: Self.sessionIdentifier) { answered += 1 }

        await waitUntil("the handler is answered") { answered == 1 }
    }

    /// With transfers in flight the handler waits for the session to report
    /// every event delivered, then is answered once, not again by the
    /// backstop.
    func test_backgroundEvents_inFlight_answersOnceTheSessionFinishesEvents() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "live", status: .downloading, pendingDownloadURLString: "https://x/live"))
        let (manager, live) = makeManager(
            store: store, liveTasks: [("live", URL(string: "https://x/live")!)],
            backgroundEventsBackstop: .milliseconds(300)
        )
        await waitUntil("adoption finishes") { manager.test_trackedDownloadTaskItemIDs == ["live"] }
        var answered = 0

        manager.handleBackgroundSessionEvents(identifier: Self.sessionIdentifier) { answered += 1 }
        let session = try XCTUnwrap(live().0)
        await drain(session)
        XCTAssertEqual(answered, 0, "Not before the session says it has delivered everything")

        session.delegate?.urlSessionDidFinishEvents?(forBackgroundURLSession: session)
        await waitUntil("finished events answer it") { answered == 1 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(answered, 1, "The backstop finds nothing left to answer")
    }

    /// If the "finished events" callback never comes, the backstop answers
    /// the handler anyway: an unanswered one costs background time.
    func test_backgroundEvents_noFinishedEvents_backstopAnswers() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "live", status: .downloading, pendingDownloadURLString: "https://x/live"))
        let (manager, _) = makeManager(
            store: store, liveTasks: [("live", URL(string: "https://x/live")!)],
            backgroundEventsBackstop: .milliseconds(100)
        )
        await waitUntil("adoption finishes") { manager.test_trackedDownloadTaskItemIDs == ["live"] }
        var answered = 0

        manager.handleBackgroundSessionEvents(identifier: Self.sessionIdentifier) { answered += 1 }

        await waitUntil("the backstop answers it") { answered == 1 }
    }

    /// A second relaunch's handler replaces the first, which is answered
    /// rather than dropped.
    func test_backgroundEvents_secondHandler_answersTheFirst() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "live", status: .downloading, pendingDownloadURLString: "https://x/live"))
        let (manager, _) = makeManager(store: store, liveTasks: [("live", URL(string: "https://x/live")!)])
        await waitUntil("adoption finishes") { manager.test_trackedDownloadTaskItemIDs == ["live"] }
        var first = 0
        var second = 0

        manager.handleBackgroundSessionEvents(identifier: Self.sessionIdentifier) { first += 1 }
        manager.handleBackgroundSessionEvents(identifier: Self.sessionIdentifier) { second += 1 }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
    }

    /// Another session's identifier (the superseded per-item scheme, or one
    /// this build doesn't know) has nothing to route, and is answered at once.
    func test_backgroundEvents_otherIdentifiers_areAnsweredAtOnce() {
        let (manager, _) = makeManager(store: DownloadTestHelpers.makeInMemoryStore())
        var answered: [String] = []

        manager.handleBackgroundSessionEvents(identifier: "com.dionysus.downloads.legacy-item") { answered.append("legacy") }
        manager.handleBackgroundSessionEvents(identifier: "com.example.unknown") { answered.append("unknown") }

        XCTAssertEqual(answered, ["legacy", "unknown"])
    }

    // MARK: Trickplay tiles

    /// Every tile sheet of the source's trickplay track is saved beside the
    /// video; one the server refuses is skipped without failing the rest.
    func test_trickplay_sheetsAreSaved_aRefusedOneIsSkipped() async throws {
        // 2×2 tiles per sheet, 9 thumbnails: three sheets.
        let info = TrickplayInfo(width: 320, height: 180, tileWidth: 2, tileHeight: 2, thumbnailCount: 9, interval: 10_000, bandwidth: 0)
        var detail = BaseItemDto(id: "tp-movie", name: "Trickplay", type: .movie)
        detail.trickplay = ["src-1": ["320": info]]
        let sheet = Data("jpeg-sheet".utf8)
        let detailBody = try JellyfinJSON.encoder.encode(detail)
        let paths = RequestedPaths()

        let row = try await enqueueMovie(id: "tp-movie") { path in
            paths.append(path)
            if path == "/Users/user-1/Items/tp-movie" { return (200, detailBody) }
            if path.hasSuffix("/Trickplay/320/0.jpg") || path.hasSuffix("/Trickplay/320/2.jpg") { return (200, sheet) }
            // A refusal with a body, as a server or proxy sends: saved, the
            // error page would be decoded as a tile sheet.
            if path.hasSuffix("/Trickplay/320/1.jpg") { return (404, Data("<html>Not Found</html>".utf8)) }
            return nil
        }

        XCTAssertEqual(row.trickplayInfo, info)
        for index in [0, 2] {
            let url = DownloadFileStore.url(forRelativePath: DownloadFileStore.trickplayTileRelativePath(itemID: "tp-movie", width: 320, sheetIndex: index))
            XCTAssertEqual(try Data(contentsOf: url), sheet, "Sheet \(index)")
        }
        let refused = DownloadFileStore.url(forRelativePath: DownloadFileStore.trickplayTileRelativePath(itemID: "tp-movie", width: 320, sheetIndex: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path), "A 404 isn't a tile sheet")
        XCTAssertEqual(paths.all.filter { $0.contains("/Trickplay/") }.count, 3, "Each sheet is asked for once")
    }

    /// No trickplay track for this source: nothing is recorded and no sheet
    /// is asked for.
    func test_trickplay_noTrack_recordsNothing() async throws {
        let detailBody = try JellyfinJSON.encoder.encode(BaseItemDto(id: "plain-movie", name: "Plain", type: .movie))
        let paths = RequestedPaths()

        let row = try await enqueueMovie(id: "plain-movie") { path in
            paths.append(path)
            return path == "/Users/user-1/Items/plain-movie" ? (200, detailBody) : nil
        }

        XCTAssertNil(row.trickplayInfo)
        XCTAssertFalse(paths.all.contains { $0.contains("/Trickplay/") })
    }

    /// Request paths seen by the mock, across its loading threads.
    private final class RequestedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func append(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private func enqueueMovie(
        id: String, answer: @escaping @Sendable (String) -> (Int, Data)?
    ) async throws -> DownloadedItem {
        MockURLProtocol.requestHandler = { request in
            let (status, body) = answer(request.url?.path ?? "") ?? (404, Data())
            return MockURLProtocol.jsonResponse(for: request, status: status, body: body)
        }
        let store = DownloadTestHelpers.makeInMemoryStore()
        let (manager, _) = makeManager(store: store)
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let item = MediaItem(dto: BaseItemDto(id: id, name: "Movie", type: .movie), images: ImageURLBuilder(baseURL: baseURL, accessToken: "tok"))
        let source = MediaSourceInfo(id: "src-1", mediaStreams: [MediaStream(index: 0, type: "Video", codec: "h264", width: 1920, height: 1080)])
        try await manager.enqueue(
            item: item, mediaSource: source, audioTrack: nil, subtitleTracks: [],
            resolution: .hd1080p, preset: .normal, client: client, userID: "user-1"
        )
        return try XCTUnwrap(store.item(itemID: id))
    }

    // MARK: Retry

    /// A retry asks again with the choices the first download made, keeping
    /// the audio track when the server still offers it.
    func test_retry_reEnqueuesWithTheOriginalChoices() async throws {
        let row = try await retryFailedDownload(originalAudioIndex: 2, offeredAudio: [(1, true), (2, false)])

        XCTAssertEqual(row.status, .downloading)
        XCTAssertNil(row.errorMessage)
        XCTAssertEqual(row.selectedAudioTrackIndex, 2)
        XCTAssertEqual(row.requestedResolution, .sd480p)
        XCTAssertEqual(row.requestedPreset, .high)
        let url = try XCTUnwrap(row.pendingDownloadURLString.flatMap(URLComponents.init(string:)))
        XCTAssertEqual(url.queryItems?.first { $0.name == "AudioStreamIndex" }?.value, "2")
    }

    /// The original audio track is gone (the file was remuxed since): the
    /// retry falls back to the default track instead of failing.
    func test_retry_originalAudioTrackGone_fallsBackToTheDefault() async throws {
        let row = try await retryFailedDownload(originalAudioIndex: 5, offeredAudio: [(1, false), (2, true)])

        XCTAssertEqual(row.selectedAudioTrackIndex, 2)
        XCTAssertEqual(row.status, .downloading)
    }

    private func retryFailedDownload(originalAudioIndex: Int, offeredAudio: [(index: Int, isDefault: Bool)]) async throws -> DownloadedItem {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let failed = DownloadTestHelpers.makeItem(itemID: "retry-movie", status: .failed)
        failed.selectedAudioTrackIndex = originalAudioIndex
        failed.requestedResolution = .sd480p
        failed.requestedPreset = .high
        failed.errorMessage = "The download stopped early."
        store.insert(failed)
        var started: [String] = []
        let (manager, _) = makeManager(store: store, maxConcurrentDownloads: 2, started: { started.append($0) })

        let audio = offeredAudio.map { track -> MediaStream in
            var stream = MediaStream(index: track.index, type: "Audio", codec: "aac")
            stream.isDefault = track.isDefault
            return stream
        }
        let source = MediaSourceInfo(id: "src-1", mediaStreams: [MediaStream(index: 0, type: "Video", codec: "h264", width: 1920, height: 1080)] + audio)
        let playbackBody = try JellyfinJSON.encoder.encode(PlaybackInfoResponse(mediaSources: [source]))
        let detailBody = try JellyfinJSON.encoder.encode(BaseItemDto(id: "retry-movie", name: "Retry", type: .movie))
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/Items/retry-movie/PlaybackInfo": MockURLProtocol.jsonResponse(for: request, body: playbackBody)
            case "/Users/user-1/Items/retry-movie": MockURLProtocol.jsonResponse(for: request, body: detailBody)
            default: MockURLProtocol.jsonResponse(for: request, status: 404, body: Data())
            }
        }
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())

        try await manager.retry(itemID: "retry-movie", client: client)

        XCTAssertEqual(started, ["retry-movie"], "The transfer starts again")
        return try XCTUnwrap(store.item(itemID: "retry-movie"))
    }
}
