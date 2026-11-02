import UIKit
import XCTest
@testable import Dionysus

/// A second Play while the player is up, or still coming up, is refused
/// (M3 review): an impatient second Select on the hero, landing after its
/// Next Up lookup, otherwise stacked a second player and a second detail
/// page beneath it.
@MainActor
final class TVPlayerPresenterTests: XCTestCase {
    private final class FakePlayer: UIViewController, TVPlayerPresentation {
        func close() {}
    }

    func test_aPlayerAnywhereInTheChain_refusesAnother() {
        XCTAssertFalse(TVPlayerPresenter.canPresent(over: [UIViewController(), FakePlayer()]))
        XCTAssertFalse(TVPlayerPresenter.canPresent(over: [UIViewController(), FakePlayer(), UIViewController()]))
    }

    func test_noPlayerInTheChain_presents() {
        XCTAssertTrue(TVPlayerPresenter.canPresent(over: [UIViewController()]))
        XCTAssertTrue(TVPlayerPresenter.canPresent(over: [UIViewController(), UIViewController()]))
    }

    func test_noWindow_presentsNothing() {
        XCTAssertFalse(TVPlayerPresenter.canPresent(over: []))
    }

    /// Under VoiceOver the player presents its controls as a layer over
    /// itself, so the player isn't the top controller (M5 review).
    func test_thePlayerIsFound_withALayerAboveIt() {
        let player = FakePlayer()
        XCTAssertTrue(TVPlayerPresenter.player(in: [UIViewController(), player, UIViewController()]) === player)
        XCTAssertTrue(TVPlayerPresenter.player(in: [UIViewController(), player]) === player)
    }

    func test_noPlayerInTheChain_findsNone() {
        XCTAssertNil(TVPlayerPresenter.player(in: [UIViewController(), UIViewController()]))
        XCTAssertNil(TVPlayerPresenter.player(in: []))
    }
}
