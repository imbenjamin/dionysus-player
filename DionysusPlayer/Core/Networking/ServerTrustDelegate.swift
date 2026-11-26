import Foundation

/// Answers server-trust challenges for the app's own sessions from
/// `ServerTrustRegistry` (#466), at session and task level alike. Challenges
/// arrive on the session's delegate queue, never the main actor, which the
/// policy's synchronous evaluation needs.
final class ServerTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ServerTrustDelegate()

    private let registry: ServerTrustRegistry

    init(registry: ServerTrustRegistry = .shared) {
        self.registry = registry
    }

    /// The delegate a task on `session` must pass. A per-task delegate
    /// replaces the session's for challenges, so a session with its own trust
    /// delegate (the Top Shelf's, bound to a registry of its own) keeps it;
    /// `URLSession.shared`, which has none, gets `.shared`. Never pass
    /// `.shared` per task on a session that brings its own.
    static func forTasks(on session: URLSession) -> ServerTrustDelegate {
        session.delegate as? ServerTrustDelegate ?? .shared
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = Self.handle(challenge, registry: registry)
        completionHandler(disposition, credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = Self.handle(challenge, registry: registry)
        completionHandler(disposition, credential)
    }

    /// `.useCredential` for a trust the registry accepts; default handling
    /// for anything else, so a refused certificate fails as it always did and
    /// client certificates and HTTP auth are untouched.
    static func handle(
        _ challenge: URLAuthenticationChallenge,
        registry: ServerTrustRegistry
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              registry.decide(trust, host: space.host, port: space.port) == .accept
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
