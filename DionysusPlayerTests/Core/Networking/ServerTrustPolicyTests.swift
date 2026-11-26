import Foundation
import Security
import XCTest
@testable import Dionysus

/// `ServerTrustPolicy.decide` answers every TLS server-trust challenge (#466),
/// so each row of its decision table is pinned here against real certificates
/// (`TLSFixtures`), never a stubbed evaluation.
final class ServerTrustPolicyTests: XCTestCase {
    private let lan = ServerOrigin(host: "192.168.1.50", port: 8920)

    /// The CA-issued leaves are valid for 800 days only (Apple refuses a
    /// server leaf valid for more than 825), so every trust that evaluates them
    /// is pinned to a date inside their window (generated 2026-11-23, valid to
    /// 2029-01-31) and the tests don't rot. Update it when regenerating.
    static let nameLeafVerifyDate = date(year: 2026, month: 12, day: 23)

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// A trust for a CA-issued fixture leaf, pinned to `nameLeafVerifyDate`.
    private func caIssuedTrust(_ leaf: String, host: String) -> SecTrust {
        let trust = TLSFixtures.trust(leaf: leaf, anchors: ["testCA"], host: host)
        SecTrustSetVerifyDate(trust, Self.nameLeafVerifyDate as CFDate)
        return trust
    }

    private func selfSignedTrust(_ leaf: String) -> SecTrust {
        TLSFixtures.trust(leaf: leaf, anchors: [], host: "192.168.1.50")
    }

    private func nameTrust(_ leaf: String) -> SecTrust {
        caIssuedTrust(leaf, host: "192.168.1.50")
    }

    func testAnotherOriginIsLeftToTheSystem() {
        let decision = ServerTrustPolicy.decide(
            trust: selfSignedTrust("selfSignedA"),
            origin: ServerOrigin(host: "192.168.1.50", port: 443),
            serverOrigin: lan,
            stored: .certificate(TLSFixtures.der("selfSignedA"))
        )
        XCTAssertEqual(decision, .systemDefault)
    }

    func testSchemeDefaultPortMatchesAnExplicit443() throws {
        let server = try XCTUnwrap(ServerOrigin(url: URL(string: "https://h")!))
        let decision = ServerTrustPolicy.decide(
            trust: TLSFixtures.trust(leaf: "selfSignedA", anchors: [], host: "h"),
            origin: ServerOrigin(host: "h", port: 443),
            serverOrigin: server,
            stored: .certificate(TLSFixtures.der("selfSignedA"))
        )
        XCTAssertEqual(decision, .accept)
    }

    func testHostCaseDoesNotMatter() throws {
        let server = try XCTUnwrap(ServerOrigin(url: URL(string: "https://Media.Example.test:8920")!))
        let decision = ServerTrustPolicy.decide(
            trust: TLSFixtures.trust(leaf: "selfSignedA", anchors: [], host: "MEDIA.example.TEST"),
            origin: ServerOrigin(host: "MEDIA.example.TEST", port: 8920),
            serverOrigin: server,
            stored: .certificate(TLSFixtures.der("selfSignedA"))
        )
        XCTAssertEqual(decision, .accept)
    }

    func testPinnedCertificateMatchIsAccepted() {
        let decision = ServerTrustPolicy.decide(
            trust: selfSignedTrust("selfSignedA"),
            origin: lan,
            serverOrigin: lan,
            stored: .certificate(TLSFixtures.der("selfSignedA"))
        )
        XCTAssertEqual(decision, .accept)
    }

    func testPinnedCertificateIsAcceptedAfterItExpires() {
        let trust = selfSignedTrust("selfSignedA")
        XCTAssertEqual(SecTrustSetVerifyDate(trust, Self.date(year: 2060, month: 1, day: 1) as CFDate), errSecSuccess)
        let decision = ServerTrustPolicy.decide(
            trust: trust,
            origin: lan,
            serverOrigin: lan,
            stored: .certificate(TLSFixtures.der("selfSignedA"))
        )
        XCTAssertEqual(decision, .accept)
    }

    func testChangedPinnedCertificateIsRefused() {
        let decision = ServerTrustPolicy.decide(
            trust: selfSignedTrust("selfSignedB"),
            origin: lan,
            serverOrigin: lan,
            stored: .certificate(TLSFixtures.der("selfSignedA"))
        )
        XCTAssertEqual(decision, .refuse(presentedLeaf: TLSFixtures.der("selfSignedB")))
    }

