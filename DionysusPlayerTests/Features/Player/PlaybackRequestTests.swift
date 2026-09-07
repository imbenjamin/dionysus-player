import XCTest
@testable import Dionysus

/// `PlaybackRequest.id` deliberately folds both `startFromBeginning` and
/// `mediaSourceID` into the identity (see its doc comment) so a Restart
/// tapped right after a Resume, or a different version picked on a second
/// Play, presents a fresh `.fullScreenCover(item:)` instead of being
/// coalesced as "same item, no change" — worth pinning down directly since
/// it's exactly the kind of thing that looks like a harmless simplification
/// later.
final class PlaybackRequestTests: XCTestCase {
    func test_id_differsByStartFromBeginningForTheSameItem() {
        let resume = PlaybackRequest(itemID: "item-1", startFromBeginning: false)
        let restart = PlaybackRequest(itemID: "item-1", startFromBeginning: true)
        XCTAssertNotEqual(resume.id, restart.id)
    }

    func test_id_isStableForIdenticalInputs() {
        let a = PlaybackRequest(itemID: "item-1", startFromBeginning: true)
        let b = PlaybackRequest(itemID: "item-1", startFromBeginning: true)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a, b)
    }

    func test_id_differsAcrossItems() {
        XCTAssertNotEqual(PlaybackRequest(itemID: "item-1").id, PlaybackRequest(itemID: "item-2").id)
    }

    func test_startFromBeginning_defaultsToFalse() {
        XCTAssertFalse(PlaybackRequest(itemID: "item-1").startFromBeginning)
    }

    /// Same reasoning as `startFromBeginning`'s inclusion above — picking a
    /// different version on a second Play (or a remembered preference
    /// resolving differently) should also present a fresh sheet.
    func test_id_differsByMediaSourceIDForTheSameItem() {
        let original = PlaybackRequest(itemID: "item-1", mediaSourceID: "src-4k")
        let alternate = PlaybackRequest(itemID: "item-1", mediaSourceID: "src-1080p")
        XCTAssertNotEqual(original.id, alternate.id)
    }

    func test_mediaSourceID_defaultsToNil() {
        XCTAssertNil(PlaybackRequest(itemID: "item-1").mediaSourceID)
    }
}
