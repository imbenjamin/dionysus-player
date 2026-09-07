import Foundation

/// The one place `PlayerView` gets a `PlaybackEngine` from.
///
/// Exists so a UI test can run the player without AetherEngine. Real
/// playback needs real media and a real display, and its video surface
/// repaints continuously — with the fake in place there is no surface at
/// all, and `PlayerControlsOverlay` is plain SwiftUI that XCUITest can see
/// and drive. What that buys is coverage of the transport, scrubber, chapter
/// picker and track pickers; what it deliberately gives up is decode, HDR,
/// transcode and seek behaviour, which stay manual on-device checks.
///
/// In a Release build this compiles down to `try AetherPlaybackEngine()`.
@MainActor
enum PlaybackEngineFactory {
    static func make() throws -> PlaybackEngine {
        #if DEBUG
        if UITestConfiguration.isActive {
            let fake = PreviewPlaybackEngine()
            // Previews want a still frame; a UI test wants a clock, so the
            // scrubber and the elapsed/remaining labels actually move.
            fake.advancesTime = true
            return fake
        }
        #endif
        return try AetherPlaybackEngine()
    }
}
