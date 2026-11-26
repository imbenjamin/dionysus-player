import Foundation
import Security

/// How a TLS server-trust challenge is answered (#466).
enum ServerTrustDecision: Equatable {
    /// Not ours to decide: `.performDefaultHandling`.
    case systemDefault
    /// Trusted by what the user stored: `.useCredential`.
    case accept
    /// The system refuses it and nothing stored covers it. Callers answer
    /// `.performDefaultHandling` (so the request fails as before) and report
    /// the certificate that was presented.
    case refuse(presentedLeaf: Data)
}

/// Decides each server-trust challenge against the trust the user stored for
/// their server (#466). Pure apart from evaluating the trust; Foundation and
/// Security only, since the Top Shelf extension compiles it.
enum ServerTrustPolicy {
    /// In order: another origin, or a certificate the system accepts for the
    /// host, is left to the system; stored names accept a chain valid for one
    /// of them (a renewal keeps working); a pinned certificate accepts exactly
    /// its own leaf, expired or not; anything else is refused and reported.
    ///
    /// Evaluates synchronously and may fetch missing intermediates over the
    /// network, so never call it on the main actor. No revocation checking.
    static func decide(
        trust: SecTrust,
        origin: ServerOrigin,
        serverOrigin: ServerOrigin?,
        stored: ServerCertificateTrust?
    ) -> ServerTrustDecision {
        guard origin == serverOrigin else { return .systemDefault }
        if systemAccepts(trust, host: origin.host) { return .systemDefault }

        switch stored {
        case .names(let names):
            if names.contains(where: { systemAccepts(trust, host: probeHost(for: $0)) }) {
                return .accept
            }
        case .certificate(let pinned):
            if leafDER(trust) == pinned { return .accept }
        case nil:
            break
        }
        return .refuse(presentedLeaf: leafDER(trust) ?? Data())
    }

    /// Whether the system accepts the chain for `host` (`nil`: the chain only,
    /// no name checked). Evaluates a copy, so the caller's trust keeps its
    /// own policy; the copy keeps its anchors, verify date and network-fetch
    /// setting.
    ///
    /// Evaluates synchronously and may fetch missing intermediates over the
    /// network, so never call it on the main actor. No revocation checking.
    static func systemAccepts(_ trust: SecTrust, host: String?) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !chain.isEmpty else {
            return false
        }
        var copy: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString?)
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &copy) == errSecSuccess,
              let copy else { return false }

        var anchors: CFArray?
        if SecTrustCopyCustomAnchorCertificates(trust, &anchors) == errSecSuccess, let anchors {
            // Setting anchors also makes them the only ones, as the system
            // does whenever custom anchors were set without re-enabling its own.
            SecTrustSetAnchorCertificates(copy, anchors)
        }
        SecTrustSetVerifyDate(copy, Date(timeIntervalSinceReferenceDate: SecTrustGetVerifyTime(trust)) as CFDate)
        var fetchAllowed = DarwinBoolean(true)
        if SecTrustGetNetworkFetchAllowed(trust, &fetchAllowed) == errSecSuccess {
            SecTrustSetNetworkFetchAllowed(copy, fetchAllowed.boolValue)
        }
        return SecTrustEvaluateWithError(copy, nil)
    }

    /// The presented (leaf) certificate's DER bytes.
    static func leafDER(_ trust: SecTrust) -> Data? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// A host to check a stored name with: `SecPolicyCreateSSL` can't take a
    /// wildcard, so `*.example.com` is checked as `dionysus-check.example.com`.
    static func probeHost(for name: String) -> String {
        name.hasPrefix("*.") ? "dionysus-check." + name.dropFirst(2) : name
    }

    /// Whether a certificate naming `dnsName` names the stored `name` too, by
    /// the names alone (no chain): the policy's own check with the chain left
    /// out, `name` probed as `probeHost(for:)` and a wildcard covering one
    /// leftmost label, case ignored. For a chain that no longer verifies, so
    /// the system can't be asked.
    static func dnsName(_ dnsName: String, covers name: String) -> Bool {
        let host = probeHost(for: name).lowercased()
        let pattern = dnsName.lowercased()
        guard pattern.hasPrefix("*.") else { return pattern == host }
        guard let dot = host.firstIndex(of: "."), host.startIndex < dot else { return false }
        return host[dot...] == pattern.dropFirst(1)
    }
}
