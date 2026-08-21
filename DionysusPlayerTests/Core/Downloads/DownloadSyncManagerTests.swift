import XCTest
@testable import Dionysus

@MainActor
final class DownloadSyncManagerTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> JellyfinAPIClient {
        JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
    }

    func test_syncIfNeeded_successfulPush_clearsPendingSync() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)

        let row = store.item(itemID: "item-1")
        XCTAssertEqual(row?.pendingSync, false)
        XCTAssertNotNil(row?.lastSyncedAt)
    }

    func test_syncIfNeeded_hitsUpdateUserDataEndpointWithStoredValues() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true)
        item.resumePositionTicks = 12_345
        item.isPlayed = true
        item.playedPercentage = 100
        store.insert(item)

        var capturedPath: String?
        struct DecodedBody: Decodable { let PlaybackPositionTicks: Int64; let Played: Bool }
        var decoded: DecodedBody?
        MockURLProtocol.requestHandler = { request in
            capturedPath = request.url?.path
            decoded = try? JSONDecoder().decode(DecodedBody.self, from: request.capturedHTTPBody ?? Data())
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)

        XCTAssertEqual(capturedPath, "/Users/user-1/Items/item-1/UserData")
        XCTAssertEqual(decoded?.PlaybackPositionTicks, 12_345)
        XCTAssertEqual(decoded?.Played, true)
    }

    /// Without an explicit `LastPlayedDate`, Jellyfin stamps its own value
    /// as the moment it *receives* the sync request, not when the item was
    /// actually watched offline (possibly hours/days earlier) — confirmed
    /// live as the cause of a downloaded episode ranking lower in Continue
    /// Watching than expected after reconnecting.
    func test_syncIfNeeded_sendsLastPlayedDateFromDownloadedItem() async throws {
        let store = DownloadTestHelpers.makeInMemoryStore()
        let item = DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true)
        let watchedAt = Date(timeIntervalSince1970: 1_700_000_000) // an arbitrary moment well before "now"
        item.lastPlayedAt = watchedAt
        store.insert(item)

        struct DecodedBody: Decodable { let LastPlayedDate: Date }
        var decoded: DecodedBody?
        MockURLProtocol.requestHandler = { request in
            // A plain decoder, not `JellyfinJSON.decoder` — that applies a
            // PascalCase→camelCase key transform on decode, which would
            // look for a `lastPlayedDate` key instead of matching
            // `DecodedBody`'s (deliberately PascalCase, mirroring the raw
            // wire JSON) `LastPlayedDate` property; same convention
            // `JellyfinAPIClientTests`' own decoded-body structs already
            // use. `.iso8601` matches `JellyfinJSON.encoder`'s own
            // `dateEncodingStrategy`, which is what actually produced this
            // body.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoded = try? decoder.decode(DecodedBody.self, from: request.capturedHTTPBody ?? Data())
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)

        let sentDate = try XCTUnwrap(decoded?.LastPlayedDate)
        XCTAssertEqual(sentDate.timeIntervalSince1970, watchedAt.timeIntervalSince1970, accuracy: 1)
    }

    /// A row with no recorded watch moment (shouldn't happen in practice —
    /// `PlayerViewModel.writeOfflineProgress` always sets it before marking
    /// `pendingSync` — but the field is optional) simply omits the key
    /// rather than sending a bogus value.
    func test_syncIfNeeded_noLastPlayedAt_omitsTheField() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))

        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.capturedHTTPBody
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)

        let json = try? JSONSerialization.jsonObject(with: capturedBody ?? Data())
        let dict = json as? [String: Any]
        XCTAssertNil(dict?["LastPlayedDate"])
    }

    /// The core new behavior: a row kept alive only to carry a pending
    /// sync write is removed outright once that sync succeeds — not just
    /// have `pendingSync` cleared.
    func test_syncIfNeeded_markedForDeletionRow_isRemovedAfterSuccessfulSync() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true, markedForDeletion: true))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)

        XCTAssertNil(store.item(itemID: "item-1"))
    }

    func test_syncIfNeeded_notMarkedForDeletion_rowSurvivesWithSyncCleared() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true, markedForDeletion: false))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)

        let row = store.item(itemID: "item-1")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.pendingSync, false)
    }

    func test_syncIfNeeded_failure_leavesRowPendingForNextTrigger() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)

        XCTAssertEqual(store.item(itemID: "item-1")?.pendingSync, true)
    }

    func test_syncIfNeeded_noPendingRows_doesNothing() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: false))
        MockURLProtocol.requestHandler = { _ in XCTFail("should not make a network call"); throw URLError(.badURL) }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)
    }

    // MARK: overlapping-call guard (2026-08-20 branch review) — rapid
    // foreground/background cycling used to fire overlapping calls, each
    // independently re-sending the same pending row's `updateUserData`
    // POST before an earlier in-flight call had a chance to clear it.

    /// Both calls run truly concurrently via `async let`; MainActor's
    /// serial execution means whichever starts first claims the in-flight
    /// guard before the other's own guard check runs, since neither call
    /// awaits anything before that check.
    func test_syncIfNeeded_overlappingCalls_secondCallIsANoOp() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }
        let client = makeClient()

        async let first: Void = DownloadSyncManager.syncIfNeeded(client: client, store: store)
        async let second: Void = DownloadSyncManager.syncIfNeeded(client: client, store: store)
        _ = await (first, second)

        XCTAssertEqual(requestCount, 1, "the overlapping second call must not re-send the same sync")
        XCTAssertEqual(store.item(itemID: "item-1")?.pendingSync, false)
    }

    /// The flip side: once the first call has actually finished (not just
    /// started), a later call must run for real — the guard only blocks
    /// truly *overlapping* calls, not sequential ones.
    func test_syncIfNeeded_sequentialCalls_bothRun() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }
        let client = makeClient()

        await DownloadSyncManager.syncIfNeeded(client: client, store: store)
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-2", pendingSync: true))
        await DownloadSyncManager.syncIfNeeded(client: client, store: store)

        XCTAssertEqual(requestCount, 2)
    }

    func test_syncIfNeeded_multiplePendingRows_syncsEachIndependently() async {
        let store = DownloadTestHelpers.makeInMemoryStore()
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-1", pendingSync: true))
        store.insert(DownloadTestHelpers.makeItem(itemID: "item-2", pendingSync: true))
        var requestedPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            if let path = request.url?.path { requestedPaths.append(path) }
            return MockURLProtocol.jsonResponse(for: request, status: 204, body: Data())
        }

        await DownloadSyncManager.syncIfNeeded(client: makeClient(), store: store)

        XCTAssertEqual(Set(requestedPaths), ["/Users/user-1/Items/item-1/UserData", "/Users/user-1/Items/item-2/UserData"])
        XCTAssertEqual(store.item(itemID: "item-1")?.pendingSync, false)
        XCTAssertEqual(store.item(itemID: "item-2")?.pendingSync, false)
    }
}
