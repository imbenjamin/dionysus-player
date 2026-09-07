import XCTest
@testable import Dionysus

final class MediaVersionPreferenceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.MediaVersionPreferenceStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_freshStore_hasNoPreference() {
        let store = MediaVersionPreferenceStore(defaults: defaults)
        XCTAssertNil(store.preferredMediaSourceID(forItem: "movie-1", userID: "user-1"))
    }

    func test_setPreferredMediaSourceID_persistsAcrossNewInstances() {
        MediaVersionPreferenceStore(defaults: defaults)
            .setPreferredMediaSourceID("src-1080p", forItem: "movie-1", userID: "user-1")

        let reloaded = MediaVersionPreferenceStore(defaults: defaults)
        XCTAssertEqual(reloaded.preferredMediaSourceID(forItem: "movie-1", userID: "user-1"), "src-1080p")
    }

    func test_setPreferredMediaSourceID_overwritesAPreviousChoiceForTheSameItem() {
        let store = MediaVersionPreferenceStore(defaults: defaults)
        store.setPreferredMediaSourceID("src-1080p", forItem: "movie-1", userID: "user-1")
        store.setPreferredMediaSourceID("src-4k", forItem: "movie-1", userID: "user-1")

        XCTAssertEqual(store.preferredMediaSourceID(forItem: "movie-1", userID: "user-1"), "src-4k")
    }

    func test_setPreferredMediaSourceID_doesNotAffectOtherItems() {
        let store = MediaVersionPreferenceStore(defaults: defaults)
        store.setPreferredMediaSourceID("src-1080p", forItem: "movie-1", userID: "user-1")

        XCTAssertNil(store.preferredMediaSourceID(forItem: "movie-2", userID: "user-1"))
    }

    /// Same reasoning as `SearchHistoryStoreTests`' equivalent — a shared
    /// device switching accounts shouldn't leak one user's version choice
    /// as another's.
    func test_preference_isScopedPerUser() {
        let store = MediaVersionPreferenceStore(defaults: defaults)
        store.setPreferredMediaSourceID("src-1080p", forItem: "movie-1", userID: "user-1")
        store.setPreferredMediaSourceID("src-4k", forItem: "movie-1", userID: "user-2")

        XCTAssertEqual(store.preferredMediaSourceID(forItem: "movie-1", userID: "user-1"), "src-1080p")
        XCTAssertEqual(store.preferredMediaSourceID(forItem: "movie-1", userID: "user-2"), "src-4k")
    }
}
