import XCTest
@testable import Dionysus

final class SpatialAudioStoreTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.SpatialAudioStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_defaults_bothOff_at714() {
        XCTAssertEqual(SpatialAudioStore(storage: defaults).settings, SpatialAudioSettings())
    }

    func test_settings_roundTrip() {
        var settings = SpatialAudioSettings()
        settings.atmosEnabled = true
        settings.atmosLayout = .l512
        settings.dtsXEnabled = true
        settings.dtsXLayout = .l916
        SpatialAudioStore(storage: defaults).settings = settings
        XCTAssertEqual(SpatialAudioStore(storage: defaults).settings, settings)
    }

    /// A layout DTS:X can't render reads as the default, as does garbage.
    func test_invalidStoredLayout_readsAs714() {
        defaults.set("5.1.2", forKey: SpatialAudioStore.dtsXLayoutKey)
        defaults.set("11.1.8", forKey: SpatialAudioStore.atmosLayoutKey)
        let settings = SpatialAudioStore(storage: defaults).settings
        XCTAssertEqual(settings.dtsXLayout, .l714)
        XCTAssertEqual(settings.atmosLayout, .l714)
    }
}
