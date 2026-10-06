import CoreGraphics
import Foundation

/// The transport's geometry and text, kept out of the view to be tested.
enum TVTransportLayout {
    static func fraction(_ time: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, time / duration))
    }

    /// The end of what is buffered, as a fraction of the title. `nil` where
    /// the route reports nothing (`PlaybackStats.bufferedSeconds` is
    /// native-route only), so no fill is drawn rather than a wrong one.
    static func bufferedFraction(currentTime: TimeInterval, bufferedSeconds: Double?, duration: TimeInterval) -> Double? {
        guard let bufferedSeconds, duration > 0 else { return nil }
        return fraction(currentTime + bufferedSeconds, duration: duration)
    }

    /// The preview's centre over the scrub head, kept on the track.
    static func previewCenterX(fraction: Double, trackWidth: CGFloat, previewWidth: CGFloat) -> CGFloat {
        let half = previewWidth / 2
        return min(max(trackWidth * fraction, half), max(trackWidth - half, half))
    }

    /// "52:15 · The Radio Broadcast" (prototype screen 12).
    static func previewCaption(time: TimeInterval, chapterName: String?) -> String {
        let clock = TVPlaybackTimeFormat.string(time)
        guard let chapterName else { return clock }
        return "\(clock) · \(chapterName)"
    }

    /// `PlayerViewModel.videoFormatDescription` is AetherEngine's presented
    /// format and `nil` for SDR, so the chip shows only while the engine has
    /// evidence the picture is HDR (Benjamin, 2026-10-06; CLAUDE.md, HDR).
    static func formatChipText(_ description: String?) -> String? {
        description?.uppercased()
    }
}
