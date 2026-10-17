import XCTest
@testable import Dionysus

/// Fetching, drawing and caching the shelf's art (M6).
final class TopShelfArtworkComposerTests: XCTestCase {
    private var directory: URL!
    private var store: TopShelfArtworkStore!
    private let images = ImageURLBuilder(baseURL: URL(string: "http://jf.local")!)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = TopShelfArtworkStore(directory: directory)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func entries() -> [TopShelfEntry] {
        var dto = BaseItemDto(id: "m1", name: "Arrival", type: .movie)
        dto.backdropImageTags = ["b"]
        dto.imageTags = ["Logo": "l"]
        return TopShelfContentBuilder.entries(resume: [dto], nextUp: [], latest: [], images: images, serverID: "http://jf.local")
    }

    private static let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36)).pngData { context in
        UIColor.gray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
    }

    func test_composes_thenReusesTheCachedArt() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return MockURLProtocol.jsonResponse(for: request, body: Self.png)
        }
        let first = await TopShelfArtworkComposer.artwork(for: entries(), store: store, session: MockURLProtocol.makeSession())
        let url = try XCTUnwrap(first["m1"])
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(requests, 2, "The backdrop and the logo")

        let second = await TopShelfArtworkComposer.artwork(for: entries(), store: store, session: MockURLProtocol.makeSession())
        XCTAssertEqual(second["m1"], url)
        XCTAssertEqual(requests, 2, "Cached art fetches nothing")
    }

    func test_aBackdropThatFails_leavesTheItemToItsPlainArt() async {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 404, body: Data())
        }
        let art = await TopShelfArtworkComposer.artwork(for: entries(), store: store, session: MockURLProtocol.makeSession())
        XCTAssertNil(art["m1"])
    }

    func test_aLogoThatFails_drawsTheName() async throws {
        MockURLProtocol.requestHandler = { request in
            let isLogo = request.url?.path.contains("/Images/Logo") == true
            return MockURLProtocol.jsonResponse(for: request, status: isLogo ? 404 : 200, body: isLogo ? Data() : Self.png)
        }
        let art = await TopShelfArtworkComposer.artwork(for: entries(), store: store, session: MockURLProtocol.makeSession())
        XCTAssertNotNil(art["m1"])
    }

    /// A render that killed the extension (Bedroom, 2026-10-14) would kill
    /// every retry too and leave the shelf blank for good: an item whose last
    /// attempt never finished keeps its plain backdrop from then on.
    func test_anItemWhoseLastRenderNeverFinished_isLeftPlain() async {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return MockURLProtocol.jsonResponse(for: request, body: Self.png)
        }
        let entry = entries()[0]
        store.markRendering(entry.artworkKey)
        let art = await TopShelfArtworkComposer.artwork(for: [entry], store: store, session: MockURLProtocol.makeSession())
        XCTAssertNil(art[entry.id])
        XCTAssertEqual(requests, 0, "Nothing is fetched for it")
    }

    /// After a load that died, the next one draws nothing new and answers at
    /// once (cached art, plain backdrops), so a death costs one blank load,
    /// not one per item (Bedroom, 1920 wide, 2026-10-14).
    func test_afterALoadThatDied_drawsNothingNew() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return MockURLProtocol.jsonResponse(for: request, body: Self.png)
        }
        var arrival = BaseItemDto(id: "m1", name: "Arrival", type: .movie)
        arrival.backdropImageTags = ["b"]
        var heat = BaseItemDto(id: "m2", name: "Heat", type: .movie)
        heat.backdropImageTags = ["b2"]
        let both = TopShelfContentBuilder.entries(
            resume: [arrival, heat],
            nextUp: [], latest: [], images: images, serverID: "http://jf.local"
        )
        store.markRendering(both[0].artworkKey)
        let first = await TopShelfArtworkComposer.artwork(for: both, store: store, session: MockURLProtocol.makeSession())
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(requests, 0)

        let second = await TopShelfArtworkComposer.artwork(for: both, store: store, session: MockURLProtocol.makeSession())
        XCTAssertNil(second["m1"], "The item that died stays plain")
        XCTAssertNotNil(second["m2"], "The next load carries on with the rest")
    }

    func test_aFinishedRender_leavesNoMarker() async {
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, body: Self.png) }
        let entry = entries()[0]
        _ = await TopShelfArtworkComposer.artwork(for: [entry], store: store, session: MockURLProtocol.makeSession())
        XCTAssertFalse(store.isMarkedRendering(entry.artworkKey))
    }

    /// A load that found nothing (a server not answering as the TV wakes)
    /// leaves the drawn art for the next.
    func test_anEmptyLoad_keepsTheCachedArt() async throws {
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, body: Self.png) }
        let entry = entries()[0]
        _ = await TopShelfArtworkComposer.artwork(for: [entry], store: store, session: MockURLProtocol.makeSession())
        XCTAssertNotNil(store.existing(for: entry.artworkKey))

        _ = await TopShelfArtworkComposer.artwork(for: [], store: store, session: MockURLProtocol.makeSession())
        XCTAssertNotNil(store.existing(for: entry.artworkKey))
    }

    /// The app asks for a refresh on every return, so tvOS can start a load
    /// while one is drawing: the second waits, rather than taking the first's
    /// marker for a render that died.
    func test_overlappingLoads_neverMarkEachOthersRenderFailed() async throws {
        MockURLProtocol.requestHandler = { request in
            Thread.sleep(forTimeInterval: 0.2)
            return MockURLProtocol.jsonResponse(for: request, body: Self.png)
        }
        let entry = entries()[0], store = store!
        async let first = TopShelfArtworkComposer.artwork(for: [entry], store: store, session: MockURLProtocol.makeSession())
        // Started while the first is fetching its backdrop.
        async let second: [String: URL] = {
            try? await Task.sleep(for: .milliseconds(100))
            return await TopShelfArtworkComposer.artwork(for: [entry], store: store, session: MockURLProtocol.makeSession())
        }()
        let (a, b) = await (first, second)
        XCTAssertFalse(store.isFailed(entry.artworkKey))
        XCTAssertNotNil(a[entry.id])
        XCTAssertNotNil(b[entry.id])
    }

    func test_withoutAStore_composesNothing() async {
        let art = await TopShelfArtworkComposer.artwork(for: entries(), store: nil, session: MockURLProtocol.makeSession())
        XCTAssertTrue(art.isEmpty)
    }
}
