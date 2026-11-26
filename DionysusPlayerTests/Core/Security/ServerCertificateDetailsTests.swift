import CryptoKit
import Foundation
import Security
import XCTest
@testable import Dionysus

/// `ServerCertificateDetails` classifies a refused certificate for the setup
/// offer (#466), against the real fixture certificates (`TLSFixtures`).
final class ServerCertificateDetailsTests: XCTestCase {
    /// Inside the CA-issued leaves' 800-day window; see
    /// `ServerTrustPolicyTests.nameLeafVerifyDate`.
    private var nameLeafVerifyDate: Date { ServerTrustPolicyTests.nameLeafVerifyDate }

    private func nameLeafTrust(anchors: [String]) -> SecTrust {
        let trust = TLSFixtures.trust(leaf: "nameLeaf", anchors: anchors, host: "192.168.1.50")
        SecTrustSetVerifyDate(trust, nameLeafVerifyDate as CFDate)
        return trust
    }

    func testNameMismatchListsTheNamesItIsValidFor() throws {
        let details = try XCTUnwrap(ServerCertificateDetails(trust: nameLeafTrust(anchors: ["testCA"])))

        XCTAssertEqual(details.kind, .nameMismatch(validFor: ["media.dionysus.test", "*.wild.dionysus.test"]))
        XCTAssertEqual(details.trust, .names(["media.dionysus.test", "*.wild.dionysus.test"]))
        XCTAssertEqual(details.subject, "media.dionysus.test")
        XCTAssertEqual(details.issuer, "Dionysus Test CA")
        XCTAssertEqual(details.dnsNames, ["media.dionysus.test", "*.wild.dionysus.test"])
        XCTAssertNotNil(details.notAfter)
    }

    func testSelfSignedIsPinned() throws {
        let trust = TLSFixtures.trust(leaf: "selfSignedA", anchors: [], host: "192.168.1.50")
        let details = try XCTUnwrap(ServerCertificateDetails(trust: trust))

        XCTAssertEqual(details.kind, .selfSigned)
        XCTAssertEqual(details.trust, .certificate(TLSFixtures.der("selfSignedA")))
        XCTAssertEqual(details.subject, "selfsigned-a.dionysus.test")
        XCTAssertNil(details.issuer, "A one-certificate chain has no issuer to show")
        XCTAssertEqual(details.leaf, TLSFixtures.der("selfSignedA"))
    }

    func testUnknownIssuerIsPinned() throws {
        let details = try XCTUnwrap(ServerCertificateDetails(trust: nameLeafTrust(anchors: [])))

        XCTAssertEqual(details.kind, .untrustedIssuer)
        XCTAssertEqual(details.trust, .certificate(TLSFixtures.der("nameLeaf")))
    }

    func testACertificateWithoutSubjectAltNamesHasNoDNSNames() throws {
        let trust = TLSFixtures.trust(leaf: "testCA", anchors: [], host: nil)
        let details = try XCTUnwrap(ServerCertificateDetails(trust: trust))

        XCTAssertEqual(details.dnsNames, [])
        XCTAssertEqual(details.kind, .selfSigned)
        XCTAssertEqual(details.subject, "Dionysus Test CA")
    }

    func testMalformedDERGivesNoDNSNames() {
        let leaf = TLSFixtures.der("nameLeaf")
        XCTAssertEqual(ServerCertificateDetails.subjectAltDNSNames(der: Data()), [])
        XCTAssertEqual(ServerCertificateDetails.subjectAltDNSNames(der: Data([0x30, 0x82, 0xFF, 0xFF, 0x01])), [])
        XCTAssertEqual(ServerCertificateDetails.subjectAltDNSNames(der: Data("not a certificate".utf8)), [])
        XCTAssertEqual(ServerCertificateDetails.subjectAltDNSNames(der: leaf.prefix(leaf.count / 2)), [])
        XCTAssertEqual(ServerCertificateDetails.subjectAltDNSNames(der: Data([0x05, 0x00])), [], "A primitive root")
        XCTAssertEqual(ServerCertificateDetails.subjectAltDNSNames(der: leaf), ["media.dionysus.test", "*.wild.dionysus.test"])
    }

    /// A hand-built certificate shape (only what the parser walks): a
    /// critical SAN mixing an IP address with DNS names, some carrying a NUL,
    /// a newline, a space or a byte past ASCII. Only the clean names survive.
    func testCraftedSubjectAltNamesKeepOnlyPrintableDNSNames() {
        func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            precondition(content.count < 128)
            return [tag, UInt8(content.count)] + content
        }
        func dns(_ bytes: [UInt8]) -> [UInt8] { tlv(0x82, bytes) }
        let generalNames = tlv(0x30,
            dns(Array("good.test".utf8))
            + tlv(0x87, [192, 168, 0, 1])
            + dns(Array("evil.test".utf8) + [0x00] + Array("x".utf8))
            + dns(Array("two\nlines".utf8))
            + dns(Array("has space".utf8))
            + dns([0x63, 0xC3, 0xA9])
            + dns([])
            + dns(Array("*.also-good.test".utf8)))
        let sanExtension = tlv(0x30,
            [0x06, 0x03, 0x55, 0x1D, 0x11]      // 2.5.29.17
            + [0x01, 0x01, 0xFF]                // critical
            + tlv(0x04, generalNames))
        let tbs = tlv(0x30, [0x02, 0x01, 0x01] + tlv(0xA3, tlv(0x30, sanExtension)))
        let certificate = tlv(0x30, tbs)

        XCTAssertEqual(ServerCertificateDetails.subjectAltDNSNames(der: Data(certificate)), ["good.test", "*.also-good.test"])
    }

    func testFingerprintIsTheLeafsSHA256() throws {
        let trust = TLSFixtures.trust(leaf: "selfSignedA", anchors: [], host: "192.168.1.50")
        let details = try XCTUnwrap(ServerCertificateDetails(trust: trust))

        XCTAssertEqual(details.fingerprint, Data(SHA256.hash(data: TLSFixtures.der("selfSignedA"))))
        XCTAssertEqual(details.fingerprint, details.trust.fingerprint)
    }
}
