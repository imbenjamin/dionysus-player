import AetherEngine
import Foundation
import Security
import XCTest
@testable import Dionysus

/// `ServerTrustRegistry` answers every server-trust challenge in the app
/// (#466): through `ServerTrustDelegate` for the app's own sessions and the
/// engine bridge for AetherEngine's. Each test makes its own registry, since
/// `.shared` is the running app's; the engine evaluator and the registry's
/// change hook are global, so they're put back after every test.
final class ServerTrustRegistryTests: XCTestCase {
    private let lanURL = URL(string: "https://192.168.1.50:8920")!
    private var savedEvaluator: (@Sendable (URLProtectionSpace) -> Bool)?
    private var savedDidChange: (@Sendable (ServerTrustRegistry) -> Void)?

    override func setUp() {
        super.setUp()
        savedEvaluator = EngineTLS.serverTrustEvaluator
        savedDidChange = ServerTrustRegistry.didChange
    }

    override func tearDown() {
        EngineTLS.serverTrustEvaluator = savedEvaluator
        ServerTrustRegistry.didChange = savedDidChange
        super.tearDown()
    }

    /// Records `onRefusal`'s calls, from whichever thread they come.
    private final class RefusalLog: @unchecked Sendable {
        private let lock = NSLock()
        private var refusals: [ServerTrustRefusal] = []
        var all: [ServerTrustRefusal] { lock.withLock { refusals } }
        func record(_ refusal: ServerTrustRefusal) { lock.withLock { refusals.append(refusal) } }
    }

    private func pinned(_ url: URL, _ leaf: String) -> ServerConfiguration {
        ServerConfiguration(name: "Media", baseURL: url, certificateTrust: .certificate(TLSFixtures.der(leaf)))
    }

    /// `decide` evaluates synchronously, which the system warns about on the
    /// main thread, so the tests call it from a detached task, as a session's
    /// delegate queue would.
    private func decide(_ registry: ServerTrustRegistry, _ leaf: String, port: Int = 8920) async -> ServerTrustDecision {
        await Task.detached {
            registry.decide(TLSFixtures.trust(leaf: leaf, anchors: [], host: "192.168.1.50"),
                            host: "192.168.1.50", port: port)
        }.value
    }

    /// `trust(for:)` (DEBUG only, for tests): setup's candidate first,
    /// then the configured server's at its own origin only, else nothing.
    func testTrustForOriginPrefersTheCandidateThenTheConfiguredServer() {
        let registry = ServerTrustRegistry()
        let origin = ServerOrigin(url: lanURL)!
        let elsewhere = ServerOrigin(host: "10.0.0.9", port: 8920)
        XCTAssertNil(registry.trust(for: origin), "Nothing held")

        let configured = ServerCertificateTrust.names(["media.example.com"])
        registry.configure(server: ServerConfiguration(name: "Media", baseURL: lanURL, certificateTrust: configured))
        XCTAssertEqual(registry.trust(for: origin), configured, "The configured server's, at its origin")
        XCTAssertNil(registry.trust(for: elsewhere), "Not at another origin")

        let candidate = ServerCertificateTrust.certificate(Data([1, 2, 3]))
        registry.setCandidate(candidate, for: origin)
        XCTAssertEqual(registry.trust(for: origin), candidate, "Setup's candidate comes first")
    }

    func testRefusalIsReportedOncePerFingerprint() async {
        let registry = ServerTrustRegistry()
        registry.configure(server: pinned(lanURL, "selfSignedA"))
        let log = RefusalLog()
        registry.onRefusal = { log.record($0) }

        for _ in 0..<10 {
            let decision = await decide(registry, "selfSignedB")
            XCTAssertEqual(decision, .refuse(presentedLeaf: TLSFixtures.der("selfSignedB")))
        }
        XCTAssertEqual(log.all, [ServerTrustRefusal(
            origin: ServerOrigin(host: "192.168.1.50", port: 8920),
            presentedLeaf: TLSFixtures.der("selfSignedB"),
            presentedChain: [TLSFixtures.der("selfSignedB")],
            previous: .certificate(TLSFixtures.der("selfSignedA"))
        )])

        _ = await decide(registry, "nameLeafOther")
        XCTAssertEqual(log.all.count, 2)
        XCTAssertEqual(log.all.last?.presentedLeaf, TLSFixtures.der("nameLeafOther"))
    }

