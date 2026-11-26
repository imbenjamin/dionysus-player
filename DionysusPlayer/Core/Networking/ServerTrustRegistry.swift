import CryptoKit
import Foundation
import Security

/// A certificate the policy refused for the configured server (#466): what
/// the changed-certificate warning shows.
struct ServerTrustRefusal: Equatable, Sendable {
    let origin: ServerOrigin
    /// The leaf the server presented, as DER.
    let presentedLeaf: Data
    /// The whole chain the trust held, leaf first, as DER: the warning
    /// classifies from it, since a CA-issued certificate's intermediates
    /// can't always be fetched again from the leaf alone.
    let presentedChain: [Data]
    /// What was trusted for the origin when it was refused; `nil` when nothing
    /// was.
    let previous: ServerCertificateTrust?
}

/// The trust every TLS server-trust challenge in the app is decided against
/// (#466): the configured server's, or setup's candidate while it re-probes.
/// Read per challenge, so changing it needs no session rebuilt. Lock-guarded:
/// challenges arrive on any queue.
///
/// Filled at launch from `ServerSessionStore` (`loadFromStore`), before any
/// session can raise a challenge, then kept current by `AppState`. Foundation,
/// CryptoKit and Security only: the Top Shelf extension compiles it.
final class ServerTrustRegistry: @unchecked Sendable {
    static let shared = ServerTrustRegistry()

    /// Called after every change of trust, with the registry that changed.
    /// The app sets it to `ServerTrustEngineBridge`, which keeps AetherEngine
    /// out of `Core/Networking`.
    static var didChange: (@Sendable (ServerTrustRegistry) -> Void)? {
        get { hookLock.withLock { _didChange } }
        set { hookLock.withLock { _didChange = newValue } }
    }
    private static let hookLock = NSLock()
    nonisolated(unsafe) private static var _didChange: (@Sendable (ServerTrustRegistry) -> Void)?

    private let lock = NSLock()
    private var serverOrigin: ServerOrigin?
    private var serverTrust: ServerCertificateTrust?
    private var candidates: [ServerOrigin: ServerCertificateTrust] = [:]
    /// SHA-256 of every leaf already reported this launch.
    private var reported: Set<Data> = []
    private var _onRefusal: (@Sendable (ServerTrustRefusal) -> Void)?

    init() {}

    /// Called once per newly presented certificate per launch, off the main
    /// actor, from whichever queue raised the challenge.
    var onRefusal: (@Sendable (ServerTrustRefusal) -> Void)? {
        get { lock.withLock { _onRefusal } }
        set { lock.withLock { _onRefusal = newValue } }
    }

    /// Whether any trust is held, configured or candidate.
    var hasStoredTrust: Bool {
        lock.withLock { serverTrust != nil || !candidates.isEmpty }
    }

    #if DEBUG
    /// The trust held for `origin`: setup's candidate first, else the
    /// configured server's when it's at `origin`. `nil` with neither. Used by
    /// tests only: challenges go through `decide`.
    func trust(for origin: ServerOrigin) -> ServerCertificateTrust? {
        lock.withLock { candidates[origin] ?? (serverOrigin == origin ? serverTrust : nil) }
    }
    #endif

    /// The configured server and its trust; `nil` when none is configured.
    /// One origin rule with `configure(serverURL:trust:)`: a host-less URL
    /// has no origin, so no challenge matches it and nothing is accepted.
    func configure(server: ServerConfiguration?) {
        lock.withLock {
            serverOrigin = server.flatMap { ServerOrigin(url: $0.baseURL) }
            serverTrust = server?.certificateTrust
        }
        Self.didChange?(self)
    }

    /// The server and trust the Top Shelf extension mirrored, which has no
    /// `ServerConfiguration` of its own.
    func configure(serverURL: URL, trust: ServerCertificateTrust?) {
        lock.withLock {
            serverOrigin = ServerOrigin(url: serverURL)
            serverTrust = trust
        }
        Self.didChange?(self)
    }

    /// Setup's pending trust, used for `origin` before anything is saved, in
    /// place of the configured server's. `nil` clears it.
    func setCandidate(_ trust: ServerCertificateTrust?, for origin: ServerOrigin) {
        lock.withLock { candidates[origin] = trust }
        Self.didChange?(self)
    }

    /// Forgets every setup candidate: once setup saves a server (its trust is
    /// the configured one from then on), or leaves for another server.
    func clearCandidates() {
        lock.withLock { candidates.removeAll() }
        Self.didChange?(self)
    }

    /// Runs `ServerTrustPolicy` for a challenge from `host:port`, reporting a
    /// refusal through `onRefusal` the first time its leaf is seen. A leaf
    /// counts as seen only once a hook has been told, so one refused before
    /// the hook is set is reported later; the hook hands back the ones it
    /// raised nothing for (`forgetReport(of:)`). Kept for the whole launch,
    /// a server change included.
    ///
    /// Evaluates synchronously and may fetch over the network, so never call
    /// it on the main actor.
    func decide(_ trust: SecTrust, host: String, port: Int) -> ServerTrustDecision {
        let origin = ServerOrigin(host: host, port: port)
        let (serverOrigin, stored) = lock.withLock { () -> (ServerOrigin?, ServerCertificateTrust?) in
            if let candidate = candidates[origin] { return (origin, candidate) }
            return (self.serverOrigin, serverTrust)
        }
        let decision = ServerTrustPolicy.decide(trust: trust, origin: origin, serverOrigin: serverOrigin, stored: stored)
        guard case .refuse(let leaf) = decision else { return decision }

        let fingerprint = Data(SHA256.hash(data: leaf))
        let report = lock.withLock { () -> (@Sendable (ServerTrustRefusal) -> Void)? in
            guard let hook = _onRefusal else { return nil }
            return reported.insert(fingerprint).inserted ? hook : nil
        }
        guard let report else { return decision }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).map { SecCertificateCopyData($0) as Data }
        report(ServerTrustRefusal(origin: origin, presentedLeaf: leaf, presentedChain: chain, previous: stored))
        return decision
    }

    /// Lets `leaf` be reported again the next time it's refused: for a
    /// refusal the hook raised nothing for.
    func forgetReport(of leaf: Data) {
        let fingerprint = Data(SHA256.hash(data: leaf))
        lock.withLock { _ = reported.remove(fingerprint) }
    }
}
