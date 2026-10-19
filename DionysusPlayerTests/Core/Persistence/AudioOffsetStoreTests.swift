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

    /// tvOS keeps the offset in the keychain every Apple TV user shares
    /// (final review, Important 2); this checks that storage round-trips.
    func test_sharedKeychainStorage_roundTrips() {
        let storage = SharedKeychainAudioOffsetStorage(keyPrefix: "tests.AudioOffsetStoreTests.")
        defer { storage.removeAll() }
        let keychainStore = AudioOffsetStore(storage: storage)
        keychainStore.globalOffsetMilliseconds = 40
        keychainStore.setOffset(-20, forItem: "item-1")

        let reread = AudioOffsetStore(storage: SharedKeychainAudioOffsetStorage(keyPrefix: "tests.AudioOffsetStoreTests."))
        XCTAssertEqual(reread.globalOffsetMilliseconds, 40)
        XCTAssertEqual(reread.offset(forItem: "item-1"), -20)
        reread.removeOffset(forItem: "item-1")
        XCTAssertNil(keychainStore.offset(forItem: "item-1"))
    }

    /// Review Focus 4: a value written by another build, out of range or off-step.
    func test_readsClampAndRoundWhatIsStored() {
        defaults.set(723, forKey: AudioOffsetStore.globalKey)
        defaults.set(["item-1": 9999, "item-2": -33], forKey: AudioOffsetStore.titlesKey)
        XCTAssertEqual(store.globalOffsetMilliseconds, 500)
        XCTAssertEqual(store.offset(forItem: "item-1"), 500)
        XCTAssertEqual(store.offset(forItem: "item-2"), -30)
    }

    /// One malformed entry (another build's 12.5, a corrupted string) costs
    /// that entry only: the next write must not wipe every other title.
    func test_aMalformedEntry_keepsTheRest() {
        defaults.set(["item-1": 12.5, "item-2": -40, "item-3": "x"], forKey: AudioOffsetStore.titlesKey)
        XCTAssertEqual(store.offset(forItem: "item-1"), 10)
        XCTAssertEqual(store.offset(forItem: "item-2"), -40)
        XCTAssertNil(store.offset(forItem: "item-3"))
        store.setOffset(20, forItem: "item-4")
        XCTAssertEqual(store.offset(forItem: "item-2"), -40)
        XCTAssertEqual(store.offset(forItem: "item-4"), 20)
    }
}
