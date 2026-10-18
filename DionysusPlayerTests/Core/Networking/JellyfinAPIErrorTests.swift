import XCTest
@testable import Dionysus

/// `errorDescription` is the text users actually see (surfaced through
/// every ViewModel's `.failed(message)` state), so its exact formatting is
/// worth pinning down directly rather than only ever seeing it as a byproduct
/// of other tests catching the error type.
final class JellyfinAPIErrorTests: XCTestCase {
    func test_invalidServerAddress_message() {
        XCTAssertEqual(JellyfinAPIError.invalidServerAddress.errorDescription, "That doesn't look like a valid server address.")
    }

    func test_invalidResponse_message() {
        XCTAssertEqual(JellyfinAPIError.invalidResponse.errorDescription, "The server sent an unexpected response.")
    }

    /// A server or proxy can answer an error with a whole HTML page, which was
    /// shown as raw markup: the body never reaches the message.
    func test_http_showsTheStatus_neverTheBody() {
        let error = JellyfinAPIError.http(status: 404, message: "<html><body><h1>404 Not Found</h1></body></html>")
        XCTAssertEqual(error.errorDescription, "Something went wrong (HTTP 404).")
    }

    func test_http_withoutMessage_showsTheStatus() {
        let error = JellyfinAPIError.http(status: 500, message: nil)
        XCTAssertEqual(error.errorDescription, "Something went wrong (HTTP 500).")
    }

    func test_isNotFound_onlyFor404() {
        XCTAssertTrue(JellyfinAPIError.http(status: 404, message: nil).isNotFound)
        XCTAssertFalse(JellyfinAPIError.http(status: 500, message: nil).isNotFound)
        XCTAssertFalse(JellyfinAPIError.notAuthenticated.isNotFound)
    }

    func test_decoding_hasAGenericUserFacingMessageRegardlessOfUnderlyingError() {
        struct DummyError: Error {}
        XCTAssertEqual(JellyfinAPIError.decoding(DummyError()).errorDescription, "Couldn't understand the server's response.")
    }

    func test_notAuthenticated_message() {
        XCTAssertEqual(JellyfinAPIError.notAuthenticated.errorDescription, "You need to sign in again.")
    }
}
