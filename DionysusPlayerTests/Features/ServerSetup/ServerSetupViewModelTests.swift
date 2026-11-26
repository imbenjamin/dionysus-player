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
        // Requests on `URLSession.shared` can't be stamped with a generation.
        MockURLProtocol.acceptsUnmarkedRequests = true
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

    /// For scans whose servers' versions aren't the point: without it each
    /// discovered server starts a real `/System/Info/Public` lookup that can
    /// outlive the test and land in a later one's `MockURLProtocol` handler.
    private static let noVersion: @Sendable (URL) async -> String? = { _ in nil }

    // MARK: Scanning on arrival

    func test_startScanOnArrival_scansOnceAndLeavesResultsAloneAfterwards() async throws {
        let discovery = StubServerDiscovery(servers: [flix])
        let viewModel = ServerSetupViewModel(discovery: discovery, versionLookup: Self.noVersion)

        viewModel.startScanOnArrival()
        try await waitUntil { viewModel.scanState == .finished }
        XCTAssertEqual(viewModel.discoveredServers, [flix])

        // Coming back to the screen (or `.task` running again) must not
        // throw the list away and scan over it.
        discovery.servers = []
        viewModel.startScanOnArrival()
        XCTAssertEqual(viewModel.scanState, .finished)
        XCTAssertEqual(viewModel.discoveredServers, [flix])
    }

    // MARK: Versions

    func test_scan_looksUpEachDiscoveredServersVersionInTheBackground() async throws {
        let viewModel = ServerSetupViewModel(
            discovery: StubServerDiscovery(servers: [flix, secure]),
            versionLookup: { address in address.scheme == "http" ? "10.11.11" : nil }
        )

        await viewModel.scanForServers()
        try await waitUntil { viewModel.serverVersions[self.flix.id] != nil }

        XCTAssertEqual(viewModel.serverVersions[flix.id], "10.11.11")
        // The HTTPS one couldn't be asked: no version, and no error either.
        XCTAssertNil(viewModel.serverVersions[secure.id])
        XCTAssertNil(viewModel.errorMessage)
    }

    func test_scan_looksUpAServersVersionOnlyOnceAcrossRescans() async throws {
        let lookups = LookupCounter()
        let viewModel = ServerSetupViewModel(
            discovery: StubServerDiscovery(servers: [flix]),
            versionLookup: { _ in
                await lookups.increment()
                return "10.11.11"
            }
        )

        await viewModel.scanForServers()
        try await waitUntil { viewModel.serverVersions[self.flix.id] != nil }
        await viewModel.scanForServers()
        // An absence (no second lookup): it would be a task started by the
        // rescan itself, so this only has to outlast a few actor hops.
        try await Task.sleep(for: .milliseconds(100))

        let count = await lookups.value
        XCTAssertEqual(count, 1)
    }

    func test_scanForServers_publishesServersInAnswerOrderAndFinishes() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: [flix, secure]), versionLookup: Self.noVersion)

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
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: [flix], error: .localNetworkAccessDenied), versionLookup: Self.noVersion)

        await viewModel.scanForServers()

        XCTAssertEqual(viewModel.scanState, .failed(.localNetworkAccessDenied))
        XCTAssertEqual(viewModel.discoveredServers, [flix])
    }

    /// A rescan replaces the list rather than appending to it — a server that
    /// has gone away shouldn't linger.
    func test_scanForServers_rescan_replacesPreviousResults() async {
        let discovery = StubServerDiscovery(servers: [flix, secure])
        let viewModel = ServerSetupViewModel(discovery: discovery, versionLookup: Self.noVersion)
        await viewModel.scanForServers()

        discovery.servers = [secure]
        await viewModel.scanForServers()

        XCTAssertEqual(viewModel.discoveredServers, [secure])
    }

    /// The Apple TV's Rescan clears the list as it starts (Benjamin,
    /// 2026-10-05), so what's listed is only what answered this time.
    func test_rescan_clearsTheListAtOnce_thenScans() async throws {
        let discovery = StubServerDiscovery(servers: [flix, secure])
        let viewModel = ServerSetupViewModel(discovery: discovery, versionLookup: Self.noVersion)
        await viewModel.scanForServers()

        discovery.servers = [secure]
        viewModel.rescan()
        XCTAssertEqual(viewModel.discoveredServers, [], "Cleared before anything answers")
        try await waitUntil { viewModel.scanState == .finished && !viewModel.discoveredServers.isEmpty }
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

    /// The question both apps show: the reason the last port failed, when
    /// there is one, ahead of what's asked.
    func test_httpPortRequest_message_leadsWithTheProblem() {
        let first = ServerSetupViewModel.HTTPPortRequest(server: lanHTTPS, problem: nil)
        XCTAssertTrue(first.message.hasPrefix(lanHTTPS.name))
        XCTAssertFalse(first.message.contains("\n"))

        let again = ServerSetupViewModel.HTTPPortRequest(server: lanHTTPS, problem: "Nothing on 9000.")
        XCTAssertEqual(again.message, "Nothing on 9000.\n\n" + first.message)
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

    // MARK: Certificate trust (#466)
    //
    // These inject their own `ServerTrustRegistry` to read the candidate back.
    // The probe's `ServerTrustDelegate.shared` answers from `.shared` instead,
    // which is never consulted here: `MockURLProtocol` raises no TLS challenge,
    // so the scripted failure count, not the candidate, decides each probe.

    /// What URLSession throws for a certificate the system refuses, carrying
    /// the presented chain as the real error does.
    private func certificateError(leaf: String = "selfSignedA") -> URLError {
        let trust = TLSFixtures.trust(leaf: leaf, anchors: [], host: "192.168.0.40")
        return URLError(.serverCertificateHasUnknownRoot, userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: trust])
    }

    /// `lanHTTPS`'s server (or `host`): HTTPS fails with `error` for the
    /// first `httpsFailures` requests, then answers; HTTP answers on 8096
    /// only. `onHTTPS` sees each HTTPS request's 1-based number first.
    private func scriptCertificateFailure(
        _ error: URLError,
        host: String = "192.168.0.40",
        httpsFailures: Int = .max,
        counter: HTTPSCounter = HTTPSCounter(),
        onHTTPS: (@Sendable (Int) -> Void)? = nil
    ) {
        MockURLProtocol.requestHandler = { request in
            guard request.url?.host == host else { throw URLError(.cannotConnectToHost) }
            if request.url?.scheme == "https" {
                let number = counter.next()
                onHTTPS?(number)
                if number <= httpsFailures { throw error }
            }
            guard request.url?.scheme == "https" || request.url?.port == 8096 else { throw URLError(.cannotConnectToHost) }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: PublicSystemInfo(serverName: "Den", id: "system-1"))
        }
    }

    nonisolated private static func selfSignedTrustDecision(in registry: ServerTrustRegistry) -> ServerTrustDecision {
        registry.decide(TLSFixtures.trust(leaf: "selfSignedA", anchors: [], host: "192.168.0.40"), host: "192.168.0.40", port: 8920)
    }

    func testTypedHTTPSAddressWithAnUnverifiableCertificateOffersTrust() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: ServerTrustRegistry())
        scriptCertificateFailure(certificateError())
        viewModel.address = "https://192.168.0.40:8920/jf"

        let result = await viewModel.testConnection()

        XCTAssertNil(result, "Nothing connects until the user trusts the certificate.")
        let offer = try XCTUnwrap(viewModel.certificateTrustOffer)
        XCTAssertFalse(offer.offersHTTP, "A typed address has no discovery reply to check HTTP against.")
        XCTAssertEqual(offer.details.kind, .selfSigned)
        XCTAssertEqual(offer.configuration.baseURL.absoluteString, "https://192.168.0.40:8920/jf")
        XCTAssertEqual(offer.serverName, "192.168.0.40")
        XCTAssertNil(viewModel.insecureFallbackOffer)
        XCTAssertFalse(viewModel.isTesting)
    }

    func testDiscoveredHTTPSServerOffersTrustBeforeHTTP() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: ServerTrustRegistry())
        scriptCertificateFailure(certificateError())

        let result = await viewModel.connect(to: lanHTTPS)

        XCTAssertNil(result)
        let offer = try XCTUnwrap(viewModel.certificateTrustOffer)
        XCTAssertTrue(offer.offersHTTP)
        XCTAssertEqual(offer.serverName, "Den")
        XCTAssertNil(viewModel.insecureFallbackOffer, "HTTP is the second choice, offered only when asked for.")
        XCTAssertNil(viewModel.httpPortRequest)
        XCTAssertNotNil(viewModel.errorMessage, "The certificate problem stays explained behind the offer.")

        await viewModel.useUnencryptedHTTPInstead()

        XCTAssertNil(viewModel.certificateTrustOffer)
        let fallback = try XCTUnwrap(viewModel.insecureFallbackOffer)
        XCTAssertEqual(fallback.configuration.baseURL.absoluteString, "http://192.168.0.40:8096/jf")
        XCTAssertFalse(viewModel.isTesting)
    }

    func testTrustingReprobesUnderTheCandidateAndReturnsTheTrust() async throws {
        let registry = ServerTrustRegistry()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: registry)
        let counter = HTTPSCounter()
        let duringReprobe = DecisionBox()
        scriptCertificateFailure(certificateError(), httpsFailures: 1, counter: counter) { number in
            if number == 2 { duringReprobe.set(Self.selfSignedTrustDecision(in: registry)) }
        }
        _ = await viewModel.connect(to: lanHTTPS)
        XCTAssertNotNil(viewModel.certificateTrustOffer)

        let trusted = await viewModel.trustOfferedCertificate()
        let configuration = try XCTUnwrap(trusted)

        XCTAssertEqual(counter.count, 2, "Trusting probes the server again.")
        XCTAssertEqual(duringReprobe.value, .accept, "The re-probe runs under the candidate.")
        XCTAssertEqual(configuration.certificateTrust, .certificate(TLSFixtures.der("selfSignedA")))
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://192.168.0.40:8920/jf")
        XCTAssertEqual(configuration.name, "Den")
        XCTAssertEqual(Self.selfSignedTrustDecision(in: registry), .accept, "The candidate stays until the configuration is saved.")
        XCTAssertNil(viewModel.certificateTrustOffer)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isTesting)
    }

    func testTrustingThatStillFailsClearsTheCandidateAndExplains() async throws {
        let registry = ServerTrustRegistry()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: registry)
        let duringReprobe = DecisionBox()
        scriptCertificateFailure(certificateError()) { number in
            if number == 2 { duringReprobe.set(Self.selfSignedTrustDecision(in: registry)) }
        }
        _ = await viewModel.connect(to: lanHTTPS)
        XCTAssertNotNil(viewModel.certificateTrustOffer)

        let configuration = await viewModel.trustOfferedCertificate()

        XCTAssertNil(configuration)
        XCTAssertEqual(duringReprobe.value, .accept, "The candidate was set for the re-probe…")
        XCTAssertNotEqual(Self.selfSignedTrustDecision(in: registry), .accept, "…and cleared once it didn't help.")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.certificateTrustOffer)
        XCTAssertFalse(viewModel.isTesting)
    }

    /// No presented chain to classify: the discovered server goes straight to
    /// the HTTP fallback, as before #466.
    func testACertificateErrorWithoutAPeerTrustKeepsTodaysFlow() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: ServerTrustRegistry())
        scriptServer()

        let result = await viewModel.connect(to: lanHTTPS)

        XCTAssertNil(result)
        XCTAssertNil(viewModel.certificateTrustOffer)
        let fallback = try XCTUnwrap(viewModel.insecureFallbackOffer)
        XCTAssertEqual(fallback.configuration.baseURL.absoluteString, "http://192.168.0.40:8096/jf")
    }

    func testDecliningClearsTheOfferButKeepsTheExplanation() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: ServerTrustRegistry())
        scriptCertificateFailure(certificateError())
        _ = await viewModel.connect(to: lanHTTPS)
        XCTAssertNotNil(viewModel.certificateTrustOffer)

        viewModel.declineCertificateTrust()

        XCTAssertNil(viewModel.certificateTrustOffer)
        XCTAssertNotNil(viewModel.errorMessage)
        await viewModel.useUnencryptedHTTPInstead()
        XCTAssertNil(viewModel.insecureFallbackOffer, "The declined server is forgotten too.")
    }

    func testANewAttemptClearsThePreviousOffer() async throws {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: ServerTrustRegistry())
        scriptCertificateFailure(certificateError())
        _ = await viewModel.connect(to: lanHTTPS)
        XCTAssertNotNil(viewModel.certificateTrustOffer)

        scriptServer()
        _ = await viewModel.connect(to: lanHTTPS)

        XCTAssertNil(viewModel.certificateTrustOffer)
        XCTAssertNotNil(viewModel.insecureFallbackOffer, "The second attempt follows its own outcome.")
    }

    /// A TLS failure whose certificate the system accepts for the host (a
    /// protocol or cipher problem) isn't the certificate's fault: no offer.
    func testACertificateTheSystemAcceptsForTheHostOffersNothing() async {
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: ServerTrustRegistry())
        let trust = TLSFixtures.trust(leaf: "nameLeaf", anchors: ["testCA"], host: "media.dionysus.test")
        SecTrustSetVerifyDate(trust, ServerTrustPolicyTests.nameLeafVerifyDate as CFDate)
        scriptCertificateFailure(
            URLError(.secureConnectionFailed, userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: trust]),
            host: "media.dionysus.test"
        )
        viewModel.address = "https://media.dionysus.test:8920"

        let result = await viewModel.testConnection()

        XCTAssertNil(result)
        XCTAssertNil(viewModel.certificateTrustOffer)
        XCTAssertEqual(viewModel.errorMessage, String(localized: "Couldn't reach a Jellyfin server at that address. Check it and try again."))
    }

    /// The re-probe redirected to plain HTTP: the user never chose
    /// unencrypted, so it fails rather than connecting there.
    func testTrustingWhoseReprobeLandsOnHTTPFails() async throws {
        let registry = ServerTrustRegistry()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), trustRegistry: registry)
        let error = certificateError()
        let counter = HTTPSCounter()
        MockURLProtocol.requestHandler = { request in
            guard request.url?.host == "192.168.0.40", request.url?.scheme == "https" else { throw URLError(.cannotConnectToHost) }
            if counter.next() == 1 { throw error }
            let landed = URL(string: "http://192.168.0.40:8920/jf/System/Info/Public")!
            let response = HTTPURLResponse(url: landed, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (response, try JellyfinJSON.encoder.encode(PublicSystemInfo(serverName: "Den", id: "system-1")))
        }
        _ = await viewModel.connect(to: lanHTTPS)
        XCTAssertNotNil(viewModel.certificateTrustOffer)

        let configuration = await viewModel.trustOfferedCertificate()

        XCTAssertEqual(counter.count, 2)
        XCTAssertNil(configuration)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotEqual(Self.selfSignedTrustDecision(in: registry), .accept)
    }

    // MARK: Local Network prompt

    /// Fails the first request as iOS does under the Local Network prompt —
    /// the app going inactive as it appears, and active again `answerDelay`
    /// later — then answers every later request with `laterResult`.
    private func scriptPrompt(on activity: FakeAppActivity, counter: RequestCounter, laterFails: Bool = false) {
        MockURLProtocol.requestHandler = { request in
            guard counter.counts(request) else { throw URLError(.cannotConnectToHost) }
            if counter.next() == 1 {
                activity.deactivate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { activity.activate() }
                throw URLError(.notConnectedToInternet)
            }
            if laterFails { throw URLError(.notConnectedToInternet) }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: PublicSystemInfo(serverName: "Flix"))
        }
    }

    func test_testConnection_failsBehindThePrompt_waitsForAllowAndRetries() async {
        let activity = FakeAppActivity()
        let counter = RequestCounter()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), activity: activity, isLocalNetworkDenied: { _ in true })
        viewModel.address = "192.168.0.222:8096/flix"
        scriptPrompt(on: activity, counter: counter)

        let result = await viewModel.testConnection()

        XCTAssertEqual(result?.baseURL.absoluteString, "http://192.168.0.222:8096/flix")
        XCTAssertEqual(counter.count, 2)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// The error's denied reason is undocumented, so the app going inactive
    /// alone is enough to wait and retry.
    func test_testConnection_promptWithoutADeniedReason_stillRetries() async {
        let activity = FakeAppActivity()
        let counter = RequestCounter()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), activity: activity, isLocalNetworkDenied: { _ in false })
        viewModel.address = "192.168.0.222:8096"
        scriptPrompt(on: activity, counter: counter)

        let result = await viewModel.testConnection()

        XCTAssertNotNil(result)
        XCTAssertEqual(counter.count, 2)
    }

    func test_testConnection_promptAnsweredDontAllow_saysLocalNetworkIsOff() async {
        let activity = FakeAppActivity()
        let counter = RequestCounter()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), activity: activity, isLocalNetworkDenied: { _ in true })
        viewModel.address = "192.168.0.222:8096"
        scriptPrompt(on: activity, counter: counter, laterFails: true)

        let result = await viewModel.testConnection()

        XCTAssertNil(result)
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(viewModel.errorMessage, ServerSetupViewModel.localNetworkDeniedMessage)
    }

    /// Turned off earlier: iOS doesn't ask again, the app never goes inactive.
    func test_testConnection_deniedWithNoPrompt_saysLocalNetworkIsOffWithoutRetrying() async {
        let counter = RequestCounter()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), activity: FakeAppActivity(), isLocalNetworkDenied: { _ in true })
        viewModel.address = "192.168.0.222:8096"
        MockURLProtocol.requestHandler = { request in
            if counter.counts(request) { _ = counter.next() }
            throw URLError(.notConnectedToInternet)
        }

        let result = await viewModel.testConnection()

        XCTAssertNil(result)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(viewModel.errorMessage, ServerSetupViewModel.localNetworkDeniedMessage)
    }

    /// Nothing to do with the prompt: fails at once, as before.
    func test_testConnection_ordinaryFailure_neitherWaitsNorRetries() async {
        let counter = RequestCounter()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), activity: FakeAppActivity(), isLocalNetworkDenied: { _ in false })
        viewModel.address = "192.168.0.222:8096"
        MockURLProtocol.requestHandler = { request in
            if counter.counts(request) { _ = counter.next() }
            throw URLError(.cannotConnectToHost)
        }
        let clock = ContinuousClock()
        let started = clock.now

        let result = await viewModel.testConnection()

        XCTAssertNil(result)
        XCTAssertEqual(counter.count, 1)
        XCTAssertNotEqual(viewModel.errorMessage, ServerSetupViewModel.localNetworkDeniedMessage)
        // The request count above is the proof that nothing retried. This
        // bound only catches the wait that precedes a retry, which lasts
        // 60 s (1 s at the least), so it is generous: a loaded runner took
        // 0.6 s against a 0.5 s bound.
        XCTAssertLessThan(clock.now - started, .seconds(10))
    }

    func test_connectToDiscoveredServer_failsBehindThePrompt_waitsAndRetries() async {
        let activity = FakeAppActivity()
        let counter = RequestCounter()
        let viewModel = ServerSetupViewModel(discovery: StubServerDiscovery(servers: []), activity: activity, isLocalNetworkDenied: { _ in true })
        scriptPrompt(on: activity, counter: counter)

        let result = await viewModel.connect(to: flix)

        XCTAssertEqual(result?.baseURL.absoluteString, "http://192.168.0.222:8096/flix")
        XCTAssertEqual(counter.count, 2)
    }
}

