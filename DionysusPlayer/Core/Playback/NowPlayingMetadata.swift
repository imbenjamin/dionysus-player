import AVFoundation
import UIKit

/// Now Playing for an `AVPlayerViewController` host (the Apple TV player),
/// where AVKit owns the session and reads the item's `externalMetadata` (M6,
/// following Sodalite: an app session of its own conflicts with AVKit's, and
/// AVKit publishes only with `showsPlaybackControls` on). `AetherPlaybackEngine`
/// stages these through the engine before `load()`, so AVKit's first read of
/// the item finds them, and again when the artwork arrives.
enum NowPlayingMetadata {
    static func externalMetadata(title: String, subtitle: String?, artwork: UIImage?) -> [AVMetadataItem] {
        var items = [string(.commonIdentifierTitle, title)]
        if let subtitle {
            // The artist is what AVKit forwards as Now Playing's second line;
            // the iTunes subtitle feeds tvOS's own info panel (Sodalite, on
            // device).
            items.append(string(.commonIdentifierArtist, subtitle))
            items.append(string(.iTunesMetadataTrackSubTitle, subtitle))
        }
        if let data = artwork?.jpegData(compressionQuality: 0.85) {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.value = data as NSData
            item.dataType = kCMMetadataBaseDataType_JPEG as String
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        return items
    }

    private static func string(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

/// Keeps AVKit's Now Playing moving on a paired iPhone (M6). AVKit publishes
/// its snapshot when the player starts and seeks, while it is still waiting to
/// play (a rate of 0), and doesn't publish again once it plays, so the iPhone's
/// progress bar stood still (Bedroom, tvOS 27). Staging the same metadata again
/// each time playback settles makes AVKit publish the real rate.
@MainActor
final class AVKitNowPlayingRepublisher {
    private let apply: ([AVMetadataItem]) -> Void
    private var staged: [AVMetadataItem] = []

    init(apply: @escaping ([AVMetadataItem]) -> Void) {
        self.apply = apply
    }

    func stage(_ items: [AVMetadataItem]) {
        staged = items
        apply(items)
    }

    func timeControlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        guard status == .playing, !staged.isEmpty else { return }
        apply(staged)
    }
}
