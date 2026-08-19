import XCTest
@testable import Dionysus

final class DownloadPreferencesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.DownloadPreferencesStoreTests"

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
        let store = DownloadPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.resolution, .hd1080p)
        XCTAssertEqual(store.bitratePreset, .normal)
        XCTAssertEqual(store.wifiOnly, true)
        XCTAssertEqual(store.maxConcurrentDownloads, 5)
    }

    /// Same key `ProfileView`'s slider writes to.
    func test_maxConcurrentDownloads_readsWhateverWasWrittenToTheSharedKey() {
        defaults.set(3, forKey: downloadMaxConcurrentStorageKey)
        XCTAssertEqual(DownloadPreferencesStore(defaults: defaults).maxConcurrentDownloads, 3)
    }

    /// `0` is the slider's own "Unlimited" sentinel — mapped to `nil` so
    /// call sites reason about "no limit" the normal Swift way.
    func test_maxConcurrentDownloads_zero_mapsToNilForUnlimited() {
        defaults.set(0, forKey: downloadMaxConcurrentStorageKey)
        XCTAssertNil(DownloadPreferencesStore(defaults: defaults).maxConcurrentDownloads)
    }

    /// Same key `ProfileView`'s `@AppStorage(downloadResolutionStorageKey)`
    /// picker writes to — this is what lets a Settings change be visible to
    /// non-view code (`DownloadManager`) without a shared object reference.
    func test_resolution_readsWhateverWasWrittenToTheSharedKey() {
        defaults.set(DownloadResolution.uhd4K.rawValue, forKey: downloadResolutionStorageKey)
        XCTAssertEqual(DownloadPreferencesStore(defaults: defaults).resolution, .uhd4K)
    }

    func test_bitratePreset_readsWhateverWasWrittenToTheSharedKey() {
        defaults.set(DownloadBitratePreset.dataSaver.rawValue, forKey: downloadBitratePresetStorageKey)
        XCTAssertEqual(DownloadPreferencesStore(defaults: defaults).bitratePreset, .dataSaver)
    }

    func test_wifiOnly_readsWhateverWasWrittenToTheSharedKey() {
        defaults.set(false, forKey: downloadWifiOnlyStorageKey)
        XCTAssertEqual(DownloadPreferencesStore(defaults: defaults).wifiOnly, false)
    }

    /// A corrupt/unrecognized stored raw value falls back to the default
    /// rather than crashing or returning something nonsensical.
    func test_resolution_unrecognizedStoredValue_fallsBackToDefault() {
        defaults.set("not-a-real-resolution", forKey: downloadResolutionStorageKey)
        XCTAssertEqual(DownloadPreferencesStore(defaults: defaults).resolution, .hd1080p)
    }
}
