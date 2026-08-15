import XCTest
@testable import Dionysus

final class TrackPreferenceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.TrackPreferenceStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_freshStore_hasNoSelection() {
        let store = TrackPreferenceStore(defaults: defaults)
        XCTAssertNil(store.selection(forItem: "movie-1", userID: "user-1"))
    }

    func test_recordAudioSelection_persistsAcrossNewInstances() {
        TrackPreferenceStore(defaults: defaults)
            .recordAudioSelection(.init(id: 2, title: "Spanish"), forItem: "movie-1", userID: "user-1")

        let reloaded = TrackPreferenceStore(defaults: defaults)
        XCTAssertEqual(reloaded.selection(forItem: "movie-1", userID: "user-1")?.audioTrack, .init(id: 2, title: "Spanish"))
    }

    /// Recording only an audio choice shouldn't fabricate a subtitle
    /// choice — the caller (`PlayerViewModel.applyStoredTrackSelection()`)
    /// relies on `.unset` to mean "leave the engine's default alone."
    func test_recordAudioSelection_leavesSubtitlePreferenceUnset() {
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordAudioSelection(.init(id: 2, title: "Spanish"), forItem: "movie-1", userID: "user-1")

        XCTAssertEqual(store.selection(forItem: "movie-1", userID: "user-1")?.subtitlePreference, .unset)
    }

    func test_recordSubtitleSelection_withTrack_persists() {
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordSubtitleSelection(.init(id: 3, title: "English"), forItem: "movie-1", userID: "user-1")

        XCTAssertEqual(store.selection(forItem: "movie-1", userID: "user-1")?.subtitlePreference, .track(.init(id: 3, title: "English")))
    }

    /// `nil` records "off" as a deliberate, rememberable choice — distinct
    /// from never having recorded a subtitle preference at all.
    func test_recordSubtitleSelection_withNil_persistsAsOff() {
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordSubtitleSelection(nil, forItem: "movie-1", userID: "user-1")

        XCTAssertEqual(store.selection(forItem: "movie-1", userID: "user-1")?.subtitlePreference, .off)
    }

    func test_recordAudioThenSubtitleSelection_forSameItem_keepsBoth() {
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordAudioSelection(.init(id: 2, title: "Spanish"), forItem: "movie-1", userID: "user-1")
        store.recordSubtitleSelection(.init(id: 5, title: "English"), forItem: "movie-1", userID: "user-1")

        let selection = store.selection(forItem: "movie-1", userID: "user-1")
        XCTAssertEqual(selection?.audioTrack, .init(id: 2, title: "Spanish"))
        XCTAssertEqual(selection?.subtitlePreference, .track(.init(id: 5, title: "English")))
    }

    func test_recordSelection_overwritesAPreviousChoiceForTheSameItem() {
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordAudioSelection(.init(id: 1, title: "English"), forItem: "movie-1", userID: "user-1")
        store.recordAudioSelection(.init(id: 2, title: "Spanish"), forItem: "movie-1", userID: "user-1")

        XCTAssertEqual(store.selection(forItem: "movie-1", userID: "user-1")?.audioTrack, .init(id: 2, title: "Spanish"))
    }

    func test_recordSelection_doesNotAffectOtherItems() {
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordAudioSelection(.init(id: 2, title: "Spanish"), forItem: "movie-1", userID: "user-1")

        XCTAssertNil(store.selection(forItem: "movie-2", userID: "user-1"))
    }

    /// Same reasoning as `MediaVersionPreferenceStoreTests`' equivalent — a
    /// shared device switching accounts shouldn't leak one user's track
    /// choice as another's.
    func test_selection_isScopedPerUser() {
        let store = TrackPreferenceStore(defaults: defaults)
        store.recordAudioSelection(.init(id: 2, title: "Spanish"), forItem: "movie-1", userID: "user-1")
        store.recordAudioSelection(.init(id: 3, title: "French"), forItem: "movie-1", userID: "user-2")

        XCTAssertEqual(store.selection(forItem: "movie-1", userID: "user-1")?.audioTrack, .init(id: 2, title: "Spanish"))
        XCTAssertEqual(store.selection(forItem: "movie-1", userID: "user-2")?.audioTrack, .init(id: 3, title: "French"))
    }
}
