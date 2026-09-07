import XCTest
@testable import Dionysus

/// `ServerSetupViewModel.testConnection()` builds its own `JellyfinAPIClient`
/// internally (same pattern as `AppState`), so it's intercepted the same
/// way — see `AppStateTests` for why `URLProtocol.registerClass` is the
/// right tool here rather than session injection.
@MainActor
final class ServerSetupViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        super.tearDown()
    }

    func test_canSubmit_falseWhenAddressBlank() {
        let viewModel = ServerSetupViewModel()
        viewModel.address = "   "
        XCTAssertFalse(viewModel.canSubmit)

        viewModel.address = "jellyfin.example.com"
        XCTAssertTrue(viewModel.canSubmit)
    }

    func test_testConnection_invalidAddress_setsErrorAndReturnsNilWithoutHittingTheNetwork() async {
        let viewModel = ServerSetupViewModel()
        viewModel.address = "   "
        MockURLProtocol.requestHandler = { _ in XCTFail("Should not make a request for an invalid address"); throw MockURLProtocol.UnhandledRequest() }

        let result = await viewModel.testConnection()

        XCTAssertNil(result)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func test_testConnection_success_usesServerReportedNameAndRespectsHTTPSPreference() async {
        let viewModel = ServerSetupViewModel()
        viewModel.address = "jellyfin.example.com"
        viewModel.useHTTPS = true
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: PublicSystemInfo(serverName: "My Jellyfin"))
        }

        let result = await viewModel.testConnection()

        XCTAssertEqual(result?.name, "My Jellyfin")
        XCTAssertEqual(result?.baseURL.absoluteString, "https://jellyfin.example.com")
        XCTAssertNil(viewModel.errorMessage)
    }

    func test_testConnection_serverNameMissing_keepsHostAsTheDisplayName() async {
        let viewModel = ServerSetupViewModel()
        viewModel.address = "jellyfin.example.com"
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: PublicSystemInfo())
        }

        let result = await viewModel.testConnection()

        XCTAssertEqual(result?.name, "jellyfin.example.com")
    }

    /// `URLSession` follows a redirect transparently, so this ping can
    /// succeed on the *wrong* scheme — confirmed live against a real public
    /// Jellyfin server that 302-redirects plain HTTP to HTTPS. Without
    /// `correctingScheme(usingLandedURL:)`, `testConnection()` would hand
    /// back a `ServerConfiguration` still pointing at `http://`, which a
    /// later non-idempotent request (sign-in) can't recover from the way
    /// this GET-based ping just did.
    func test_testConnection_serverRedirectsToHTTPS_correctsSchemeInReturnedConfiguration() async {
        let viewModel = ServerSetupViewModel()
        viewModel.address = "demo.jellyfin.org/unstable"
        viewModel.useHTTPS = false

        MockURLProtocol.requestHandler = { request in
            let landedURL = URL(string: "https://demo.jellyfin.org/unstable/System/Info/Public")!
            let response = HTTPURLResponse(
                url: landedURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, try! JellyfinJSON.encoder.encode(PublicSystemInfo(serverName: "Unstable Demo")))
        }

        let result = await viewModel.testConnection()

        XCTAssertEqual(result?.baseURL.absoluteString, "https://demo.jellyfin.org/unstable")
        XCTAssertEqual(result?.name, "Unstable Demo")
    }

    func test_testConnection_unreachableServer_setsErrorAndReturnsNil() async {
        let viewModel = ServerSetupViewModel()
        viewModel.address = "jellyfin.example.com"
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }

        let result = await viewModel.testConnection()

        XCTAssertNil(result)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: syncHTTPSToggle
    //
    // `ServerConfiguration.parse` always honors an explicit scheme in the
    // typed address over `useHTTPS` (see its doc comment) — without this
    // sync, the toggle could show "on" while a leftover/pasted `http://…`
    // address silently connects over plain HTTP anyway. Confirmed live
    // (both Simulator and physical device) before this fix existed.

    func test_syncHTTPSToggle_explicitHTTPAddress_turnsToggleOff() {
        let viewModel = ServerSetupViewModel()
        viewModel.useHTTPS = true

        viewModel.syncHTTPSToggle(withAddress: "http://demo.jellyfin.org/unstable")

        XCTAssertFalse(viewModel.useHTTPS)
    }

    func test_syncHTTPSToggle_explicitHTTPSAddress_turnsToggleOn() {
        let viewModel = ServerSetupViewModel()
        viewModel.useHTTPS = false

        viewModel.syncHTTPSToggle(withAddress: "https://demo.jellyfin.org/unstable")

        XCTAssertTrue(viewModel.useHTTPS)
    }

    func test_syncHTTPSToggle_bareHostOrHostAndPort_leavesToggleUntouched() {
        let viewModel = ServerSetupViewModel()
        viewModel.useHTTPS = true

        viewModel.syncHTTPSToggle(withAddress: "192.168.1.50:8096")
        XCTAssertTrue(viewModel.useHTTPS)

        viewModel.useHTTPS = false
        viewModel.syncHTTPSToggle(withAddress: "jellyfin.example.com")
        XCTAssertFalse(viewModel.useHTTPS)
    }
}
