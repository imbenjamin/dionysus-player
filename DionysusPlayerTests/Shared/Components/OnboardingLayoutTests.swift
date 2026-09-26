import SwiftUI
import XCTest
@testable import Dionysus

/// The pre-sign-in journey's composition and orientation rules, checked
/// against window and screen sizes measured on each device class — the sizes
/// the thresholds were chosen from.
final class OnboardingLayoutTests: XCTestCase {
    // MARK: Composition

    func test_resolve_phonesAreCompactWhateverTheirSizeClass() {
        // iPhone 17 portrait.
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 402, height: 874), horizontalSizeClass: .compact), .compact)
        // A Pro Max in landscape reports a regular size class — only the
        // portrait lock keeps a phone out of the iPad compositions.
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 440, height: 956), horizontalSizeClass: .compact), .compact)
        // A foldable's outer screen.
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 466, height: 678), horizontalSizeClass: .compact), .compact)
    }

    func test_resolve_iPadPortraitIsRegularAndLandscapeIsLandscape() {
        // iPad Pro 13-inch.
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 1032, height: 1376), horizontalSizeClass: .regular), .regular)
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 1376, height: 1032), horizontalSizeClass: .regular), .landscape)
        // iPad mini, the smallest iPad.
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 744, height: 1133), horizontalSizeClass: .regular), .regular)
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 1133, height: 744), horizontalSizeClass: .regular), .landscape)
    }

    /// The unfolded inner screen held sideways: 951pt wide, which the first
    /// cut's 1000pt threshold sent to the portrait composition.
    func test_resolve_unfoldedFoldableIsLandscape() {
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 951, height: 669), horizontalSizeClass: .regular), .landscape)
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 669, height: 951), horizontalSizeClass: .regular), .regular)
    }

    /// A narrow Split View or Slide Over window reports a compact size class
    /// on an iPad and gets the phone composition.
    func test_resolve_narrowIPadWindowIsCompact() {
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 507, height: 1032), horizontalSizeClass: .compact), .compact)
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 320, height: 1032), horizontalSizeClass: .compact), .compact)
    }

    func test_resolve_regularSizeClassButNarrowWindowStaysCompact() {
        XCTAssertEqual(OnboardingLayout.resolve(windowSize: CGSize(width: 580, height: 900), horizontalSizeClass: .regular), .compact)
    }

    func test_isShortLandscape_forTheFoldableAndIPadMiniButNotLargerIPads() {
        XCTAssertTrue(OnboardingLayout.isShortLandscape(.landscape, windowSize: CGSize(width: 951, height: 669)))
        XCTAssertTrue(OnboardingLayout.isShortLandscape(.landscape, windowSize: CGSize(width: 1133, height: 744)))
        XCTAssertFalse(OnboardingLayout.isShortLandscape(.landscape, windowSize: CGSize(width: 1180, height: 820)))
        XCTAssertFalse(OnboardingLayout.isShortLandscape(.landscape, windowSize: CGSize(width: 1376, height: 1032)))
        XCTAssertFalse(OnboardingLayout.isShortLandscape(.regular, windowSize: CGSize(width: 669, height: 700)))
    }

    // MARK: Orientation

    func test_isPhoneSized_coversEveryPhoneScreenButNotTheFoldablesInnerOrAnyIPad() {
        XCTAssertTrue(RotationLock.isPhoneSized(CGSize(width: 402, height: 874)))
        XCTAssertTrue(RotationLock.isPhoneSized(CGSize(width: 956, height: 440)), "Either orientation")
        XCTAssertTrue(RotationLock.isPhoneSized(CGSize(width: 466, height: 678)), "A foldable's outer screen")
        XCTAssertFalse(RotationLock.isPhoneSized(CGSize(width: 669, height: 951)), "A foldable's inner screen")
        XCTAssertFalse(RotationLock.isPhoneSized(CGSize(width: 744, height: 1133)), "iPad mini")
    }

    // MARK: Avatar rows

    func test_rows_balancesRatherThanStrandingTheLastTile() {
        // Five tiles, four fit: 3 + 2, not 4 + 1.
        let rows = CenteredFlowLayout.rows(count: 5, itemWidth: 150, spacing: 20, width: 700)
        XCTAssertEqual(rows, [0..<3, 3..<5])
    }

    func test_rows_oneRowWhenEverythingFits() {
        XCTAssertEqual(CenteredFlowLayout.rows(count: 3, itemWidth: 104, spacing: 20, width: 354), [0..<3])
    }

    func test_rows_atLeastOnePerRowWhenNothingFits() {
        XCTAssertEqual(CenteredFlowLayout.rows(count: 2, itemWidth: 150, spacing: 20, width: 100), [0..<1, 1..<2])
    }

    func test_rows_noTilesNoRows() {
        XCTAssertEqual(CenteredFlowLayout.rows(count: 0, itemWidth: 150, spacing: 20, width: 700), [])
    }
}
