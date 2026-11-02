import AVFoundation
import UIKit
import XCTest
@testable import Dionysus

/// Under an `AVPlayerViewController` host (the Apple TV player) AVKit owns Now
/// Playing and reads it from the item's `externalMetadata`, which the engine
/// stages before `load()` (M6, after Sodalite).
final class NowPlayingMetadataTests: XCTestCase {
    private func value(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) -> Any? {
        items.first { $0.identifier == identifier }?.value
    }

    func test_title_isTheCommonTitle() {
        let items = NowPlayingMetadata.externalMetadata(title: "Arrival", subtitle: nil, artwork: nil)
        XCTAssertEqual(value(items, .commonIdentifierTitle) as? String, "Arrival")
        XCTAssertNil(value(items, .commonIdentifierArtist))
        XCTAssertNil(value(items, .commonIdentifierArtwork))
    }

    /// The artist item is what AVKit forwards as Now Playing's second line;
    /// the iTunes subtitle feeds tvOS's own info panel (Sodalite, on device).
    func test_subtitle_isBothTheArtistAndTheTrackSubtitle() {
        let items = NowPlayingMetadata.externalMetadata(title: "Northern Lights", subtitle: "S1:E2 · Dawn", artwork: nil)
        XCTAssertEqual(value(items, .commonIdentifierArtist) as? String, "S1:E2 · Dawn")
        XCTAssertEqual(value(items, .iTunesMetadataTrackSubTitle) as? String, "S1:E2 · Dawn")
    }

    func test_artwork_isJPEGData() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let items = NowPlayingMetadata.externalMetadata(title: "Arrival", subtitle: nil, artwork: image)
        let artwork = try XCTUnwrap(items.first { $0.identifier == .commonIdentifierArtwork })
        XCTAssertEqual(artwork.dataType, kCMMetadataBaseDataType_JPEG as String)
        XCTAssertNotNil((artwork.value as? Data).flatMap(UIImage.init(data:)))
    }

    /// Every item carries a language tag: AVKit drops untagged string items.
    func test_everyItem_isTaggedUndetermined() {
        let items = NowPlayingMetadata.externalMetadata(title: "A", subtitle: "B", artwork: nil)
        XCTAssertTrue(items.allSatisfy { $0.extendedLanguageTag == "und" })
    }
}
