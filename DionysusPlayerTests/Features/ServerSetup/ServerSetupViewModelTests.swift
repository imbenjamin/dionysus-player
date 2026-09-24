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

    // MARK: Discovery

    private let flix = DiscoveredServer(id: "flix", name: "Flix", address: URL(string: "http://192.168.0.222:8096/flix")!)
    private let secure = DiscoveredServer(id: "secure", name: "Secure", address: URL(string: "https://media.local:8920")!)

    func test_scanForServers_publishesServersInAnswerOrderAndFinishes() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: [flix, secure]))

        await viewModel.scanForServers()

        XCTAssertEqual(viewModel.discoveredServers, [flix, secure])
        XCTAssertEqual(viewModel.scanState, .finished)
    }

    func test_scanForServers_nothingAnswers_finishesEmpty() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))

        await viewModel.scanForServers()

        XCTAssertTrue(viewModel.discoveredServers.isEmpty)
        XCTAssertEqual(viewModel.scanState, .finished)
    }

    func test_scanForServers_accessDenied_reportsItAndKeepsWhateverAnswered() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: [flix], error: .localNetworkAccessDenied))

        await viewModel.scanForServers()

        XCTAssertEqual(viewModel.scanState, .failed(.localNetworkAccessDenied))
        XCTAssertEqual(viewModel.discoveredServers, [flix])
    }

    /// A rescan replaces the list rather than appending to it — a server that
    /// has gone away shouldn't linger.
    func test_scanForServers_rescan_replacesPreviousResults() async {
        let discovery = StubServerDiscovery(servers: [flix, secure])
        let viewModel = ServerSetupViewModel(discovery: discovery)
        await viewModel.scanForServers()

        discovery.servers = [secure]
        await viewModel.scanForServers()

        XCTAssertEqual(viewModel.discoveredServers, [secure])
    }

    func test_connectToDiscoveredServer_fillsAddressAndConnectsWithBasePath() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        viewModel.useHTTPS = true
        MockURLProtocol.requestHandler = { request in
            try MockURLProtocol.encodedJSONResponse(for: request, value: PublicSystemInfo(serverName: "Flix"))
        }

        let result = await viewModel.connect(to: flix)

        XCTAssertEqual(result?.baseURL.absoluteString, "http://192.168.0.222:8096/flix")
        XCTAssertEqual(viewModel.address, "http://192.168.0.222:8096/flix")
        XCTAssertFalse(viewModel.useHTTPS, "The toggle should follow the discovered address's scheme.")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/flix/System/Info/Public")
        XCTAssertNil(viewModel.connectingServerID)
    }

    /// Answered the UDP probe but not HTTP: the address stays in the field so
    /// the user can see what was tried and correct it.
    func test_connectToDiscoveredServer_unreachable_leavesAddressAndShowsError() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        MockURLProtocol.requestHandler = { request in MockURLProtocol.jsonResponse(for: request, status: 500, body: Data()) }

        let result = await viewModel.connect(to: secure)

        XCTAssertNil(result)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.address, "https://media.local:8920")
        XCTAssertTrue(viewModel.useHTTPS)
    }

    // MARK: Insecure fallback

    /// HTTPS on, advertised by LAN IP, certificate issued for a domain name —
    /// so the HTTPS address fails validation while HTTP on 8096 still answers.
    private let lanHTTPS = DiscoveredServer(id: "system-1", name: "Den", address: URL(string: "https://192.168.0.40:8920/jf")!)

    /// Fails HTTPS with `httpsError`; answers HTTP only on `httpPort`, with
    /// `/System/Info/Public` reporting `systemID`, and refuses every other port.
    private func scriptServer(httpsError: URLError.Code = .serverCertificateUntrusted, systemID: String? = "system-1", httpPort: Int? = 8096) {
        MockURLProtocol.requestHandler = { request in
            if request.url?.scheme == "https" { throw URLError(httpsError) }
            guard let httpPort, request.url?.port == httpPort else { throw URLError(.cannotConnectToHost) }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: PublicSystemInfo(serverName: "Den", id: systemID))
        }
    }

    func test_connect_httpsCertificateFails_httpAnswersAsSameServer_offersFallbackWithoutConnecting() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer()

        let result = await viewModel.connect(to: lanHTTPS)

        XCTAssertNil(result, "Nothing should connect until the user accepts.")
        let offer = try XCTUnwrap(viewModel.insecureFallbackOffer)
        XCTAssertEqual(offer.configuration.baseURL.absoluteString, "http://192.168.0.40:8096/jf", "Same host and base path, default HTTP port.")
        XCTAssertEqual(offer.configuration.name, "Den")
        XCTAssertEqual(offer.httpDisplayAddress, "192.168.0.40:8096/jf")
        XCTAssertNotNil(viewModel.errorMessage, "The certificate problem should be explained behind the alert.")
        XCTAssertFalse(viewModel.isTesting)
    }

    func test_acceptInsecureFallback_returnsTheTestedHTTPConfigurationAndFillsTheField() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer()
        _ = await viewModel.connect(to: lanHTTPS)

        let configuration = try XCTUnwrap(viewModel.acceptInsecureFallback())

        XCTAssertEqual(configuration.baseURL.absoluteString, "http://192.168.0.40:8096/jf")
        XCTAssertEqual(viewModel.address, "http://192.168.0.40:8096/jf")
        XCTAssertFalse(viewModel.useHTTPS)
        XCTAssertNil(viewModel.insecureFallbackOffer)
        XCTAssertNil(viewModel.errorMessage)
    }

    func test_declineInsecureFallback_clearsTheOfferButKeepsTheExplanation() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer()
        _ = await viewModel.connect(to: lanHTTPS)

        viewModel.declineInsecureFallback()

        XCTAssertNil(viewModel.insecureFallbackOffer)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.address, "https://192.168.0.40:8920/jf")
    }

    /// Something answering HTTP on 8096 that isn't the server discovered —
    /// never offered as though it were.
    func test_connect_httpAnswersWithADifferentSystemID_offersNothingAndAsksForThePort() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer(systemID: "someone-else")

        let result = await viewModel.connect(to: lanHTTPS)

        XCTAssertNil(result)
        XCTAssertNil(viewModel.insecureFallbackOffer)
        XCTAssertNotNil(viewModel.httpPortRequest)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// Ports are configurable, so 8096 is only a first guess: when it doesn't
    /// answer, the user is asked which port instead.
    func test_connect_defaultHTTPPortDoesNotAnswer_asksForThePort() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer(httpPort: 8097)

        let result = await viewModel.connect(to: lanHTTPS)

        XCTAssertNil(result)
        XCTAssertNil(viewModel.insecureFallbackOffer)
        let request = try XCTUnwrap(viewModel.httpPortRequest)
        XCTAssertEqual(request.server, lanHTTPS)
        XCTAssertNil(request.problem)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func test_tryHTTPPort_answeringPort_offersTheFallbackOnThatPort() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer(httpPort: 8097)
        _ = await viewModel.connect(to: lanHTTPS)
        let request = try XCTUnwrap(viewModel.httpPortRequest)

        await viewModel.tryHTTPPort(" 8097 ", for: request)

        XCTAssertNil(viewModel.httpPortRequest)
        XCTAssertEqual(viewModel.insecureFallbackOffer?.configuration.baseURL.absoluteString, "http://192.168.0.40:8097/jf")
        XCTAssertFalse(viewModel.isTesting)
        XCTAssertNil(viewModel.connectingServerID)
    }

    func test_tryHTTPPort_silentPort_asksAgainSayingSo() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer(httpPort: 8097)
        _ = await viewModel.connect(to: lanHTTPS)
        let request = try XCTUnwrap(viewModel.httpPortRequest)

        await viewModel.tryHTTPPort("9000", for: request)

        XCTAssertNil(viewModel.insecureFallbackOffer)
        let again = try XCTUnwrap(viewModel.httpPortRequest)
        XCTAssertEqual(again.server, lanHTTPS)
        XCTAssertNotNil(again.problem)
    }

    func test_tryHTTPPort_notAPort_asksAgainWithoutARequest() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer(httpPort: nil)
        _ = await viewModel.connect(to: lanHTTPS)
        let request = try XCTUnwrap(viewModel.httpPortRequest)
        MockURLProtocol.lastRequest = nil

        await viewModel.tryHTTPPort("70000", for: request)

        XCTAssertNotNil(viewModel.httpPortRequest?.problem)
        XCTAssertNil(MockURLProtocol.lastRequest, "An invalid port shouldn't be probed.")
    }

    func test_parsePort() {
        XCTAssertEqual(ServerSetupViewModel.parsePort("8096"), 8096)
        XCTAssertEqual(ServerSetupViewModel.parsePort(" 1 "), 1)
        XCTAssertEqual(ServerSetupViewModel.parsePort("65535"), 65535)
        XCTAssertNil(ServerSetupViewModel.parsePort("0"))
        XCTAssertNil(ServerSetupViewModel.parsePort("65536"))
        XCTAssertNil(ServerSetupViewModel.parsePort("80a"))
        XCTAssertNil(ServerSetupViewModel.parsePort(""))
    }

    /// Only a certificate failure earns the HTTP probe: an HTTPS server that
    /// simply isn't there has no reason to be tried unencrypted.
    func test_connect_httpsUnreachableForAnotherReason_neverTriesHTTP() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []))
        scriptServer(httpsError: .cannotConnectToHost)

        let result = await viewModel.connect(to: lanHTTPS)

        XCTAssertNil(result)
        XCTAssertNil(viewModel.insecureFallbackOffer)
        XCTAssertNil(viewModel.httpPortRequest)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.scheme, "https", "The only request should have been the HTTPS one.")
    }
}

/// Yields `servers`, then finishes — or fails with `error` if one is set.
private final class StubServerDiscovery: ServerDiscovering, @unchecked Sendable {
    var servers: [DiscoveredServer]
    let error: ServerDiscoveryError?

    init(servers: [DiscoveredServer], error: ServerDiscoveryError? = nil) {
        self.servers = servers
        self.error = error
    }

    func discoverServers() -> AsyncThrowingStream<DiscoveredServer, Error> {
        let servers = servers
        let error = error
        return AsyncThrowingStream { continuation in
            servers.forEach { continuation.yield($0) }
            continuation.finish(throwing: error)
        }
    }
}
