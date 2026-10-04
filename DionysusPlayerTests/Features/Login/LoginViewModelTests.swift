import XCTest
@testable import Dionysus

/// `LoginViewModel` itself has little logic — it mostly delegates to
/// `AppState.signIn` — but that delegation, the `canSubmit` gate, and the
/// user-facing error message on failure were all previously unverified.
@MainActor
final class LoginViewModelTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.LoginViewModelTests"
    private let credentialsKey = "server.credentials"

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        KeychainStore.delete(forKey: credentialsKey)
        super.tearDown()
    }

    private func makeSignedOutAppState() -> AppState {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(sessionStore: ServerSessionStore(defaults: defaults))
        appState.completeServerSetup(ServerConfiguration(name: "Home", baseURL: URL(string: "https://jellyfin.example.com")!))
        return appState
    }

    func test_canSubmit_falseWhenUsernameBlankOrWhitespace() {
        let viewModel = LoginViewModel()
        viewModel.username = "   "
        XCTAssertFalse(viewModel.canSubmit)

        viewModel.username = "ben"
        XCTAssertTrue(viewModel.canSubmit)
    }

    func test_signIn_success_clearsErrorAndSignsAppStateIn() async {
        let viewModel = LoginViewModel()
        viewModel.username = "ben"
        viewModel.password = "hunter2"
        let appState = makeSignedOutAppState()
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(
                for: request,
                value: AuthenticationResult(user: UserDto(id: "user-1", name: "ben"), accessToken: "tok", serverId: nil)
            )
        }

        await viewModel.signIn(using: appState)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isSigningIn)
        XCTAssertEqual(appState.currentUser?.id, "user-1")
        XCTAssertEqual(appState.phase, .main)
    }

    func test_signIn_failure_setsUserFacingErrorMessageAndLeavesAppStateSignedOut() async {
        let viewModel = LoginViewModel()
        viewModel.username = "ben"
        viewModel.password = "wrong"
        let appState = makeSignedOutAppState()
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 401, body: Data()) }

        await viewModel.signIn(using: appState)

        XCTAssertEqual(viewModel.errorMessage, "Couldn't sign in. Check your username and password.")
        XCTAssertFalse(viewModel.isSigningIn)
        XCTAssertEqual(appState.phase, .login)
    }
    // MARK: Quick Connect availability

    func test_quickConnectAvailability_followsTheServer() async {
        let viewModel = LoginViewModel()
        let appState = makeSignedOutAppState()
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, body: Data("true".utf8))
        }

        await viewModel.loadQuickConnectAvailability(using: appState)

        XCTAssertTrue(viewModel.isQuickConnectAvailable)
    }

    /// A server that can't answer never gets a button that would only fail.
    func test_quickConnectAvailability_hiddenWhenTheCheckFails() async {
        let viewModel = LoginViewModel()
        let appState = makeSignedOutAppState()
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }

        await viewModel.loadQuickConnectAvailability(using: appState)

        XCTAssertFalse(viewModel.isQuickConnectAvailable)
    }

    // MARK: Public users and branding

    private nonisolated static let publicUsersJSON = #"""
    [{"Name":"Ben","Id":"u-ben","HasPassword":false},{"Name":"Sam","Id":"u-sam","HasPassword":true}]
    """#

    /// `nonisolated` and `static`: a handler built inside a `@MainActor` test
    /// method inherits that isolation, and traps when `URLProtocol` calls it
    /// off the main thread.
    private nonisolated static func respond(users: String = publicUsersJSON, branding: String = #"{"SplashscreenEnabled":false}"#) {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/Users/Public") {
                return MockURLProtocol.jsonResponse(for: request, body: Data(users.utf8))
            }
            if path.hasSuffix("/Branding/Configuration") {
                return MockURLProtocol.jsonResponse(for: request, body: Data(branding.utf8))
            }
            if path.hasSuffix("/QuickConnect/Enabled") {
                return MockURLProtocol.jsonResponse(for: request, body: Data("true".utf8))
            }
            if path.hasSuffix("/Users/AuthenticateByName") {
                let body = request.capturedHTTPBody.flatMap { try? JellyfinJSON.decoder.decode(AuthenticateByNameRequest.self, from: $0) }
                guard body?.pw == "" || body?.pw == "right" else {
                    return MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
                }
                return try MockURLProtocol.encodedJSONResponse(
                    for: request,
                    value: AuthenticationResult(user: UserDto(id: "u", name: body?.username ?? ""), accessToken: "tok", serverId: nil)
                )
            }
            return MockURLProtocol.jsonResponse(for: request, status: 404, body: Data())
        }
    }

    func test_load_listsTheServersUsersAndItsQuickConnect() async {
        let viewModel = LoginViewModel()
        Self.respond()

        await viewModel.load(using: makeSignedOutAppState())

        guard case .loaded(let users) = viewModel.usersState else {
            return XCTFail("Expected the users to load, got \(viewModel.usersState)")
        }
        XCTAssertEqual(users.map(\.name), ["Ben", "Sam"])
        XCTAssertTrue(viewModel.isQuickConnectAvailable)
        XCTAssertNil(viewModel.splashscreenURL)
        XCTAssertNil(viewModel.disclaimer)
    }

    /// Every user hidden from the login screen: the plain form, not an error.
    func test_load_noListedUsersFallsBackToTheForm() async {
        let viewModel = LoginViewModel()
        Self.respond(users: "[]")

        await viewModel.load(using: makeSignedOutAppState())

        XCTAssertEqual(viewModel.usersState, .unavailable)
        XCTAssertNil(viewModel.errorMessage)
    }

    func test_load_serverThatCantListUsersFallsBackToTheForm() async {
        let viewModel = LoginViewModel()
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }

        await viewModel.load(using: makeSignedOutAppState())

        XCTAssertEqual(viewModel.usersState, .unavailable)
        XCTAssertFalse(viewModel.isQuickConnectAvailable)
    }

    /// The splashscreen is only asked for once the server says it has one —
    /// it's off by default and answers 404 then.
    func test_load_splashscreenOnlyWhenTheServerHasTurnedItOn() async {
        let viewModel = LoginViewModel()
        Self.respond(branding: #"{"LoginDisclaimer":"Reset daily.<br/>\nBe nice &amp; enjoy.","SplashscreenEnabled":true}"#)

        await viewModel.load(using: makeSignedOutAppState())

        XCTAssertEqual(viewModel.splashscreenURL?.path, "/Branding/Splashscreen")
        XCTAssertEqual(viewModel.disclaimer, "Reset daily.\n\nBe nice & enjoy.")
    }

    // MARK: Choosing a user

    func test_choose_passwordlessUserSignsInAtOnceWithAnEmptyPassword() async throws {
        let viewModel = LoginViewModel()
        let appState = makeSignedOutAppState()
        Self.respond()

        await viewModel.choose(UserDto(id: "u-ben", name: "Ben", hasPassword: false), using: appState)

        XCTAssertEqual(appState.phase, .main)
        let body = try XCTUnwrap(MockURLProtocol.lastRequest?.capturedHTTPBody)
        let posted = try JellyfinJSON.decoder.decode(AuthenticateByNameRequest.self, from: body)
        XCTAssertEqual(posted.username, "Ben")
        XCTAssertEqual(posted.pw, "")
        XCTAssertNil(viewModel.selectedUser)
    }

    func test_choose_userWithAPasswordIsAskedForItAndTappingAgainDeselects() async {
        let viewModel = LoginViewModel()
        let appState = makeSignedOutAppState()
        let sam = UserDto(id: "u-sam", name: "Sam", hasPassword: true)
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Choosing a user with a password shouldn't sign in yet")
            throw MockURLProtocol.UnhandledRequest()
        }

        await viewModel.choose(sam, using: appState)
        XCTAssertEqual(viewModel.selectedUser, sam)

        await viewModel.choose(sam, using: appState)
        XCTAssertNil(viewModel.selectedUser)
        XCTAssertEqual(appState.phase, .login)
    }

    /// `HasPassword: true` isn't proof a password is needed (Jellyfin's demo
    /// server says it of an account that takes an empty one), so an empty
    /// submission goes to the server rather than being blocked here.
    func test_signInSelectedUser_allowsAnEmptyPassword() async {
        let viewModel = LoginViewModel()
        let appState = makeSignedOutAppState()
        Self.respond()
        await viewModel.choose(UserDto(id: "u-sam", name: "Sam", hasPassword: true), using: appState)

        await viewModel.signInSelectedUser(using: appState)

        XCTAssertEqual(appState.phase, .main)
    }

    func test_signInSelectedUser_wrongPasswordKeepsThemSelectedWithAnError() async {
        let viewModel = LoginViewModel()
        let appState = makeSignedOutAppState()
        let sam = UserDto(id: "u-sam", name: "Sam", hasPassword: true)
        Self.respond()
        await viewModel.choose(sam, using: appState)
        viewModel.selectedUserPassword = "wrong"

        await viewModel.signInSelectedUser(using: appState)

        XCTAssertEqual(appState.phase, .login)
        XCTAssertEqual(viewModel.selectedUser, sam)
        XCTAssertNil(viewModel.signingInUser, "The grid should come back for another try.")
        XCTAssertEqual(viewModel.errorMessage, "Couldn't sign in. Check the password and try again.")
        XCTAssertFalse(viewModel.isSigningIn)
    }

    func test_signInSelectedUser_rightPasswordSignsIn() async {
        let viewModel = LoginViewModel()
        let appState = makeSignedOutAppState()
        Self.respond()
        await viewModel.choose(UserDto(id: "u-sam", name: "Sam", hasPassword: true), using: appState)
        viewModel.selectedUserPassword = "right"

        await viewModel.signInSelectedUser(using: appState)

        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.sessionStore.credentials?.username, "Sam")
    }

    // MARK: Disclaimer

    func test_disclaimer_convertsBreaksAndStripsOtherMarkup() {
        XCTAssertEqual(
            LoginDisclaimer.plainText(from: "Line one<br>Line two<BR />Line <b>three</b>"),
            "Line one\nLine two\nLine three"
        )
    }

    func test_disclaimer_decodesEntitiesWithoutDoubleDecoding() {
        XCTAssertEqual(LoginDisclaimer.plainText(from: "Tom &amp; Jerry &lt;3"), "Tom & Jerry <3")
        XCTAssertEqual(LoginDisclaimer.plainText(from: "Literally &amp;lt;"), "Literally &lt;")
    }

    func test_disclaimer_blankOrMarkupOnlyIsNone() {
        XCTAssertNil(LoginDisclaimer.plainText(from: "   "))
        XCTAssertNil(LoginDisclaimer.plainText(from: "<br/><p></p>"))
    }
}
