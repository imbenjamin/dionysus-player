import XCTest
@testable import Dionysus

final class ImageURLBuilderTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    func test_url_includesTagMaxWidthAndApiKeyWhenProvided() throws {
        let builder = ImageURLBuilder(baseURL: baseURL, accessToken: "tok")
        let url = try XCTUnwrap(builder.url(itemID: "item-1", imageType: "Primary", tag: "abc", maxWidth: 500))

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/Items/item-1/Images/Primary")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["tag"], "abc")
        XCTAssertEqual(query["maxWidth"], "500")
        XCTAssertEqual(query["ApiKey"], "tok")
    }

    func test_url_omitsApiKeyWhenNoAccessToken() throws {
        let builder = ImageURLBuilder(baseURL: baseURL, accessToken: nil)
        let url = try XCTUnwrap(builder.url(itemID: "item-1"))
        XCTAssertFalse(url.absoluteString.contains("ApiKey"))
    }

    func test_url_hasNoQueryStringWhenNothingToAdd() throws {
        let builder = ImageURLBuilder(baseURL: baseURL, accessToken: nil)
        let url = try XCTUnwrap(builder.url(itemID: "item-1"))
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    func test_url_defaultsImageTypeToPrimary() throws {
        let builder = ImageURLBuilder(baseURL: baseURL, accessToken: nil)
        let url = try XCTUnwrap(builder.url(itemID: "item-1"))
        XCTAssertTrue(url.absoluteString.contains("/Images/Primary"))
    }

    func test_userImageURL_usesUsersEndpointNotItems() throws {
        let builder = ImageURLBuilder(baseURL: baseURL, accessToken: "tok")
        let url = try XCTUnwrap(builder.userImageURL(userID: "user-1", tag: "xyz"))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/Users/user-1/Images/Primary")
    }

    func test_trickplayTileURL_buildsWidthAndIndexedPathWithApiKey() throws {
        let builder = ImageURLBuilder(baseURL: baseURL, accessToken: "tok")
        let url = try XCTUnwrap(builder.trickplayTileURL(itemID: "item-1", width: 320, sheetIndex: 3))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/Videos/item-1/Trickplay/320/3.jpg")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["ApiKey"], "tok")
    }

    func test_trickplayTileURL_omitsApiKeyWhenNoAccessToken() throws {
        let builder = ImageURLBuilder(baseURL: baseURL, accessToken: nil)
        let url = try XCTUnwrap(builder.trickplayTileURL(itemID: "item-1", width: 320, sheetIndex: 0))
        XCTAssertFalse(url.absoluteString.contains("ApiKey"))
    }
}
