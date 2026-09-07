import XCTest
@testable import Dionysus

/// `DeviceIdentity.deviceID` caches into the real `UserDefaults.standard`
/// (same store the shipping app uses — not injectable), so these tests save
/// and restore whatever was already there rather than clearing it outright,
/// to avoid disturbing this machine's real cached ID across runs.
final class DeviceIdentityTests: XCTestCase {
    private let key = "device.identifier"
    private var originalValue: String?

    override func setUp() {
        super.setUp()
        originalValue = UserDefaults.standard.string(forKey: key)
    }

    override func tearDown() {
        if let originalValue {
            UserDefaults.standard.set(originalValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func test_deviceID_generatedOnceAndCachedAcrossCalls() {
        UserDefaults.standard.removeObject(forKey: key)

        let first = DeviceIdentity.deviceID
        XCTAssertFalse(first.isEmpty)

        let second = DeviceIdentity.deviceID
        XCTAssertEqual(first, second, "Should reuse the cached ID rather than generating a fresh one on every access")
    }

    func test_deviceID_reusesWhateverIsAlreadyPersisted() {
        UserDefaults.standard.set("fixed-id-123", forKey: key)
        XCTAssertEqual(DeviceIdentity.deviceID, "fixed-id-123")
    }

    func test_clientName_isDionysus() {
        XCTAssertEqual(DeviceIdentity.clientName, "Dionysus")
    }

    func test_deviceName_isNonEmpty() {
        XCTAssertFalse(DeviceIdentity.deviceName.isEmpty)
    }
}
