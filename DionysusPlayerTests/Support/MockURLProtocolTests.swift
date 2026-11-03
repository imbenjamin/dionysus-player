import XCTest
@testable import Dionysus

/// Pins `MockURLProtocol`'s per-test isolation: a request from a session made
/// before `reset()` (a leftover from an earlier test) must never reach the
/// current test's handler.
final class MockURLProtocolTests: XCTestCase {
    private let url = URL(string: "http://example.test/ping")!

    /// The URL loading system hands a protocol's error back as an `NSError`
    /// in the error type's own domain, so match on that.
    private func isStaleRequest(_ error: Error) -> Bool {
        (error as NSError).domain.hasSuffix("StaleRequest")
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func test_aCurrentSession_reachesTheHandler() async throws {
        var seenHeader: String?
        MockURLProtocol.requestHandler = { request in
            seenHeader = request.value(forHTTPHeaderField: MockURLProtocol.generationHeader)
            return MockURLProtocol.jsonResponse(for: request, body: Data("{}".utf8))
        }
        let (_, response) = try await MockURLProtocol.makeSession().data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(seenHeader, String(MockURLProtocol.generation))
        XCTAssertNotNil(MockURLProtocol.lastRequest)
    }

    func test_aSessionFromBeforeReset_neverReachesTheCurrentHandler() async {
        let oldSession = MockURLProtocol.makeSession()
        MockURLProtocol.reset()
        MockURLProtocol.requestHandler = { _ in
            XCTFail("A stale session's request reached the current handler")
            throw MockURLProtocol.UnhandledRequest()
        }
        do {
            _ = try await oldSession.data(from: url)
            XCTFail("Expected StaleRequest")
        } catch {
            XCTAssertTrue(isStaleRequest(error), "got \(error)")
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func test_anUnmarkedRequest_isRefusedByDefault() async {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("An unmarked request reached the handler")
            throw MockURLProtocol.UnhandledRequest()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        do {
            _ = try await URLSession(configuration: configuration).data(from: url)
            XCTFail("Expected StaleRequest")
        } catch {
            XCTAssertTrue(isStaleRequest(error), "got \(error)")
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func test_anUnmarkedRequest_reachesTheHandlerWhenAccepted() async throws {
        MockURLProtocol.acceptsUnmarkedRequests = true
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, body: Data("{}".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let (_, response) = try await URLSession(configuration: configuration).data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func test_reset_clearsAcceptsUnmarkedRequests() {
        MockURLProtocol.acceptsUnmarkedRequests = true
        MockURLProtocol.reset()
        XCTAssertFalse(MockURLProtocol.acceptsUnmarkedRequests)
    }
}