/// Stands in for `AppActivityMonitor`, flipped by the test.
private final class FakeAppActivity: AppActivityObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var current = AppActivityState()

    var state: AppActivityState { lock.withLock { current } }

    func deactivate() {
        lock.withLock {
            current.isActive = false
            current.deactivations += 1
        }
    }

    func activate() {
        lock.withLock {
            current.isActive = true
            current.activations += 1
        }
    }
}

/// Counts requests from inside a `MockURLProtocol` handler, which runs off
/// the main actor — a reference type rather than a captured local, which
/// `MockURLProtocol` handlers are known to hang on.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Only requests to the server under test. `MockURLProtocol` is registered
    /// process-wide, and the host app's own launch traffic (a session left on
    /// the simulator signs itself back in) reaches it too.
    func counts(_ request: URLRequest) -> Bool {
        request.url?.host == "192.168.0.222" && request.url?.path.hasSuffix("/System/Info/Public") == true
    }

    var count: Int { lock.withLock { value } }

    /// Records a request; its 1-based number.
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// Counts HTTPS requests from inside a `MockURLProtocol` handler; see
/// `RequestCounter` for why it's a class.
private final class HTTPSCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    /// Records a request; its 1-based number.
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// A decision captured inside a `MockURLProtocol` handler.
private final class DecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decision: ServerTrustDecision?

    var value: ServerTrustDecision? { lock.withLock { decision } }
    func set(_ value: ServerTrustDecision) { lock.withLock { decision = value } }
}

private actor LookupCounter {
    private(set) var value = 0
    func increment() { value += 1 }
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
