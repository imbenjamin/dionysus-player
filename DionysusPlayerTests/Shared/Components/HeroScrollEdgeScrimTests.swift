import XCTest
@testable import Dionysus

/// The cross-fade rule behind `HeroScrollEdgeScrim`: "over the hero" (0) while
/// the hero is under the bars, "hero gone" (1) once it has scrolled away, and 1
/// throughout without a hero. The same value decides the status bar's colour.
final class HeroScrollEdgeScrimTests: XCTestCase {
    /// An iPhone 17-sized page: bars end 116pt down, hero 470pt tall.
    private let barBottom: CGFloat = 116
    private let heroHeight: CGFloat = 470

    private func progress(scrolled: CGFloat, heroHeight: CGFloat?) -> Double {
        HeroScrollEdgeScrim.progress(scrolled: scrolled, heroHeight: heroHeight, barBottom: barBottom)
    }

    func test_progress_isZeroAtRest() {
        XCTAssertEqual(progress(scrolled: 0, heroHeight: heroHeight), 0)
    }

    func test_progress_staysZeroUntilTheHeroBottomNearsTheBars() {
        // The hero's bottom is exactly `rampDistance` below the bars.
        let rampStart = heroHeight - barBottom - HeroScrollEdgeScrim.rampDistance
        XCTAssertEqual(progress(scrolled: rampStart, heroHeight: heroHeight), 0)
    }

    func test_progress_isHalfwayMidRamp() {
        let midRamp = heroHeight - barBottom - HeroScrollEdgeScrim.rampDistance / 2
        XCTAssertEqual(progress(scrolled: midRamp, heroHeight: heroHeight), 0.5)
    }

    func test_progress_isFullOnceTheHeroBottomReachesTheBars() {
        XCTAssertEqual(progress(scrolled: heroHeight - barBottom, heroHeight: heroHeight), 1)
        XCTAssertEqual(progress(scrolled: 5000, heroHeight: heroHeight), 1)
    }

    func test_progress_isZeroWhenPulledDownPastRest() {
        // Pull-to-refresh on Home scrolls to a negative offset.
        XCTAssertEqual(progress(scrolled: -120, heroHeight: heroHeight), 0)
    }

    func test_progress_isFullWithoutAHero() {
        XCTAssertEqual(progress(scrolled: 0, heroHeight: nil), 1)
        XCTAssertEqual(progress(scrolled: 0, heroHeight: 0), 1)
    }

    /// Quantised, so scrolling within the ramp reports a small set of values
    /// rather than a new one every frame.
    func test_progress_isQuantised() {
        let value = progress(scrolled: heroHeight - barBottom - 40.123, heroHeight: heroHeight)
        XCTAssertEqual(value, (value * HeroScrollEdgeScrim.progressSteps).rounded() / HeroScrollEdgeScrim.progressSteps)
    }

    // MARK: isOverHero

    func test_isOverHero_atRestAndEarlyInTheCrossFade() {
        XCTAssertTrue(HeroScrollEdgeScrim.isOverHero(progress: 0))
        XCTAssertTrue(HeroScrollEdgeScrim.isOverHero(progress: 0.49))
    }

    func test_isOverHero_flipsAtTheMidpoint() {
        XCTAssertFalse(HeroScrollEdgeScrim.isOverHero(progress: 0.5))
        XCTAssertFalse(HeroScrollEdgeScrim.isOverHero(progress: 1))
    }

    /// No hero means the page's own colour scheme, never a forced light status bar.
    func test_isOverHero_neverWithoutAHero() {
        let progress = HeroScrollEdgeScrim.progress(scrolled: 0, heroHeight: nil, barBottom: barBottom)
        XCTAssertFalse(HeroScrollEdgeScrim.isOverHero(progress: progress))
    }

    // MARK: solidFraction

    func test_solidFraction_endsAtTheBars() {
        let fraction = HeroScrollEdgeScrim.solidFraction(barBottom: barBottom)
        XCTAssertEqual(fraction, barBottom / (barBottom + HeroScrollEdgeScrim.fadeHeight), accuracy: 0.0001)
    }

    func test_solidFraction_isZeroBeforeTheBarsAreMeasured() {
        XCTAssertEqual(HeroScrollEdgeScrim.solidFraction(barBottom: 0), 0)
    }
}

/// The hand-off behind the status bar's colour: one page owns it at a time, and
/// a page that has already been replaced can't clear its replacement's value.
@MainActor
final class HeroStatusBarSchemeTests: XCTestCase {
    func test_claim_setsTheScheme() {
        let store = HeroStatusBarScheme()
        store.claim(UUID(), scheme: .dark)
        XCTAssertEqual(store.scheme, .dark)
    }

    func test_release_byTheOwner_clearsTheScheme() {
        let store = HeroStatusBarScheme()
        let page = UUID()
        store.claim(page, scheme: .dark)
        store.release(page)
        XCTAssertNil(store.scheme)
    }

    /// A push shows the new page before the old one disappears.
    func test_release_byAReplacedPage_leavesTheNewPagesScheme() {
        let store = HeroStatusBarScheme()
        let home = UUID()
        let detail = UUID()
        store.claim(home, scheme: .light)
        store.claim(detail, scheme: .dark)
        store.release(home)
        XCTAssertEqual(store.scheme, .dark)
    }

    /// Popping back: the revealed page claims again as it reappears.
    func test_claim_afterTheOwnerLeaves_takesOver() {
        let store = HeroStatusBarScheme()
        let home = UUID()
        let detail = UUID()
        store.claim(detail, scheme: .light)
        store.claim(home, scheme: .dark)
        store.release(detail)
        XCTAssertEqual(store.scheme, .dark)
    }

    func test_claim_updatesTheOwnersSchemeAsItScrolls() {
        let store = HeroStatusBarScheme()
        let page = UUID()
        store.claim(page, scheme: .dark)
        store.claim(page, scheme: .light)
        XCTAssertEqual(store.scheme, .light)
    }
}
