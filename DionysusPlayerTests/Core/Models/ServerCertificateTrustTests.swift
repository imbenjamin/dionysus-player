import XCTest
@testable import Dionysus

/// What Profile says about a server's stored certificate trust (#466).
final class ServerCertificateTrustTests: XCTestCase {
    func testProfileSummaryNamesTheFirstNameOrSaysSelfSigned() {
        XCTAssertEqual(
            ServerCertificateTrust.names(["media.lan", "10.0.0.2"]).profileSummary,
            String(localized: "Trusted for media.lan")
        )
        XCTAssertEqual(
            ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA")).profileSummary,
            String(localized: "Trusted (self-signed)")
        )
    }

    /// A certificate a private CA issued isn't self-signed, so it isn't called that.
    func testProfileSummaryDoesNotCallAnIssuedCertificateSelfSigned() {
        XCTAssertEqual(
            ServerCertificateTrust.certificate(TLSFixtures.der("nameLeaf")).profileSummary,
            String(localized: "Trusted (this certificate)")
        )
    }

    func testTVSummaryEndsInCertificateForEveryKind() {
        XCTAssertEqual(
            ServerCertificateTrust.names(["media.lan", "10.0.0.2"]).profileSummaryForTV,
            String(localized: "Certificate trusted for media.lan")
        )
        XCTAssertEqual(
            ServerCertificateTrust.certificate(TLSFixtures.der("selfSignedA")).profileSummaryForTV,
            String(localized: "Trusted (self-signed) certificate")
        )
        XCTAssertEqual(
            ServerCertificateTrust.certificate(TLSFixtures.der("nameLeaf")).profileSummaryForTV,
            String(localized: "Trusted (pinned) certificate")
        )
    }
}
