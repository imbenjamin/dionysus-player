import XCTest
@testable import Dionysus

final class TestHostDetectionTests: XCTestCase {
    func test_withXCTestConfigurationPath_isUnitTestHost() {
        XCTAssertTrue(TestHostDetection.isUnitTestHost(environment: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"]))
    }

    func test_withoutIt_isNotUnitTestHost() {
        XCTAssertFalse(TestHostDetection.isUnitTestHost(environment: [:]))
    }

    func test_uiTestModeAlone_isNotUnitTestHost() {
        XCTAssertFalse(TestHostDetection.isUnitTestHost(environment: ["UITestMode": "YES"]))
    }

    func test_thisProcess_isAUnitTestHost() {
        XCTAssertTrue(TestHostDetection.isUnitTestHost)
    }
}
