import SwiftUI
import XCTest
@testable import Dionysus

/// A destructive row is a plain row with a red title at rest, and takes the
/// system's destructive role only in focus: at rest tvOS 26 drew that role's
/// title red on a red platter (Benjamin, 2026-10-11).
final class TVSettingsRowTests: XCTestCase {
    func test_destructiveRow_takesItsRoleOnlyInFocus() {
        XCTAssertNil(TVSettingsRow.buttonRole(.destructive, isFocused: false))
        XCTAssertEqual(TVSettingsRow.buttonRole(.destructive, isFocused: true), .destructive)
    }

    func test_destructiveRow_titleIsRedOnlyAtRest() {
        XCTAssertTrue(TVSettingsRow.titleIsRed(.destructive, isFocused: false))
        XCTAssertFalse(TVSettingsRow.titleIsRed(.destructive, isFocused: true))
    }

    func test_plainRow_isUnchanged() {
        XCTAssertNil(TVSettingsRow.buttonRole(nil, isFocused: true))
        XCTAssertFalse(TVSettingsRow.titleIsRed(nil, isFocused: false))
    }
}
