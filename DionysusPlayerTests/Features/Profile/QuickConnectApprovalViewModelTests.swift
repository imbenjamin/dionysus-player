import XCTest
@testable import Dionysus

/// `QuickConnectApprovalViewModel` against `MockURLProtocol`: what a typed
/// code becomes, and how each of the server's answers reads to the user.
@MainActor
final class QuickConnectApprovalViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    override func tearDown() async throws {
        MockURLProtocol.reset()
        ConnectivityMonitor.shared.reset()
        try await super.tearDown()
    }

    private func makeViewModel(code: String? = "482913") -> QuickConnectApprovalViewModel {
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let viewModel = QuickConnectApprovalViewModel(client: client, userName: "Ben", serverName: "Home")
        if let code { viewModel.setCode(code) }
        return viewModel
    }

    private func failureMessage(_ viewModel: QuickConnectApprovalViewModel) -> String? {
        if case .failed(let message) = viewModel.state { return message }
        return nil
    }

    // MARK: Code entry

    func test_setCode_keepsDigitsOnlyUpToSix() {
        let viewModel = makeViewModel(code: nil)

        viewModel.setCode("Code: 482 913 7")

        XCTAssertEqual(viewModel.code, "482913")
    }

    /// `Character.isNumber` is true for more than 0–9; the server's codes are
    /// ASCII digits only.
    func test_setCode_dropsNonASCIINumerals() {
        let viewModel = makeViewModel(code: nil)

        viewModel.setCode("٤٨٢9١3")

        XCTAssertEqual(viewModel.code, "93")
    }

    func test_canSubmit_onlyWithSixDigits() {
        let viewModel = makeViewModel(code: "48291")
        XCTAssertFalse(viewModel.canSubmit)

        viewModel.setCode("482913")
        XCTAssertTrue(viewModel.canSubmit)
    }

    func test_editingAfterAFailure_clearsIt() async {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 404, body: Data())
        }
        let viewModel = makeViewModel()
        await viewModel.authorize()
        XCTAssertNotNil(failureMessage(viewModel))

        viewModel.setCode("48291")

        XCTAssertEqual(viewModel.state, .entering)
    }

    // MARK: Server answers

    func test_authorize_success_approves() async {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, body: Data("true".utf8))
        }
        let viewModel = makeViewModel()

        await viewModel.authorize()

        XCTAssertEqual(viewModel.state, .approved)
        XCTAssertFalse(viewModel.canSubmit, "An approved code can't be sent again.")
    }

    func test_authorize_unknownCode_explainsExpiry() async throws {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 404, body: Data())
        }
        let viewModel = makeViewModel()

        await viewModel.authorize()

        let message = try XCTUnwrap(failureMessage(viewModel))
        XCTAssertTrue(message.contains("10 minutes"), message)
    }

    /// Jellyfin answers an already-approved code with a bare 500.
    func test_authorize_serverError_mentionsAlreadyUsed() async throws {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }
        let viewModel = makeViewModel()

        await viewModel.authorize()

        let message = try XCTUnwrap(failureMessage(viewModel))
        XCTAssertTrue(message.contains("already have been used"), message)
    }

    /// A 401 is told apart by asking whether Quick Connect is still on.
    func test_authorize_401WithQuickConnectOff_saysItsOff() async throws {
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/QuickConnect/Enabled" {
                return MockURLProtocol.jsonResponse(for: request, body: Data("false".utf8))
            }
            return MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
        }
        let viewModel = makeViewModel()

        await viewModel.authorize()

        let message = try XCTUnwrap(failureMessage(viewModel))
        XCTAssertTrue(message.contains("turned off"), message)
    }

    func test_authorize_401WithQuickConnectOn_saysSessionExpired() async throws {
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/QuickConnect/Enabled" {
                return MockURLProtocol.jsonResponse(for: request, body: Data("true".utf8))
            }
            return MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
        }
        let viewModel = makeViewModel()

        await viewModel.authorize()

        let message = try XCTUnwrap(failureMessage(viewModel))
        XCTAssertTrue(message.contains("session has expired"), message)
    }

    func test_authorize_offline_namesTheServer() async throws {
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let viewModel = makeViewModel()

        await viewModel.authorize()

        let message = try XCTUnwrap(failureMessage(viewModel))
        XCTAssertTrue(message.contains("Home"), message)
    }

    func test_authorize_withoutSixDigits_sendsNothing() async {
        MockURLProtocol.requestHandler = { request in
            XCTFail("Nothing should be sent for an incomplete code")
            return MockURLProtocol.jsonResponse(for: request, body: Data("true".utf8))
        }
        let viewModel = makeViewModel(code: "123")

        await viewModel.authorize()

        XCTAssertEqual(viewModel.state, .entering)
    }

    // MARK: Availability

    func test_isAvailable_followsTheServer() async {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, body: Data("true".utf8))
        }
        let client = JellyfinAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession())

        let available = await QuickConnectApprovalViewModel.isAvailable(on: client)

        XCTAssertTrue(available)
    }

    func test_isAvailable_falseWhenTheCheckFails() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let client = JellyfinAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession())

        let available = await QuickConnectApprovalViewModel.isAvailable(on: client)

        XCTAssertFalse(available)
    }
}
