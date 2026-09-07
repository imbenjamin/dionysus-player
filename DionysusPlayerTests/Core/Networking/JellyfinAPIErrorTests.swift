import XCTest
@testable import Dionysus

/// `errorDescription` is the text users actually see (surfaced through
/// every ViewModel's `.failed(message)` state), so its exact formatting —
/// particularly the optional-message branch on `.http` — is worth pinning
/// down directly rather than only ever seeing it as a byproduct of other
/// tests catching the error type.
final class JellyfinAPIErrorTests: XCTestCase {
    func test_invalidServerAddress_message() {
        XCTAssertEqual(JellyfinAPIError.invalidServerAddress.errorDescription, "That doesn't look like a valid server address.")
    }

    func test_invalidResponse_message() {
        XCTAssertEqual(JellyfinAPIError.invalidResponse.errorDescription, "The server sent an unexpected response.")
    }

    func test_http_withMessage_includesStatusAndMessage() {
        let error = JellyfinAPIError.http(status: 404, message: "Not Found")
        XCTAssertEqual(error.errorDescription, "Server returned 404: Not Found.")
    }

    func test_http_withoutMessage_omitsTheColon() {
        let error = JellyfinAPIError.http(status: 500, message: nil)
        XCTAssertEqual(error.errorDescription, "Server returned 500.")
    }

    func test_decoding_hasAGenericUserFacingMessageRegardlessOfUnderlyingError() {
        struct DummyError: Error {}
        XCTAssertEqual(JellyfinAPIError.decoding(DummyError()).errorDescription, "Couldn't understand the server's response.")
    }

    func test_notAuthenticated_message() {
        XCTAssertEqual(JellyfinAPIError.notAuthenticated.errorDescription, "You need to sign in again.")
    }
}
