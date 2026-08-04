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
}
