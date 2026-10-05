import UIKit
import XCTest
@testable import Dionysus

/// A second Play while the player is up, or still coming up, is refused
/// (M3 review): an impatient second Select on the hero, landing after its
/// Next Up lookup, otherwise stacked a second player and a second detail
/// page beneath it.
@MainActor
final class TVPlayerPresenterTests: XCTestCase {
    private final class FakePlayer: UIViewController, TVPlayerPresentation {}

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
}
