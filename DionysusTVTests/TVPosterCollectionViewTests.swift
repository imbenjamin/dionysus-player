import UIKit
import XCTest
@testable import Dionysus

/// Focus arriving in the grid from outside is when the posters SwiftUI's
/// focus left looking focused are told to look again
/// (`TVPosterCollectionView.didUpdateFocus`). Moves inside the grid already
/// reach the two posters concerned.
@MainActor
final class TVPosterCollectionViewTests: XCTestCase {
    private let grid = UIView()
    private let poster = UIView()
    private let otherPoster = UIView()
    private let header = UIView()

    override func setUp() {
        super.setUp()
        let cell = UIView()
        cell.addSubview(poster)
        grid.addSubview(cell)
        grid.addSubview(otherPoster)
    }

    func test_focusFromOutsideTheGrid_entersIt() {
        XCTAssertTrue(TVPosterCollectionView.focusEntered(from: header, to: poster, in: grid))
    }

    func test_focusFromNowhere_entersTheGrid() {
        XCTAssertTrue(TVPosterCollectionView.focusEntered(from: nil, to: poster, in: grid))
    }

    func test_aMoveBetweenPosters_isNotAnEntry() {
        XCTAssertFalse(TVPosterCollectionView.focusEntered(from: otherPoster, to: poster, in: grid))
    }

    func test_focusLeavingTheGrid_isNotAnEntry() {
        XCTAssertFalse(TVPosterCollectionView.focusEntered(from: poster, to: header, in: grid))
        XCTAssertFalse(TVPosterCollectionView.focusEntered(from: poster, to: nil, in: grid))
    }
}
