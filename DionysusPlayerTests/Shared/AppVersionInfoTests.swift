import XCTest
@testable import Dionysus

/// `footerText(version:)` takes its version string as a parameter
/// specifically so this doesn't depend on whatever tag/commit happened to
/// build the test host — see its doc comment.
final class AppVersionInfoTests: XCTestCase {
    func test_footerText_formatsVersion() {
        XCTAssertEqual(AppVersionInfo.footerText(version: "1.2.3-alpha.4"), "Dionysus Player 1.2.3-alpha.4")
    }

    func test_footerText_defaultsToAppVersionFull() {
        XCTAssertEqual(AppVersionInfo.footerText(), "Dionysus Player \(AppVersion.full)")
    }
}
