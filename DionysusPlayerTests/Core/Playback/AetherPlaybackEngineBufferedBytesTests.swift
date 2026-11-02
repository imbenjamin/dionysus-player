import XCTest
import AetherEngine
@testable import Dionysus

/// Stats' "Buffered" size reads the bytes ahead of the playhead, not the
/// whole segment cache, which also holds segments already watched.
final class AetherPlaybackEngineBufferedBytesTests: XCTestCase {
    func test_loopbackCache_reportsForwardBytesOnly() {
        let status = Self.status(route: .loopbackFMP4, capability: .active, resident: 900_000_000, forward: 600_000_000)
        XCTAssertEqual(AetherPlaybackEngine.forwardCacheBytes(status), 600_000_000)
    }

    /// AVPlayer buffers a server transcode against the origin, so there is no
    /// local cache to size; "unsupported" isn't an empty cache.
    func test_remoteHLS_reportsNothing() {
        XCTAssertNil(AetherPlaybackEngine.forwardCacheBytes(.nativeRemoteHLS(requestedBudgetBytes: nil)))
    }

    /// Software sessions, and the gap before a load's first sample or after
    /// stop, report the inactive snapshot.
    func test_inactiveCache_reportsNothing() {
        XCTAssertNil(AetherPlaybackEngine.forwardCacheBytes(.inactive))
    }

    /// The software route's `bufferedPosition` is the end of its packet cache,
    /// on `currentTime`'s axis (AE#776's cache, published since 7.x).
    func test_softwareRoute_readsPacketCacheAhead() {
        let seconds = AetherPlaybackEngine.bufferedAheadSeconds(
            backend: .software, loadedAhead: nil, bufferedPosition: 1_390, sourceTime: 1_205, currentTime: 1_200
        )
        XCTAssertEqual(seconds, 190)
    }

    func test_nativeRoute_prefersAVPlayersLoadedRange() {
        let seconds = AetherPlaybackEngine.bufferedAheadSeconds(
            backend: .native, loadedAhead: 24, bufferedPosition: 1_390, sourceTime: 1_200, currentTime: 1_200
        )
        XCTAssertEqual(seconds, 24)
    }

    func test_nativeRoute_withoutAnItem_fallsBackToTheClock() {
        let seconds = AetherPlaybackEngine.bufferedAheadSeconds(
            backend: .native, loadedAhead: nil, bufferedPosition: 1_230, sourceTime: 1_200, currentTime: 1_190
        )
        XCTAssertEqual(seconds, 30)
    }

    func test_audioOnly_reportsNothing() {
        XCTAssertNil(AetherPlaybackEngine.bufferedAheadSeconds(
            backend: .audio, loadedAhead: nil, bufferedPosition: 10, sourceTime: 0, currentTime: 0
        ))
    }

    private static func status(
        route: SessionCacheRoute, capability: SessionCacheCapability, resident: Int, forward: Int
    ) -> SessionCacheStatus {
        SessionCacheStatus(
            route: route, capability: capability, requestedBudgetBytes: nil, volumeSafetyLimitBytes: nil,
            baseEffectiveBudgetBytes: 0, playbackSafeFloorBytes: 0, effectiveBudgetBytes: 0,
            currentResidentBytes: resident, currentForwardBytes: forward,
            forwardWindowSegments: 0, backwardWindowSegments: 0, producerParked: false,
            evictionCount: 0, hardWindowFloorExceeded: false,
            cleanupReason: nil, cleanupResult: .notRun, lastFailure: nil
        )
    }
}
