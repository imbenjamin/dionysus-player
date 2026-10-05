import XCTest

/// A page still loading keeps focus on its loading indicator, so the
/// shell's three-second fallback doesn't open the sidebar over it, where
/// Menu on a top-level page leaves the app (Benjamin, 2026-10-05; seen on a
/// slow server). Once the content lands, the page's first item takes focus.
final class LoadingJourneyTests: TVUITestCase {
    private func loading(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[A11yID.TV.Detail.loading]
    }

    func test_homeLoadingSlowly_keepsTheSidebarShut_thenFocusesPlay() {
        let app = launch(scenario: "slowItems", seedSession: true)
        XCTAssertTrue(waitForFocus(loading(app), timeout: 10), "The loading indicator has focus")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(loading(app).hasFocus, "Past the shell's three seconds, still on the indicator")
        XCTAssertTrue(waitForCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "The sidebar stays shut")
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay], timeout: 20), "Play takes focus once Home loads")
    }

    func test_aLibraryLoadingSlowly_keepsTheSidebarShut_thenFocusesItsFirstTile() {
        let app = launch(scenario: "slowItems", seedSession: true)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay], timeout: 25))
        openRailFromHome(app)
        pressDown(until: app.buttons[A11yID.TV.Sidebar.library(UITestFixtureIdentity.moviesLibraryID)])
        press(.select)
        XCTAssertTrue(waitForFocus(loading(app), timeout: 10), "The loading indicator has focus")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(loading(app).hasFocus, "Past the shell's three seconds, still on the indicator")
        XCTAssertTrue(waitForFocus(firstLibraryTile(app), timeout: 20), "The first title takes focus once the library loads")
    }
}
