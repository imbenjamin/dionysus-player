import TVServices
import XCTest
@testable import Dionysus

/// What the Top Shelf extension hands tvOS (TQ-25): the whole load over the
/// stub server, and how each entry becomes a carousel item. The loader, the
/// builder and the art each have tests of their own; these pin the provider's
/// part, which ran under no test.
final class TopShelfCarouselTests: XCTestCase {
    private let session = TopShelfSession(
        serverURL: URL(string: "http://jf.local")!, serverID: "http://jf.local", userID: "u1",
        accessToken: "tok", deviceID: "dev", deviceName: "Bedroom"
    )
    private var directory: URL!
    private var store: TopShelfArtworkStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = TopShelfArtworkStore(directory: directory)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        DeviceIdentity.adopt(deviceID: nil, deviceName: nil)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private static let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36)).pngData { context in
        UIColor.gray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
    }

    /// A server with one resumed movie (backdrop and logo) and nothing else;
    /// `images` answers every image request.
    private func serveOneResumedMovie(images: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/Images/") { return images(request) }
            if path.hasSuffix("/Items/Latest") { return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]()) }
            var movie = BaseItemDto(id: "m1", name: "Arrival", type: .movie)
            movie.backdropImageTags = ["b"]
            movie.imageTags = ["Logo": "l"]
            let items = path.hasSuffix("/Items/Resume") ? [movie] : []
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
    }

    private func carousel(store: TopShelfArtworkStore?) async throws -> TVTopShelfCarouselContent {
        let content = await TopShelfCarousel.content(session: session, urlSession: MockURLProtocol.makeSession(), store: store)
        return try XCTUnwrap(content as? TVTopShelfCarouselContent, "A carousel, not \(String(describing: content))")
    }

    // MARK: The whole load

    func test_noSession_isTheStaticImage_andAsksNothing() async {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return MockURLProtocol.jsonResponse(for: request, body: Data())
        }
        let content = await TopShelfCarousel.content(session: nil, urlSession: MockURLProtocol.makeSession(), store: store)
        XCTAssertNil(content)
        XCTAssertEqual(requests, 0)
    }

    /// A revoked token fails every source: the static image, not an empty
    /// carousel (which draws a blank shelf).
    func test_aRefusedToken_isTheStaticImage() async {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
        }
        let content = await TopShelfCarousel.content(session: session, urlSession: MockURLProtocol.makeSession(), store: store)
        XCTAssertNil(content)
    }

    func test_rows_becomeAnActionsCarousel_withTheComposedArt_andTheDeepLinks() async throws {
        serveOneResumedMovie { MockURLProtocol.jsonResponse(for: $0, body: Self.png) }
        let carousel = try await carousel(store: store)
        XCTAssertEqual(carousel.style, .actions, "tvOS 27 draws no text over either style; actions gives Play and More Info")
        XCTAssertEqual(carousel.items.map(\.identifier), ["m1"])
        let item = try XCTUnwrap(carousel.items.first)
        XCTAssertEqual(item.title, "Arrival")
        let art = try XCTUnwrap(item.imageURL(for: .screenScale2x))
        XCTAssertTrue(art.isFileURL, "The composited art, not the plain backdrop: \(art)")
        XCTAssertTrue(art.path.hasPrefix(directory.path))
        XCTAssertNil(item.imageURL(for: .screenScale1x), "2x only: setting both doubles the system's fetches")
        XCTAssertEqual(item.displayAction.flatMap { TVDeepLink(url: $0.url) }, TVDeepLink(action: .item, itemID: "m1", serverID: "http://jf.local"))
        XCTAssertEqual(item.playAction.flatMap { TVDeepLink(url: $0.url) }, TVDeepLink(action: .play, itemID: "m1", serverID: "http://jf.local"))
    }

    /// Art that can't be drawn leaves the plain backdrop, never an empty frame.
    func test_artThatFails_leavesThePlainBackdrop() async throws {
        serveOneResumedMovie { MockURLProtocol.jsonResponse(for: $0, status: 404, body: Data()) }
        let items = try await carousel(store: store).items
        let item = try XCTUnwrap(items.first)
        let art = try XCTUnwrap(item.imageURL(for: .screenScale2x))
        XCTAssertFalse(art.isFileURL)
        XCTAssertTrue(art.path.contains("/Items/m1/Images/Backdrop"), "The backdrop: \(art)")
    }

    /// No App Group (the store is `nil`): the plain backdrop, and no image is
    /// fetched, since nothing would be drawn.
    func test_withoutTheAppGroup_thePlainBackdrop_fetchingNoImage() async throws {
        var imageRequests = 0
        serveOneResumedMovie { request in
            imageRequests += 1
            return MockURLProtocol.jsonResponse(for: request, body: Self.png)
        }
        let items = try await carousel(store: nil).items
        let item = try XCTUnwrap(items.first)
        XCTAssertFalse(try XCTUnwrap(item.imageURL(for: .screenScale2x)).isFileURL)
        XCTAssertEqual(imageRequests, 0)
    }

    // MARK: One item

    private func entry(cast: [String] = ["Amy Adams", "Jeremy Renner"], options: Set<TopShelfEntry.MediaOption> = []) -> TopShelfEntry {
        TopShelfEntry(
            id: "m1", title: "Arrival", contextTitle: "Continue Watching", summary: "Linguists meet visitors.",
            genre: "Science Fiction", duration: 6960, releaseYear: 2016, cast: cast, mediaOptions: options,
            image1x: URL(string: "http://jf.local/b1")!, image2x: URL(string: "http://jf.local/b2")!,
            displayURL: URL(string: "dionysus://item/m1")!, playURL: URL(string: "dionysus://play/m1")!,
            logoURL: nil, remainingText: nil, artworkKey: "k"
        )
    }

    func test_item_carriesTheEntrysDetails() throws {
        let item = TopShelfCarousel.item(entry(), art: nil)
        XCTAssertEqual(item.identifier, "m1")
        XCTAssertEqual(item.contextTitle, "Continue Watching")
        XCTAssertEqual(item.summary, "Linguists meet visitors.")
        XCTAssertEqual(item.genre, "Science Fiction")
        XCTAssertEqual(item.duration, 6960)
        let created = try XCTUnwrap(item.creationDate)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: created), 2016)
        XCTAssertEqual(item.namedAttributes.map(\.values), [["Amy Adams", "Jeremy Renner"]])
        XCTAssertEqual(item.imageURL(for: .screenScale2x)?.absoluteString, "http://jf.local/b2", "The 2x backdrop when no art was drawn")
        XCTAssertEqual(item.displayAction?.url.absoluteString, "dionysus://item/m1")
        XCTAssertEqual(item.playAction?.url.absoluteString, "dionysus://play/m1")
    }

    func test_item_withoutCast_hasNoStarringLine() {
        XCTAssertTrue(TopShelfCarousel.item(entry(cast: []), art: nil).namedAttributes.isEmpty)
    }

    func test_item_prefersTheComposedArt() {
        let art = URL(fileURLWithPath: "/tmp/k.jpg")
        XCTAssertEqual(TopShelfCarousel.item(entry(), art: art).imageURL(for: .screenScale2x), art)
    }

    func test_noEntries_isTheStaticImage() {
        XCTAssertNil(TopShelfCarousel.content([], art: [:]))
    }

    func test_items_keepTheEntriesOrder() throws {
        var second = entry()
        second.id = "e2"
        let content = try XCTUnwrap(TopShelfCarousel.content([entry(), second], art: [:]))
        XCTAssertEqual(content.items.map(\.identifier), ["m1", "e2"])
    }

    // MARK: Media options

    /// One resolution and one colour space each, the better one winning.
    func test_mediaOptions_takeTheBetterResolutionAndColourSpace() {
        XCTAssertEqual(
            TopShelfCarousel.mediaOptions([.hd, .uhd4K, .hdr, .dolbyVision]),
            [.videoResolution4K, .videoColorSpaceDolbyVision])
        XCTAssertEqual(TopShelfCarousel.mediaOptions([.hd, .hdr]), [.videoResolutionHD, .videoColorSpaceHDR])
    }

    func test_mediaOptions_mapAtmosAndCaptions() {
        XCTAssertEqual(
            TopShelfCarousel.mediaOptions([.atmos, .closedCaptions]),
            [.audioDolbyAtmos, .audioTranscriptionClosedCaptioning])
        XCTAssertEqual(TopShelfCarousel.mediaOptions([]), [])
    }

    func test_item_carriesItsMediaOptions() {
        XCTAssertEqual(
            TopShelfCarousel.item(entry(options: [.uhd4K, .dolbyVision, .atmos]), art: nil).mediaOptions,
            [.videoResolution4K, .videoColorSpaceDolbyVision, .audioDolbyAtmos])
    }
}
