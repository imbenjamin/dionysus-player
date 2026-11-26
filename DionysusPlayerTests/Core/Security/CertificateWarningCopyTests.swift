import Foundation
import XCTest
@testable import Dionysus

/// What the changed-certificate warning says (#466), on both platforms: a
/// trust kept by name whose certificate still carries a trusted name but no
/// longer verifies is called what it is (lapsed), not a new certificate.
final class CertificateWarningCopyTests: XCTestCase {
    /// `nameLeaf` with no anchor: valid for `media.dionysus.test` and
    /// `*.wild.dionysus.test`, its chain unverifiable, as when it expires or
    /// its authority is removed.
    private func lapsedLeafDetails() throws -> ServerCertificateDetails {
        try XCTUnwrap(ServerCertificateDetails(chain: [TLSFixtures.der("nameLeaf")]))
    }

    private func warning(previous: ServerCertificateTrust?) throws -> CertificateWarning {
        CertificateWarning(kind: previous.map { .changed(previous: $0) } ?? .untrusted, details: try lapsedLeafDetails())
    }

    // MARK: Matching a trusted name to the certificate's names

    func testADNSNameCoversTheSameNameIgnoringCase() {
        XCTAssertTrue(ServerTrustPolicy.dnsName("Media.Dionysus.test", covers: "media.dionysus.TEST"))
        XCTAssertFalse(ServerTrustPolicy.dnsName("media.dionysus.test", covers: "other.dionysus.test"))
    }

    func testAWildcardCoversOneLeftmostLabelOnly() {
        XCTAssertTrue(ServerTrustPolicy.dnsName("*.wild.dionysus.test", covers: "a.wild.dionysus.test"))
        XCTAssertFalse(ServerTrustPolicy.dnsName("*.wild.dionysus.test", covers: "a.b.wild.dionysus.test"))
        XCTAssertFalse(ServerTrustPolicy.dnsName("*.wild.dionysus.test", covers: "wild.dionysus.test"))
    }

    /// A trusted wildcard is probed as the policy probes it
    /// (`probeHost(for:)`), so the same wildcard covers it and a plain name
    /// doesn't.
    func testATrustedWildcardIsCoveredAsThePolicyProbesIt() {
        XCTAssertTrue(ServerTrustPolicy.dnsName("*.wild.dionysus.test", covers: "*.wild.dionysus.test"))
        XCTAssertFalse(ServerTrustPolicy.dnsName("a.wild.dionysus.test", covers: "*.wild.dionysus.test"))
    }

    // MARK: Classification

    func testANameTrustTheCertificateStillCarriesHasLapsed() throws {
        let warning = try warning(previous: .names(["media.dionysus.test"]))
        XCTAssertEqual(warning.lapsedNames, ["media.dionysus.test"])
    }

    func testOnlyTheTrustedNamesTheCertificateCarriesAreListed() throws {
        let warning = try warning(previous: .names(["other.example.com", "media.dionysus.test", "x.wild.dionysus.test"]))
        XCTAssertEqual(warning.lapsedNames, ["media.dionysus.test", "x.wild.dionysus.test"])
    }

    func testANameTrustForOtherNamesIsANewCertificate() throws {
        XCTAssertNil(try warning(previous: .names(["other.example.com"])).lapsedNames)
    }

    func testAPinnedTrustNeverLapses() throws {
        XCTAssertNil(try warning(previous: .certificate(TLSFixtures.der("selfSignedA"))).lapsedNames)
        XCTAssertNil(try warning(previous: .certificate(TLSFixtures.der("nameLeaf"))).lapsedNames)
    }

    func testNothingTrustedNeverLapses() throws {
        XCTAssertNil(try warning(previous: nil).lapsedNames)
    }

    // MARK: Copy

    func testTheLapsedCopy() throws {
        let warning = try warning(previous: .names(["media.dionysus.test", "*.wild.dionysus.test"]))
        XCTAssertEqual(warning.title(serverName: "Media"), "“Media”’s Certificate Is No Longer Valid")
        XCTAssertEqual(
            warning.message(host: "192.168.1.50"),
            "This certificate is still for media.dionysus.test and *.wild.dionysus.test, but it can no longer be verified. "
                + "It may have expired, or the authority that issued it is no longer trusted."
        )
        XCTAssertEqual(warning.newHeading, "Certificate")
        XCTAssertEqual(warning.previousHeading, "Trusted Certificate")
        XCTAssertTrue(warning.asksBeforeTrusting, "the buttons, and Trust's question, are unchanged")
    }

    func testAnyOtherChangeKeepsTodaysCopy() throws {
        for previous in [.names(["other.example.com"]), .certificate(TLSFixtures.der("selfSignedA"))] as [ServerCertificateTrust] {
            let warning = try warning(previous: previous)
            XCTAssertEqual(warning.title(serverName: "Media"), "“Media” Has a New Certificate")
            XCTAssertEqual(
                warning.message(host: nil),
                "This isn't the certificate you trusted. If you didn't replace it, something on this network may be "
                    + "intercepting the connection, such as a Wi-Fi sign-in page."
            )
            XCTAssertEqual(warning.newHeading, "New Certificate")
        }
    }

    func testTheUntrustedCopyIsUnchanged() throws {
        let warning = try warning(previous: nil)
        XCTAssertEqual(warning.title(serverName: "Media"), "Can't Verify “Media”")
        XCTAssertEqual(warning.newHeading, "Certificate")
    }
}
