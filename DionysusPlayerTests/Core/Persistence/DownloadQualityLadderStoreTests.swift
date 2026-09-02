import XCTest
@testable import Dionysus

final class DownloadQualityLadderStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.dionysusplayer.tests.DownloadQualityLadderStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Fresh store falls through to the shipped ladder

    func test_freshStore_kbpsMatchesShippedDefaultConvertedToKbps() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        XCTAssertEqual(store.kbps(resolution: .hd1080p, preset: .normal), 3000)
        XCTAssertEqual(store.kbps(resolution: .hd720p, preset: .dataSaver), 750)
    }

    func test_freshStore_videoBitrateMatchesShippedDefaultBitsPerSecond() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        XCTAssertEqual(
            store.videoBitrate(resolution: .uhd4K, preset: .high),
            DownloadResolution.uhd4K.videoBitrate(preset: .high)
        )
    }

    func test_freshStore_hasNoOverrides() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        XCTAssertFalse(store.hasAnyOverride)
        XCTAssertFalse(store.isOverridden(resolution: .hd1080p, preset: .normal))
    }

    // MARK: Setting/reading a single cell

    func test_setOverride_isReflectedInKbpsAndVideoBitrate() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        store.setOverride(2500, resolution: .hd1080p, preset: .normal)
        XCTAssertEqual(store.kbps(resolution: .hd1080p, preset: .normal), 2500)
        XCTAssertEqual(store.videoBitrate(resolution: .hd1080p, preset: .normal), 2_500_000)
        XCTAssertTrue(store.isOverridden(resolution: .hd1080p, preset: .normal))
        XCTAssertTrue(store.hasAnyOverride)
    }

    /// Overriding one cell must not perturb any other cell's own value —
    /// each of the twelve entries is independent.
    func test_setOverride_onlyAffectsItsOwnCell() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        store.setOverride(2500, resolution: .hd1080p, preset: .normal)
        XCTAssertEqual(store.kbps(resolution: .hd1080p, preset: .high), 4500, "unrelated preset, same tier")
        XCTAssertEqual(store.kbps(resolution: .hd720p, preset: .normal), 1500, "unrelated tier, same preset")
        XCTAssertFalse(store.isOverridden(resolution: .hd1080p, preset: .high))
    }

    /// A second `UserDefaults`-backed instance sees the same value — this is
    /// what lets `DownloadsQualityLadderView`, `JellyfinAPIClient`, and
    /// `DownloadManager` each construct their own store and stay in
    /// agreement without sharing a reference.
    func test_setOverride_isVisibleToAFreshStoreInstanceOverTheSameDefaults() {
        DownloadQualityLadderStore(defaults: defaults).setOverride(5000, resolution: .uhd4K, preset: .dataSaver)
        XCTAssertEqual(DownloadQualityLadderStore(defaults: defaults).kbps(resolution: .uhd4K, preset: .dataSaver), 5000)
    }

    // MARK: Clamping

    func test_setOverride_clampsBelowMinimum() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        store.setOverride(0, resolution: .sd480p, preset: .high)
        XCTAssertEqual(store.kbps(resolution: .sd480p, preset: .high), DownloadQualityLadderStore.minKbps)

        store.setOverride(-100, resolution: .sd480p, preset: .high)
        XCTAssertEqual(store.kbps(resolution: .sd480p, preset: .high), DownloadQualityLadderStore.minKbps)
    }

    func test_setOverride_clampsAboveMaximum() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        store.setOverride(999_999, resolution: .sd480p, preset: .high)
        XCTAssertEqual(store.kbps(resolution: .sd480p, preset: .high), DownloadQualityLadderStore.maxKbps)
    }

    /// A real bug, found live: `DownloadsQualityLadderView`'s per-row
    /// `TextField` binding is rebuilt fresh on every render, and SwiftUI can
    /// resync a freshly rebuilt `Binding` by writing its currently-displayed
    /// value straight back through the new `set` — so a cell showing its
    /// own default (no user edit at all) could get spuriously re-committed
    /// and end up persisted as an explicit "override" of a value identical
    /// to the default, which then wrongly showed a reset affordance for a
    /// cell with nothing to reset. Setting exactly the default must always
    /// behave like clearing, regardless of why that value was set.
    func test_setOverride_valueEqualToDefault_isTreatedAsNotOverridden() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        store.setOverride(3000, resolution: .hd1080p, preset: .normal)
        XCTAssertFalse(store.isOverridden(resolution: .hd1080p, preset: .normal))
        XCTAssertFalse(store.hasAnyOverride)
        XCTAssertEqual(store.kbps(resolution: .hd1080p, preset: .normal), 3000)
    }

    /// Same rule, but clearing a *real* override back down to the default
    /// value rather than never having one — a spurious resync after a
    /// genuine edit must not leave the cell looking overridden either.
    func test_setOverride_changedBackToDefaultValue_clearsTheOverride() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        store.setOverride(2500, resolution: .hd1080p, preset: .normal)
        XCTAssertTrue(store.isOverridden(resolution: .hd1080p, preset: .normal))

        store.setOverride(3000, resolution: .hd1080p, preset: .normal)
        XCTAssertFalse(store.isOverridden(resolution: .hd1080p, preset: .normal))
    }

    // MARK: Resetting

    func test_setOverride_nil_clearsBackToDefault() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        store.setOverride(2500, resolution: .hd1080p, preset: .normal)
        store.setOverride(nil, resolution: .hd1080p, preset: .normal)
        XCTAssertEqual(store.kbps(resolution: .hd1080p, preset: .normal), 3000)
        XCTAssertFalse(store.isOverridden(resolution: .hd1080p, preset: .normal))
    }

    func test_resetAll_clearsEveryCell() {
        let store = DownloadQualityLadderStore(defaults: defaults)
        for resolution in DownloadResolution.allCases {
            for preset in DownloadBitratePreset.allCases {
                store.setOverride(1234, resolution: resolution, preset: preset)
            }
        }
        XCTAssertTrue(store.hasAnyOverride)

        store.resetAll()

        XCTAssertFalse(store.hasAnyOverride)
        for resolution in DownloadResolution.allCases {
            for preset in DownloadBitratePreset.allCases {
                XCTAssertEqual(
                    store.kbps(resolution: resolution, preset: preset),
                    resolution.videoBitrate(preset: preset) / 1000
                )
            }
        }
    }
}
