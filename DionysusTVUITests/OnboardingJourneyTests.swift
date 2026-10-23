import XCTest

final class OnboardingJourneyTests: TVUITestCase {
    /// Discovery lists the stub server with default focus on it, so one Select
    /// connects; the stub's public user list then shows, and choosing the
    /// passwordless user (second in the list, after one with a password) signs
    /// straight in.
    func test_selectDiscoveredServer_thenUser_reachesMain() {
        let app = launch()
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.passwordlessUserID)]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[A11yID.TV.Sidebar.home].exists, "No rail before signing in")
        press(.right)
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        let main = app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 10)
        if !main { attachTree() }
        XCTAssertTrue(main)
        XCTAssertTrue(waitForCollapsed(app.buttons[A11yID.TV.Sidebar.home]), "Signed in, the rail is there, collapsed")
    }

    /// Above five lockups the row scrolls, so the first one, which takes
    /// focus, and "Other" at the far end are each fully on screen when focused.
    func test_manyUsers_theRowScrolls_soEveryLockupIsReachable() {
        let app = launch(scenario: "manyUsers")
        connectToDiscoveredServer(app)
        let window = app.windows.firstMatch.frame
        let first = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(first, timeout: 10))
        XCTAssertGreaterThanOrEqual(first.frame.minX, 0, "The first lockup isn't cut off at the left edge")
        let other = app.buttons[A11yID.TV.Onboarding.otherUser]
        for _ in 0..<8 where !other.hasFocus {
            press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(waitForFocus(other))
        XCTAssertLessThanOrEqual(other.frame.maxX, window.maxX, "Other is fully on screen once focused")
    }

    /// Typing an address is the secondary route: a button below the found
    /// servers reveals the field.
    func test_enterServerAddress_revealsTheAddressField() {
        let app = launch()
        let enter = app.buttons[A11yID.TV.Onboarding.enterAddress]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        for _ in 0..<4 where !enter.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(enter))
        press(.select)
        let field = app.textFields[A11yID.TV.Onboarding.addressField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The button it was is gone, and tvOS would hand focus to the server
        // list's default; the field keeps it.
        XCTAssertTrue(waitForFocus(field), "The field takes focus")
        // With the field shown, Enter Server Address heads it rather than
        // being a button again (Benjamin, 2026-10-05).
        XCTAssertTrue(poll(timeout: 5) { !enter.exists }, "No longer a button")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.enterAddress].exists, "It stays as the field's heading")
    }

    /// Once the scan is over, Rescan scans again from an empty list
    /// (Benjamin, 2026-10-05); the servers are listed again once they answer.
    func test_rescan_afterTheScan_listsTheServersAgain() {
        let app = launch()
        let rescan = app.buttons[A11yID.TV.Onboarding.rescan]
        XCTAssertTrue(rescan.waitForExistence(timeout: 10), "Rescan once the scan is over")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.onboarding.server."))
        let found = rows.count
        XCTAssertGreaterThan(found, 0)
        for _ in 0..<6 where !rescan.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(rescan))
        press(.select)
        XCTAssertTrue(poll(timeout: 10) { rows.count == found && rescan.exists }, "The same servers, listed once each")
    }

    /// A user with a password goes to Quick Connect, not a keyboard; the stub
    /// approves the code on its first poll, which signs in.
    func test_passwordUser_signsInThroughQuickConnect() {
        let app = launch()
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[A11yID.TV.Main.heroPlay].waitForExistence(timeout: 15))
    }

    /// "Use Password Instead" is one press from the code, and opens a password
    /// field for the chosen user.
    func test_quickConnect_usePasswordInstead_showsThePasswordField() {
        let app = launch(scenario: "quickConnectPending")
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        let usePassword = app.buttons[A11yID.TV.Onboarding.usePassword]
        XCTAssertTrue(usePassword.waitForExistence(timeout: 10))
        // Read a digit at a time, as it's typed in.
        let code = UITestFixtureIdentity.quickConnectCode(1)
        XCTAssertEqual(
            app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].label,
            code.map(String.init).joined(separator: " ")
        )
        XCTAssertTrue(waitForFocus(usePassword))
        press(.select)
        XCTAssertTrue(app.secureTextFields[A11yID.TV.Onboarding.passwordField].waitForExistence(timeout: 5))
    }

    /// With Quick Connect off, a user with a password goes straight to the
    /// password field.
    func test_quickConnectDisabled_passwordUser_goesStraightToPassword() {
        let app = launch(scenario: "quickConnectDisabled")
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.secureTextFields[A11yID.TV.Onboarding.passwordField].waitForExistence(timeout: 5))
    }

    /// Change Server sits centred below the lockups; Down reaches it from
    /// any of them, not only one above it.
    func test_downFromTheFirstLockup_reachesChangeServer() {
        let app = launch()
        connectToDiscoveredServer(app)
        let first = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(first, timeout: 10))
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Onboarding.changeServer]))
    }

    /// The stub serves every profile picture as a transparent PNG, as the demo
    /// server's is. The avatar's middle stays dark once it loads: the monogram
    /// and its bright colour behind the picture showed through (store
    /// screenshots, 2026-10-23).
    func test_transparentProfilePicture_hidesTheMonogram() throws {
        let app = launch()
        connectToDiscoveredServer(app)
        let lockup = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(lockup, timeout: 10))
        // Unfocused, so no lift or highlight over the avatar.
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Onboarding.changeServer]))
        // The picture fades in over 0.3s once loaded.
        let deadline = Date().addingTimeInterval(5)
        var brightness = 1.0
        repeat {
            brightness = try avatarCentreBrightness(of: lockup)
            if brightness < 0.3 { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        XCTAssertLessThan(brightness, 0.3)
    }

    /// The mean of each pixel's brightest channel over the middle half of a
    /// lockup's avatar: 230pt across (`TVLoginView.lockupSize`), centred at
    /// the top, above the name.
    private func avatarCentreBrightness(of lockup: XCUIElement) throws -> Double {
        let cgImage = try XCTUnwrap(lockup.screenshot().image.cgImage)
        let side = Int(230 * CGFloat(cgImage.width) / lockup.frame.width)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0, count = 0.0
        for y in side / 4 ..< side * 3 / 4 {
            for x in (width - side) / 2 + side / 4 ..< (width - side) / 2 + side * 3 / 4 {
                let i = (y * width + x) * 4
                total += Double(max(pixels[i], pixels[i + 1], pixels[i + 2])) / 255
                count += 1
            }
        }
        return total / count
    }

    /// While the users load, Change Server is the way off a slow server
    /// (M5 review): disabled for everyone, nothing could take focus for up to
    /// the request's 20s. Only under VoiceOver does it wait.
    func test_changeServer_worksWhileTheUsersLoad() {
        let app = launch(scenario: "slowPublicUsers")
        connectToDiscoveredServer(app)
        let change = app.buttons[A11yID.TV.Onboarding.changeServer]
        XCTAssertTrue(waitForFocus(change, timeout: 10))
        XCTAssertFalse(app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)].exists)
        press(.select)
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10), "Change Server returns to Find Your Server")
    }

    /// Down from the password field goes to Sign In, not to Cancel beside it.
    func test_passwordField_downGoesToSignIn() {
        let app = launch(scenario: "quickConnectDisabled")
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        let field = app.secureTextFields[A11yID.TV.Onboarding.passwordField]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(field))
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Onboarding.passwordSignIn]))
    }

    /// An expired code hands focus to Get New Code, the one thing to do next
    /// (and VoiceOver hears the expiry; by ear).
    func test_quickConnect_expiredCode_focusesGetNewCode() {
        let app = launch(scenario: "quickConnectExpiring")
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        let getNewCode = app.buttons[A11yID.TV.Onboarding.getNewCode]
        XCTAssertTrue(getNewCode.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(getNewCode))
    }

    private func connectToDiscoveredServer(_ app: XCUIApplication) {
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(server), "The first discovered server must take default focus")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
    }
}