    func testNameTrustAcceptsARenewedCertificateForTheSameName() {
        let decision = ServerTrustPolicy.decide(
            trust: nameTrust("nameLeaf"),
            origin: lan,
            serverOrigin: lan,
            stored: .names(["media.dionysus.test"])
        )
        XCTAssertEqual(decision, .accept)
    }

    func testNameTrustAcceptsAWildcardName() {
        let decision = ServerTrustPolicy.decide(
            trust: nameTrust("nameLeaf"),
            origin: lan,
            serverOrigin: lan,
            stored: .names(["*.wild.dionysus.test"])
        )
        XCTAssertEqual(decision, .accept)
    }

    func testNameTrustRefusesAValidCertificateForAnotherName() {
        let trust = nameTrust("nameLeafOther")
        // The chain itself is valid: the refusal is about the name.
        XCTAssertTrue(ServerTrustPolicy.systemAccepts(trust, host: "other.dionysus.test"))
        let decision = ServerTrustPolicy.decide(
            trust: trust,
            origin: lan,
            serverOrigin: lan,
            stored: .names(["media.dionysus.test"])
        )
        XCTAssertEqual(decision, .refuse(presentedLeaf: TLSFixtures.der("nameLeafOther")))
    }

    /// Name trust waives only the name: an expired chain is still refused.
    func testNameTrustRefusesAnExpiredCertificate() {
        let trust = nameTrust("nameLeaf")
        SecTrustSetVerifyDate(trust, Self.date(year: 2060, month: 1, day: 1) as CFDate)
        let decision = ServerTrustPolicy.decide(
            trust: trust,
            origin: lan,
            serverOrigin: lan,
            stored: .names(["media.dionysus.test"])
        )
        XCTAssertEqual(decision, .refuse(presentedLeaf: TLSFixtures.der("nameLeaf")))
    }

    func testNoStoredTrustRefusesAndReports() {
        let decision = ServerTrustPolicy.decide(
            trust: selfSignedTrust("selfSignedA"),
            origin: lan,
            serverOrigin: lan,
            stored: nil
        )
        XCTAssertEqual(decision, .refuse(presentedLeaf: TLSFixtures.der("selfSignedA")))
    }

    func testASystemTrustedCertificateIsLeftToTheSystem() {
        let origin = ServerOrigin(host: "media.dionysus.test", port: 8920)
        let decision = ServerTrustPolicy.decide(
            trust: caIssuedTrust("nameLeaf", host: "media.dionysus.test"),
            origin: origin,
            serverOrigin: origin,
            stored: nil
        )
        XCTAssertEqual(decision, .systemDefault)
    }

    // MARK: - Helpers the table relies on

    /// The copy is evaluated, not the caller's trust: the fixture CA must
    /// survive it, or name trust would fail for the wrong reason.
    func testSystemAcceptsKeepsTheTrustsAnchors() {
        let trust = nameTrust("nameLeaf")
        XCTAssertTrue(ServerTrustPolicy.systemAccepts(trust, host: "media.dionysus.test"))
        XCTAssertTrue(ServerTrustPolicy.systemAccepts(trust, host: nil))
        XCTAssertFalse(ServerTrustPolicy.systemAccepts(trust, host: "192.168.1.50"))
        XCTAssertFalse(ServerTrustPolicy.systemAccepts(selfSignedTrust("selfSignedA"), host: nil))
    }

    /// The copy is evaluated at the caller's verify date, not now: past the
    /// leaves' window the same chain is refused.
    func testSystemAcceptsHonoursTheTrustsVerifyDate() {
        let trust = nameTrust("nameLeaf")
        XCTAssertTrue(ServerTrustPolicy.systemAccepts(trust, host: "media.dionysus.test"))
        SecTrustSetVerifyDate(trust, Self.date(year: 2060, month: 1, day: 1) as CFDate)
        XCTAssertFalse(ServerTrustPolicy.systemAccepts(trust, host: "media.dionysus.test"))
    }

    func testLeafDERIsThePresentedCertificate() {
        XCTAssertEqual(ServerTrustPolicy.leafDER(nameTrust("nameLeaf")), TLSFixtures.der("nameLeaf"))
    }

    func testProbeHostReplacesOnlyALeadingWildcard() {
        XCTAssertEqual(ServerTrustPolicy.probeHost(for: "*.wild.dionysus.test"), "dionysus-check.wild.dionysus.test")
        XCTAssertEqual(ServerTrustPolicy.probeHost(for: "media.dionysus.test"), "media.dionysus.test")
    }
}
