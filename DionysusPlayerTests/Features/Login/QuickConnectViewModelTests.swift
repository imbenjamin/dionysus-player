import XCTest
@testable import Dionysus

/// `QuickConnectViewModel`'s poll loop against `MockURLProtocol`, with a
/// millisecond poll interval so a test runs in well under a second.
@MainActor
final class QuickConnectViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!

    override func tearDown() async throws {
        MockURLProtocol.reset()
        ConnectivityMonitor.shared.reset()
        try await super.tearDown()
    }

    private func makeViewModel() -> QuickConnectViewModel {
        let client = JellyfinAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession())
        return QuickConnectViewModel(client: client, pollInterval: .milliseconds(10))
    }

    private static func result(authenticated: Bool) -> QuickConnectResult {
        QuickConnectResult(secret: "abc123", code: "482913", authenticated: authenticated)
    }

    func test_run_pollsUntilApprovedThenSignsInWithTheSecret() async {
        var polls = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/QuickConnect/Initiate" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: false))
            }
            polls += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: polls >= 3))
        }
        let viewModel = makeViewModel()
        var signedInWith: String?

        await viewModel.run { signedInWith = $0 }

        XCTAssertEqual(signedInWith, "abc123")
        XCTAssertEqual(polls, 3)
        XCTAssertEqual(viewModel.state, .authorizing)
    }

    func test_run_showsTheCodeWhileWaiting() async throws {
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: false))
        }
        let viewModel = makeViewModel()
        let task = Task { await viewModel.run { _ in XCTFail("Never approved") } }

        try await waitUntil { viewModel.state == .waiting(code: "482913") }
        task.cancel()
        await task.value
    }

    func test_run_unknownSecret_expires() async {
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/QuickConnect/Initiate" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: false))
            }
            return MockURLProtocol.jsonResponse(for: request, status: 404, body: Data(#""Unknown secret""#.utf8))
        }
        let viewModel = makeViewModel()

        await viewModel.run { _ in XCTFail("An expired code can't sign in") }

        XCTAssertEqual(viewModel.state, .expired)
    }

    /// One dropped poll shouldn't discard a code the user may be typing on
    /// another device right now.
    func test_run_toleratesATransientPollFailure() async {
        var polls = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/QuickConnect/Initiate" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: false))
            }
            polls += 1
            if polls == 1 { throw URLError(.timedOut) }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: true))
        }
        let viewModel = makeViewModel()
        var signedIn = false

        await viewModel.run { _ in signedIn = true }

        XCTAssertTrue(signedIn)
    }

    func test_run_repeatedPollFailures_fail() async {
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/QuickConnect/Initiate" {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: false))
            }
            return MockURLProtocol.jsonResponse(for: request, status: 500, body: Data())
        }
        let viewModel = makeViewModel()

        await viewModel.run { _ in XCTFail("Never approved") }

        guard case .failed = viewModel.state else {
            return XCTFail("Expected .failed, got \(viewModel.state)")
        }
    }

    /// Quick Connect turned off answers `Initiate` with 401.
    func test_run_initiateRefused_fails() async {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(for: request, status: 401, body: Data(#""Quick connect is disabled""#.utf8))
        }
        let viewModel = makeViewModel()

        await viewModel.run { _ in XCTFail("Never approved") }

        guard case .failed = viewModel.state else {
            return XCTFail("Expected .failed, got \(viewModel.state)")
        }
    }

    func test_run_signInFailureAfterApproval_fails() async {
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: true))
        }
        let viewModel = makeViewModel()

        await viewModel.run { _ in throw JellyfinAPIError.http(status: 500, message: nil) }

        guard case .failed = viewModel.state else {
            return XCTFail("Expected .failed, got \(viewModel.state)")
        }
    }

    /// Dismissing the sheet cancels `.task(id:)`; the loop must stop polling
    /// rather than keep a request going behind a screen that's gone.
    func test_run_cancelled_stopsPolling() async throws {
        var polls = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path != "/QuickConnect/Initiate" { polls += 1 }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: Self.result(authenticated: false))
        }
        let viewModel = makeViewModel()
        let task = Task { await viewModel.run { _ in XCTFail("Never approved") } }
        try await waitUntil { polls >= 2 }

        task.cancel()
        await task.value
        let pollsAtCancel = polls
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertLessThanOrEqual(polls, pollsAtCancel + 1, "At most the poll already in flight")
    }

    func test_spokenCode_separatesDigits() {
        XCTAssertEqual(QuickConnectViewModel.spokenCode("482913"), "4 8 2 9 1 3")
    }
}