    /// Refused before any hook was set (a background session at launch,
    /// before `AppState` exists): still reported once one is.
    func testARefusalWithNoHookIsReportedOnceAHookIsSet() async {
        let registry = ServerTrustRegistry()
        registry.configure(server: pinned(lanURL, "selfSignedA"))
        _ = await decide(registry, "selfSignedB")

        let log = RefusalLog()
        registry.onRefusal = { log.record($0) }
        _ = await decide(registry, "selfSignedB")
        _ = await decide(registry, "selfSignedB")

        XCTAssertEqual(log.all.map(\.presentedLeaf), [TLSFixtures.der("selfSignedB")])
    }

    /// A refusal handed back is reported again at its next refusal.
    func testAForgottenReportIsReportedAgain() async {
        let registry = ServerTrustRegistry()
        registry.configure(server: pinned(lanURL, "selfSignedA"))
        let log = RefusalLog()
        registry.onRefusal = { log.record($0) }
        _ = await decide(registry, "selfSignedB")

        registry.forgetReport(of: TLSFixtures.der("selfSignedB"))
        _ = await decide(registry, "selfSignedB")
        _ = await decide(registry, "selfSignedB")

        XCTAssertEqual(log.all.count, 2)
    }

    func testCandidateIsUsedForItsOriginBeforeAnythingIsSaved() async {
        let registry = ServerTrustRegistry()
        let origin = ServerOrigin(host: "192.168.1.50", port: 8920)
        var decision = await decide(registry, "selfSignedA")
        XCTAssertEqual(decision, .systemDefault)

        registry.setCandidate(.certificate(TLSFixtures.der("selfSignedA")), for: origin)
        decision = await decide(registry, "selfSignedA")
        XCTAssertEqual(decision, .accept)
        // Only for its own origin.
        decision = await decide(registry, "selfSignedA", port: 443)
        XCTAssertEqual(decision, .systemDefault)

        registry.setCandidate(nil, for: origin)
        decision = await decide(registry, "selfSignedA")
        XCTAssertEqual(decision, .systemDefault)
    }

    func testLoadFromStoreFillsTheTrustBeforeAppStateStarts() async throws {
        let suiteName = "com.dionysusplayer.tests.ServerTrustRegistryTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)
            .saveServer(pinned(lanURL, "selfSignedA"))

        let registry = ServerTrustRegistry()
        registry.loadFromStore(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults))

        XCTAssertTrue(registry.hasStoredTrust)
        let decision = await decide(registry, "selfSignedA")
        XCTAssertEqual(decision, .accept)
    }

    func testBridgeSetsTheEngineEvaluatorOnlyWhileATrustIsStored() {
        let registry = ServerTrustRegistry()
        ServerTrustRegistry.didChange = { ServerTrustEngineBridge.apply(registry: $0) }

        registry.configure(server: pinned(lanURL, "selfSignedA"))
        XCTAssertNotNil(EngineTLS.serverTrustEvaluator)

        registry.configure(server: ServerConfiguration(name: "Media", baseURL: lanURL))
        XCTAssertNil(EngineTLS.serverTrustEvaluator)
    }

    /// The app's hook drives the engine from `.shared` only, so a registry a
    /// test makes can never change what the engine trusts.
    func testInstalledBridgeIgnoresRegistriesOtherThanShared() {
        ServerTrustEngineBridge.install()
        EngineTLS.serverTrustEvaluator = nil

        ServerTrustRegistry().configure(server: pinned(lanURL, "selfSignedA"))

        XCTAssertNil(EngineTLS.serverTrustEvaluator)
    }

    func testDelegateAcceptsThePinnedListenerAndRefusesAChangedOne() async throws {
        let server = try await TLSTestServer(identity: "selfSignedA")
        defer { server.stop() }
        let registry = ServerTrustRegistry()
        registry.configure(server: pinned(server.baseURL, "selfSignedA"))
        let log = RefusalLog()
        registry.onRefusal = { log.record($0) }
        let delegate = ServerTrustDelegate(registry: registry)

        let (_, response) = try await URLSession.shared.data(for: URLRequest(url: server.baseURL), delegate: delegate)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(log.all.isEmpty)

        server.replaceIdentity("selfSignedB")
        do {
            _ = try await URLSession.shared.data(for: URLRequest(url: server.baseURL), delegate: delegate)
            XCTFail("a changed certificate must not load")
        } catch let error as URLError {
            let expected: [URLError.Code] = [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                                             .secureConnectionFailed]
            XCTAssertTrue(expected.contains(error.code), "unexpected \(error.code)")
        }
        XCTAssertEqual(log.all.map(\.presentedLeaf), [TLSFixtures.der("selfSignedB")])
    }
}
