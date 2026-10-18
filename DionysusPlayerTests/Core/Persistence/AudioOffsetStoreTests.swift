import XCTest
@testable import Dionysus

final class AudioOffsetStoreTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.AudioOffsetStoreTests"
    private var defaults: UserDefaults!
    private var store: AudioOffsetStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = AudioOffsetStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_global_defaultsToZero() {
        XCTAssertEqual(store.globalOffsetMilliseconds, 0)
    }

    func test_global_persists_normalized() {
        store.globalOffsetMilliseconds = 44
        XCTAssertEqual(AudioOffsetStore(defaults: defaults).globalOffsetMilliseconds, 40)
        store.globalOffsetMilliseconds = 9000
        XCTAssertEqual(store.globalOffsetMilliseconds, 500)
    }

    func test_titleOffset_setReadRemove() {
        XCTAssertNil(store.offset(forItem: "item-1"))
        store.setOffset(-120, forItem: "item-1")
        XCTAssertEqual(AudioOffsetStore(defaults: defaults).offset(forItem: "item-1"), -120)
        XCTAssertNil(store.offset(forItem: "item-2"), "Another item is untouched")
        store.removeOffset(forItem: "item-1")
        XCTAssertNil(store.offset(forItem: "item-1"))
    }

    func test_titleOffset_normalizedOnWrite() {
        store.setOffset(-777, forItem: "item-1")
        XCTAssertEqual(store.offset(forItem: "item-1"), -500)
    }

    /// Review Focus 4: a value written by another build, out of range or off-step.
    func test_readsClampAndRoundWhatIsStored() {
        defaults.set(723, forKey: AudioOffsetStore.globalKey)
        defaults.set(["item-1": 9999, "item-2": -33], forKey: AudioOffsetStore.titlesKey)
        XCTAssertEqual(store.globalOffsetMilliseconds, 500)
        XCTAssertEqual(store.offset(forItem: "item-1"), 500)
        XCTAssertEqual(store.offset(forItem: "item-2"), -30)
    }
}
