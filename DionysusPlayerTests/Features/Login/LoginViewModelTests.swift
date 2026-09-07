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
}
