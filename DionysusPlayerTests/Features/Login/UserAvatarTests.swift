import XCTest
@testable import Dionysus

/// `UserAvatar` is the sign-in avatar on both iOS and Apple TV: the user's
/// Jellyfin profile picture over a monogram. The picture is fetched only when
/// the server says one exists, from the public user-image route.
final class UserAvatarTests: XCTestCase {
    private let server = URL(string: "https://jellyfin.example.com")!

    func test_imageURL_usesTheUserImageRouteWithTagAndWidth() throws {
        let user = UserDto(id: "user-1", name: "Ada", primaryImageTag: "tag-1")
        let url = try XCTUnwrap(UserAvatar.imageURL(for: user, serverURL: server, size: 200))
        XCTAssertEqual(url.path, "/Users/user-1/Images/Primary")
        let query = URLRequest(url: url).queryDictionary
        XCTAssertEqual(query["tag"], "tag-1")
        XCTAssertEqual(query["maxWidth"], "600")
    }

    /// No tag means the user never set a picture: the monogram stays, and
    /// nothing is requested.
    func test_imageURL_isNilWithoutATag() {
        let user = UserDto(id: "user-1", name: "Ada", primaryImageTag: nil)
        XCTAssertNil(UserAvatar.imageURL(for: user, serverURL: server, size: 200))
    }

    func test_imageURL_isNilWithoutAServer() {
        let user = UserDto(id: "user-1", name: "Ada", primaryImageTag: "tag-1")
        XCTAssertNil(UserAvatar.imageURL(for: user, serverURL: nil, size: 200))
    }
}
