import XCTest
@testable import Dionysus

/// `ServerConfiguration.parse` is the first thing a user's typing hits
/// during server setup, and it has to cope with whatever shorthand they
/// type (bare host, host:port, or a full URL) — worth pinning down exactly
/// since it's easy to accidentally regress one form while fixing another.
final class ServerConfigurationTests: XCTestCase {
    func test_bareHost_usesPreferredScheme() {
        let httpsConfig = ServerConfiguration.parse(rawAddress: "jellyfin.example.com", preferHTTPS: true)
        XCTAssertEqual(httpsConfig?.baseURL.absoluteString, "https://jellyfin.example.com")
        XCTAssertEqual(httpsConfig?.name, "jellyfin.example.com")

        let httpConfig = ServerConfiguration.parse(rawAddress: "jellyfin.example.com", preferHTTPS: false)
        XCTAssertEqual(httpConfig?.baseURL.absoluteString, "http://jellyfin.example.com")
    }

    func test_hostAndPort_isPreserved() {
        let config = ServerConfiguration.parse(rawAddress: "192.168.1.50:8096", preferHTTPS: false)
        XCTAssertEqual(config?.baseURL.absoluteString, "http://192.168.1.50:8096")
        XCTAssertEqual(config?.name, "192.168.1.50")
    }

    func test_fullyQualifiedURL_ignoresPreferHTTPS() {
        let config = ServerConfiguration.parse(rawAddress: "http://jellyfin.example.com", preferHTTPS: true)
        XCTAssertEqual(config?.baseURL.absoluteString, "http://jellyfin.example.com")
    }

    func test_trimsWhitespace() {
        let config = ServerConfiguration.parse(rawAddress: "  jellyfin.example.com  ", preferHTTPS: true)
        XCTAssertEqual(config?.name, "jellyfin.example.com")
    }

    func test_emptyOrWhitespaceOnly_returnsNil() {
        XCTAssertNil(ServerConfiguration.parse(rawAddress: "", preferHTTPS: true))
        XCTAssertNil(ServerConfiguration.parse(rawAddress: "   ", preferHTTPS: true))
    }

    func test_noHost_returnsNil() {
        XCTAssertNil(ServerConfiguration.parse(rawAddress: "https://", preferHTTPS: true))
    }

    func test_id_matchesBaseURLAbsoluteString() {
        let config = ServerConfiguration.parse(rawAddress: "jellyfin.example.com", preferHTTPS: true)!
        XCTAssertEqual(config.id, config.baseURL.absoluteString)
    }

    // MARK: explicitScheme

    func test_explicitScheme_bareHostOrHostAndPort_isNil() {
        XCTAssertNil(ServerConfiguration.explicitScheme(in: "jellyfin.example.com"))
        XCTAssertNil(ServerConfiguration.explicitScheme(in: "192.168.1.50:8096"))
    }

    func test_explicitScheme_fullyQualifiedURL_isLowercasedScheme() {
        XCTAssertEqual(ServerConfiguration.explicitScheme(in: "http://jellyfin.example.com"), "http")
        XCTAssertEqual(ServerConfiguration.explicitScheme(in: "https://jellyfin.example.com"), "https")
        XCTAssertEqual(ServerConfiguration.explicitScheme(in: "HTTPS://jellyfin.example.com"), "https")
    }

    func test_explicitScheme_trimsWhitespaceAndEmpty() {
        XCTAssertEqual(ServerConfiguration.explicitScheme(in: "  https://jellyfin.example.com  "), "https")
        XCTAssertNil(ServerConfiguration.explicitScheme(in: ""))
    }

    // MARK: correctingScheme

    func test_correctingScheme_landedOnDifferentScheme_rewritesSchemeOnly() {
        let config = ServerConfiguration.parse(rawAddress: "http://jellyfin.example.com:8096/path", preferHTTPS: false)!

        let corrected = config.correctingScheme(usingLandedURL: URL(string: "https://jellyfin.example.com:8096/path/System/Info/Public"))

        XCTAssertEqual(corrected.baseURL.absoluteString, "https://jellyfin.example.com:8096/path")
    }

    func test_correctingScheme_landedOnSameScheme_isUnchanged() {
        let config = ServerConfiguration.parse(rawAddress: "https://jellyfin.example.com", preferHTTPS: true)!

        let corrected = config.correctingScheme(usingLandedURL: URL(string: "https://jellyfin.example.com/System/Info/Public"))

        XCTAssertEqual(corrected, config)
    }

    func test_correctingScheme_nilLandedURL_isUnchanged() {
        let config = ServerConfiguration.parse(rawAddress: "jellyfin.example.com", preferHTTPS: true)!

        XCTAssertEqual(config.correctingScheme(usingLandedURL: nil), config)
    }
}
