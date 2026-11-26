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

    // MARK: Certificate trust (#466)

    func testDecodesAConfigurationSavedBeforeCertificateTrust() throws {
        let json = Data(#"{"name":"S","baseURL":"https://h:8920"}"#.utf8)
        let config = try JSONDecoder().decode(ServerConfiguration.self, from: json)
        XCTAssertNil(config.certificateTrust)
    }

    func testRoundTripsBothTrustKinds() throws {
        for trust in [ServerCertificateTrust.names(["media.lan", "10.0.0.2"]), .certificate(Data([1, 2, 3]))] {
            var config = ServerConfiguration(name: "S", baseURL: URL(string: "https://h:8920")!)
            config.certificateTrust = trust
            let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(decoded.certificateTrust, trust)
        }
    }

    func testFingerprintTextIsColonSeparatedUppercaseHex() {
        XCTAssertEqual(ServerCertificateTrust.fingerprintText(Data([0x4f, 0xa2, 0x0c])), "4F:A2:0C")
    }

    func testFingerprintIsTheSHA256OfTheCertificate() {
        XCTAssertNil(ServerCertificateTrust.names(["h"]).fingerprint)
        let fingerprint = ServerCertificateTrust.certificate(Data("abc".utf8)).fingerprint
        XCTAssertEqual(fingerprint?.map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testOriginDefaultsTheSchemePort() throws {
        XCTAssertEqual(try XCTUnwrap(ServerOrigin(url: URL(string: "https://h")!)).port, 443)
        XCTAssertEqual(try XCTUnwrap(ServerOrigin(url: URL(string: "http://h")!)).port, 80)
    }

    func testOriginLowercasesAndUnbracketsTheHost() throws {
        let named = try XCTUnwrap(ServerOrigin(url: URL(string: "https://MEDIA.lan:8920")!))
        XCTAssertEqual(named, ServerOrigin(host: "media.lan", port: 8920))
        let v6 = try XCTUnwrap(ServerOrigin(url: URL(string: "https://[fe80::1]:8920")!))
        XCTAssertEqual(v6.host, "fe80::1")
    }

    /// A challenge's origin is built from `URLProtectionSpace.host`, not a URL.
    func testOriginFromAHostAndPortIsNormalisedTheSameWay() {
        XCTAssertEqual(ServerOrigin(host: "MEDIA.lan", port: 8920).host, "media.lan")
        XCTAssertEqual(ServerOrigin(host: "[FE80::1]", port: 8920).host, "fe80::1")
    }

    func testConfigurationOriginFollowsItsBaseURL() {
        let config = ServerConfiguration(name: "S", baseURL: URL(string: "https://Media.lan:8920")!)
        XCTAssertEqual(config.origin, ServerOrigin(host: "media.lan", port: 8920))
    }
}
