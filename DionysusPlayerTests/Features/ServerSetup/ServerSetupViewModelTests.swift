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

    func test_testConnection_unreachableServer_setsErrorAndReturnsNil() async {
        let viewModel = ServerSetupViewModel()
        viewModel.address = "jellyfin.example.com"
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }

        let result = await viewModel.testConnection()

        XCTAssertNil(result)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}
