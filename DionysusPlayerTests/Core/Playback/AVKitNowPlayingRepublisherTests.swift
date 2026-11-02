import AVFoundation
import XCTest
@testable import Dionysus

/// Under an AVPlayerViewController host AVKit publishes Now Playing while the
/// player is still waiting to play (rate 0), and never again once it plays, so
/// a paired iPhone's progress bar stood still (M6, Bedroom). Staging the same
/// metadata again as playback settles makes AVKit publish the real rate.
@MainActor
final class AVKitNowPlayingRepublisherTests: XCTestCase {
    private var staged: [[AVMetadataItem]] = []
    private lazy var republisher = AVKitNowPlayingRepublisher { [unowned self] in staged.append($0) }
    private let items = NowPlayingMetadata.externalMetadata(title: "Deadpool", subtitle: "2016 · 1h 48m", artwork: nil)

    func test_stage_passesTheItemsStraightThrough() {
        republisher.stage(items)
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.count, items.count)
    }

    func test_settlingIntoPlaying_stagesTheSameItemsAgain() {
        republisher.stage(items)
        republisher.timeControlStatusChanged(.playing)
        XCTAssertEqual(staged.count, 2)
        XCTAssertEqual(staged.last?.map(\.identifier), items.map(\.identifier))
    }

    func test_waitingOrPaused_restagesNothing() {
        republisher.stage(items)
        republisher.timeControlStatusChanged(.waitingToPlayAtSpecifiedRate)
        republisher.timeControlStatusChanged(.paused)
        XCTAssertEqual(staged.count, 1)
    }

    func test_nothingStagedYet_restagesNothing() {
        republisher.timeControlStatusChanged(.playing)
        XCTAssertTrue(staged.isEmpty)
    }
}
