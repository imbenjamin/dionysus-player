import XCTest
@testable import Dionysus

/// Exercises the real Keychain (no fake/in-memory substitute exists for
/// Security.framework) — these run fine in the Simulator, where the app's
/// own keychain access needs no special entitlement, but each test cleans
/// up after itself so a failed run can't poison the next one.
final class KeychainStoreTests: XCTestCase {
    private let key = "test.keychain.\(UUID().uuidString)"

    override func tearDown() {
        KeychainStore.delete(forKey: key)
        super.tearDown()
    }

    func test_saveThenLoad_roundTripsTheSameData() {
        let data = Data("hello".utf8)
        KeychainStore.save(data, forKey: key)
        XCTAssertEqual(KeychainStore.load(forKey: key), data)
    }

    func test_save_overwritesAnyExistingValueForTheSameKey() {
        KeychainStore.save(Data("first".utf8), forKey: key)
        KeychainStore.save(Data("second".utf8), forKey: key)
        XCTAssertEqual(KeychainStore.load(forKey: key), Data("second".utf8))
    }

    func test_load_missingKeyReturnsNil() {
        XCTAssertNil(KeychainStore.load(forKey: "test.keychain.never-saved"))
    }

    func test_delete_removesTheValue() {
        KeychainStore.save(Data("hello".utf8), forKey: key)
        KeychainStore.delete(forKey: key)
        XCTAssertNil(KeychainStore.load(forKey: key))
    }
}
