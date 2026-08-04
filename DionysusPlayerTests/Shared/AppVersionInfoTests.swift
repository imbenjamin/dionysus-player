import XCTest
@testable import Dionysus

/// `footerText(info:)` takes its Info.plist dictionary as a parameter
/// specifically so this doesn't depend on whatever branch/commit happened
/// to build the test host — see its doc comment.
final class AppVersionInfoTests: XCTestCase {
    func test_footerText_formatsBranchAndCommit() {
        let text = AppVersionInfo.footerText(info: ["GitBranch": "develop", "GitCommitHash": "a1b2c3d"])
        XCTAssertEqual(text, "Dionysus Player develop (a1b2c3d)")
    }

    func test_footerText_fallsBackToUnknownWhenKeysMissing() {
        XCTAssertEqual(AppVersionInfo.footerText(info: [:]), "Dionysus Player unknown (unknown)")
    }

    func test_footerText_fallsBackToUnknownWhenInfoIsNil() {
        XCTAssertEqual(AppVersionInfo.footerText(info: nil), "Dionysus Player unknown (unknown)")
    }

    func test_footerText_ignoresNonStringValuesForTheKeys() {
        // Defensive: Info.plist values are typed dynamically; a malformed
        // entry (wrong type) should fall back rather than crash.
        let text = AppVersionInfo.footerText(info: ["GitBranch": 42, "GitCommitHash": "a1b2c3d"])
        XCTAssertEqual(text, "Dionysus Player unknown (a1b2c3d)")
    }
}
