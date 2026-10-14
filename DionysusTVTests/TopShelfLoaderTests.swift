import XCTest
@testable import Dionysus

/// The extension's fetch (M6): nothing without the mirrored session or a
/// server answering; never a password sign-in (Review Focus 1).
final class TopShelfLoaderTests: XCTestCase {
    private let session = TopShelfSession(
        serverURL: URL(string: "http://jf.local")!, serverID: "http://jf.local", userID: "u1",
        accessToken: "tok", deviceID: "dev", deviceName: "Bedroom"
    )

    override func tearDown() {
        MockURLProtocol.reset()
        DeviceIdentity.adopt(deviceID: nil, deviceName: nil)
        super.tearDown()
    }

    func test_noSession_loadsNothing_andAsksNothing() async {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        let entries = await TopShelfLoader.load(session: nil, urlSession: MockURLProtocol.makeSession())
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(requests, 0)
    }

    func test_401_loadsNothing_withoutSigningIn() async {
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            return MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/AuthenticateByName") }, "The extension never signs in")
    }

    func test_success_buildsEntries_presentingTheAppsDeviceID() async {
        var headers: [String] = []
        MockURLProtocol.requestHandler = { request in
            headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let path = request.url?.path ?? ""
            if path.hasSuffix("/Items/Latest") { return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]()) }
            var movie = BaseItemDto(id: "m1", name: "Arrival", type: .movie)
            movie.backdropImageTags = ["t"]
            let items = path.hasSuffix("/Items/Resume") ? [movie] : []
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertEqual(entries.map(\.id), ["m1"])
        XCTAssertTrue(headers.allSatisfy { $0.contains("DeviceId=\"dev\"") }, "Every request carries the app's device id")
    }
}
