import Foundation
import Security
import XCTest
@testable import Dionysus

/// The app's sessions reach a trusted server and refuse a changed certificate
/// (#466), against a local TLS listener. The API client runs on a session
/// with a registry of its own, as the Top Shelf's does: a per-task delegate
/// replaces the session's for challenges, so this proves the client asks its
/// own session's registry, never `.shared`. The player's fetches run on
/// `URLSession.shared` and so on `.shared`, configured and put back per test.
/// The image loader and the downloads' ad-hoc session are type checks; the
/// download router is a synthetic challenge.
final class ServerTrustSessionCoverageTests: XCTestCase {
    private var server: TLSTestServer?

    override func tearDown() {
        server?.stop()
        server = nil
        ServerTrustRegistry.shared.configure(server: nil)
        ServerTrustRegistry.shared.onRefusal = nil
        super.tearDown()
    }

    private func start(listener identity: String) async throws -> TLSTestServer {
        let server = try await TLSTestServer(identity: identity)
        self.server = server
        return server
    }

    /// A registry of its own, pinned to `leaf` for `server`; `.shared` knows
    /// nothing of the listener's random port.
    private func privateRegistry(for server: TLSTestServer, pinned leaf: String) -> ServerTrustRegistry {
        let registry = ServerTrustRegistry()
        registry.configure(serverURL: server.baseURL, trust: .certificate(TLSFixtures.der(leaf)))
        return registry
    }

    private func session(asking registry: ServerTrustRegistry) -> URLSession {
        URLSession(configuration: .ephemeral, delegate: ServerTrustDelegate(registry: registry), delegateQueue: nil)
    }

    func testAPIClientOnASessionWithItsOwnRegistry_reachesAPinnedServer() async throws {
        let server = try await start(listener: "selfSignedA")
        let urlSession = session(asking: privateRegistry(for: server, pinned: "selfSignedA"))
        defer { urlSession.invalidateAndCancel() }
        let info = try await JellyfinAPIClient(baseURL: server.baseURL, session: urlSession).publicSystemInfo()
        XCTAssertEqual(info.serverName, "TLS Test")
    }

    func testAPIClientRefusesAChangedCertificate() async throws {
        let server = try await start(listener: "selfSignedA")
        let registry = privateRegistry(for: server, pinned: "selfSignedB")
        let refusals = RefusalLog()
        registry.onRefusal = { _ in refusals.record() }
        let urlSession = session(asking: registry)
        defer { urlSession.invalidateAndCancel() }
        do {
            _ = try await JellyfinAPIClient(baseURL: server.baseURL, session: urlSession).publicSystemInfo()
            XCTFail("A certificate that isn't the pinned one must be refused")
        } catch let error as URLError {
            // Default handling, never `.cancel`: the system's own refusal.
            XCTAssertEqual(error.code, .serverCertificateUntrusted, "got \(error)")
        }
        XCTAssertEqual(refusals.refusals, 1, "the session's own registry decided, and reported the refusal")
    }

    func testImageLoaderUsesTheTrustDelegate() async {
        let loader = RemoteImageLoader()
        XCTAssertTrue(loader.session.delegate is ServerTrustDelegate)
    }

    func testPlayerFetchesPassTheTrustDelegate() async throws {
        let server = try await start(listener: "selfSignedA")
        ServerTrustRegistry.shared.configure(server: ServerConfiguration(
            name: "TLS Test", baseURL: server.baseURL,
            certificateTrust: .certificate(TLSFixtures.der("selfSignedA"))
        ))
        let url = server.baseURL.appendingPathComponent("System/Info/Public")
        let (data, response) = try await PlayerViewModel.fetch(URLRequest(url: url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(data.isEmpty)
    }

    private final class RefusalLog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var refusals: Int { lock.withLock { count } }
        func record() { lock.withLock { count += 1 } }
    }

    #if DOWNLOADS
    @MainActor
    func testDownloadAdHocSessionUsesTheTrustDelegate() {
        XCTAssertTrue(DownloadManager.makeAdHocFetchSession().delegate is ServerTrustDelegate)
    }

    /// A protection space that carries a trust, which only the system makes
    /// for a real connection.
    private final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
        let fixedTrust: SecTrust
        init(trust: SecTrust) {
            fixedTrust = trust
            super.init(host: "192.168.1.50", port: 8920, protocol: "https", realm: nil,
                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var serverTrust: SecTrust? { fixedTrust }
    }

    private final class NoSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func answer(_ router: DownloadTaskRouter, leaf: String) async -> URLSession.AuthChallengeDisposition {
        await Task.detached {
            let space = TrustSpace(trust: TLSFixtures.trust(leaf: leaf, anchors: [], host: "192.168.1.50"))
            let challenge = URLAuthenticationChallenge(
                protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                failureResponse: nil, error: nil, sender: NoSender()
            )
            return await withCheckedContinuation { continuation in
                router.urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in
                    continuation.resume(returning: disposition)
                }
            }
        }.value
    }

    func testDownloadRouterAnswersServerTrustThroughTheSharedHandler() async {
        let registry = ServerTrustRegistry()
        registry.configure(server: ServerConfiguration(
            name: "Media", baseURL: URL(string: "https://192.168.1.50:8920")!,
            certificateTrust: .certificate(TLSFixtures.der("selfSignedA"))
        ))
        let log = RefusalLog()
        registry.onRefusal = { _ in log.record() }
        let router = DownloadTaskRouter(registry: registry)

        let accepted = await answer(router, leaf: "selfSignedA")
        XCTAssertEqual(accepted, .useCredential)
        XCTAssertEqual(log.refusals, 0)

        let refused = await answer(router, leaf: "selfSignedB")
        XCTAssertEqual(refused, .performDefaultHandling)
        XCTAssertEqual(log.refusals, 1, "the registry, through the shared handler, saw the refusal")
    }
    #endif
}
