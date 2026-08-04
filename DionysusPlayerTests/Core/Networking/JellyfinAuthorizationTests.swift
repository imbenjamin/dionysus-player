import XCTest
@testable import Dionysus

final class JellyfinAuthorizationTests: XCTestCase {
    func test_headerValue_startsWithMediaBrowserAndIdentifiesTheClient() {
        let header = JellyfinAuthorization.headerValue(token: nil)
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains("Client=\"Dionysus\""))
        XCTAssertTrue(header.contains("Device=\""))
        XCTAssertTrue(header.contains("DeviceId=\""))
        XCTAssertTrue(header.contains("Version=\""))
    }

    func test_headerValue_omitsTokenWhenNil() {
        XCTAssertFalse(JellyfinAuthorization.headerValue(token: nil).contains("Token="))
    }

    func test_headerValue_omitsTokenWhenEmptyString() {
        XCTAssertFalse(JellyfinAuthorization.headerValue(token: "").contains("Token="))
    }

    func test_headerValue_includesTokenWhenPresent() {
        XCTAssertTrue(JellyfinAuthorization.headerValue(token: "secret-token").contains("Token=\"secret-token\""))
    }
}
