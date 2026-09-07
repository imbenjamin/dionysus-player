import XCTest
@testable import Dionysus

final class StreamPreferenceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.StreamPreferenceStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_freshStore_fallsBackToDocumentedDefaults() {
        let store = StreamPreferenceStore(defaults: defaults)
        XCTAssertEqual(store.decisionMode, .allowTranscoding)
        XCTAssertEqual(store.streamingMaxBitrate, .unlimited)
    }

    /// Same key `ProfileView`'s `@AppStorage(streamDecisionModeStorageKey)`
    /// picker writes to — this is what lets a Settings change be visible to
    /// non-view code (`PlayerViewModel`) without a shared object reference.
    func test_decisionMode_readsWhateverWasWrittenToTheSharedKey() {
        defaults.set(StreamDecisionMode.allowTranscoding.rawValue, forKey: streamDecisionModeStorageKey)
        XCTAssertEqual(StreamPreferenceStore(defaults: defaults).decisionMode, .allowTranscoding)
    }

    func test_streamingMaxBitrate_readsWhateverWasWrittenToTheSharedKey() {
        defaults.set(StreamingMaxBitrate.mbps10.rawValue, forKey: streamingMaxBitrateStorageKey)
        XCTAssertEqual(StreamPreferenceStore(defaults: defaults).streamingMaxBitrate, .mbps10)
    }

    /// A corrupt/unrecognized stored raw value falls back to the default
    /// rather than crashing or returning something nonsensical.
    func test_decisionMode_unrecognizedStoredValue_fallsBackToDefault() {
        defaults.set("not-a-real-mode", forKey: streamDecisionModeStorageKey)
        XCTAssertEqual(StreamPreferenceStore(defaults: defaults).decisionMode, .allowTranscoding)
    }

    func test_streamingMaxBitrate_unrecognizedStoredValue_fallsBackToDefault() {
        defaults.set("not-a-real-tier", forKey: streamingMaxBitrateStorageKey)
        XCTAssertEqual(StreamPreferenceStore(defaults: defaults).streamingMaxBitrate, .unlimited)
    }

    /// `.unlimited` expresses "no user-imposed cap" as `nil` — turning that
    /// into a concrete wire value is `DeviceProfileBuilder.build(_:)`'s job
    /// (see its own doc comment on why it can't just omit the field).
    func test_bitsPerSecond_unlimitedIsNil_othersAreExactMbpsValues() {
        XCTAssertNil(StreamingMaxBitrate.unlimited.bitsPerSecond)
        XCTAssertEqual(StreamingMaxBitrate.mbps40.bitsPerSecond, 40_000_000)
        XCTAssertEqual(StreamingMaxBitrate.mbps20.bitsPerSecond, 20_000_000)
        XCTAssertEqual(StreamingMaxBitrate.mbps10.bitsPerSecond, 10_000_000)
        XCTAssertEqual(StreamingMaxBitrate.mbps4.bitsPerSecond, 4_000_000)
    }
}
