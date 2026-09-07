import AetherEngine
import XCTest
@testable import Dionysus

/// `AetherPlaybackEngine.category(for:)` — the one place AetherEngine's own
/// `PlaybackErrorKind` (a plain public `RawRepresentable` struct, no live
/// engine instance needed to construct one) gets mapped onto the app's
/// `PlaybackFailure.Category` that `PlayerView` branches Retry-vs-Close on.
/// Everything else `AetherPlaybackEngine` does (the Combine-bridging
/// suppression flag, the seek watchdog's timing, PiP-failure logging) wraps
/// a real `AetherEngine` instance and can't be exercised without one — this
/// classifier is the one piece of that file's error handling that's a plain
/// static function, so it's the one piece covered by a unit test; see the
/// error-handling plan's own verification section for why the rest is
/// manual/on-device only.
@MainActor
final class AetherPlaybackEngineClassificationTests: XCTestCase {
    func test_sourceRateLimited_isRateLimited() {
        XCTAssertEqual(AetherPlaybackEngine.category(for: .sourceRateLimited), .rateLimited)
    }

    /// An access refusal, or content this build/device can never play
    /// regardless of retry count — all four map to `.refused`, per
    /// AetherEngine's own docs calling out `.sourceRefused` as the
    /// counterpart worth different recovery UX from `.sourceRateLimited`.
    func test_refusalAndUnplayableContentKinds_areRefused() {
        let refusedKinds: [PlaybackErrorKind] = [
            .sourceRefused, .dolbyVisionRequiresHardware, .hlsPlaylistOnRawLivePath, .demuxedAudioLiveUnsupported
        ]
        for kind in refusedKinds {
            XCTAssertEqual(AetherPlaybackEngine.category(for: kind), .refused, "\(kind.rawValue) should classify as .refused")
        }
    }

    /// Every other known kind — Retry is plausible for all of these, and
    /// this is today's existing default behavior for every failure.
    func test_everyOtherKnownKind_isTransient() {
        let transientKinds: [PlaybackErrorKind] = [
            .sourceOpenFailed, .customSourceProbeFailed, .liveSourceUnavailable, .nativeItemFailed,
            .noPlayableTrackWithinBudget, .masterPlaylistRejected, .vodSourceFailed, .softwarePipelineFailed,
            .audioSessionFailed, .reloadFailed, .liveReloadNeverReady, .audioTrackSwitchFailed
        ]
        for kind in transientKinds {
            XCTAssertEqual(AetherPlaybackEngine.category(for: kind), .transient, "\(kind.rawValue) should classify as .transient")
        }
    }

    /// `PlaybackErrorKind` is a string-backed struct, not an enum,
    /// specifically so a future AetherEngine release can add a new kind
    /// without breaking a host's exhaustive switch — proves
    /// `category(for:)`'s non-exhaustive `default:` actually delivers that
    /// forward-compatibility, falling back to `.transient` (Retry, the safe
    /// default) rather than crashing or matching the wrong case.
    func test_unrecognizedFutureKind_fallsBackToTransient() {
        let futureKind = PlaybackErrorKind(rawValue: "someKindThisAppDoesNotKnowAboutYet")
        XCTAssertEqual(AetherPlaybackEngine.category(for: futureKind), .transient)
    }
}
