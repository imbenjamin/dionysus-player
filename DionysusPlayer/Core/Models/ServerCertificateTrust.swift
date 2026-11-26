import CryptoKit
import Foundation
import Security

/// What the user chose to trust about a server whose HTTPS certificate the
/// system can't verify (#466). Stored on the `ServerConfiguration` and mirrored
/// for the Top Shelf. Foundation, CryptoKit and Security only: the extension
/// compiles it.
enum ServerCertificateTrust: Codable, Equatable, Sendable {
    /// The certificate chains to a trusted root but doesn't cover the host the
    /// app connects to; these are the names the user accepted.
    case names([String])
    /// A self-signed or privately issued certificate, pinned by its DER bytes.
    case certificate(Data)

    /// SHA-256 of the pinned certificate's DER; `nil` for `.names`.
    var fingerprint: Data? {
        guard case .certificate(let der) = self else { return nil }
        return Data(SHA256.hash(data: der))
    }

    /// One line for Profile: the first name trusted, or what kind of
    /// certificate is pinned (self-signed only when it really is).
    var profileSummary: String {
        switch self {
        case .names(let names):
            return String(localized: "Trusted for \(names.first ?? String(localized: "this server"))")
        case .certificate:
            return isSelfSigned ? String(localized: "Trusted (self-signed)") : String(localized: "Trusted (this certificate)")
        }
    }

    /// The Apple TV's wording, which ends in "certificate".
    var profileSummaryForTV: String {
        switch self {
        case .names(let names):
            return String(localized: "Certificate trusted for \(names.first ?? String(localized: "this server"))")
        case .certificate:
            return isSelfSigned ? String(localized: "Trusted (self-signed) certificate") : String(localized: "Trusted (pinned) certificate")
        }
    }

    /// Whether a pinned certificate's issuer is its own subject.
    private var isSelfSigned: Bool {
        guard case .certificate(let der) = self,
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?,
              let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?
        else { return false }
        return issuer == subject
    }

    /// Uppercase hex pairs joined by colons, as certificate viewers show them.
    static func fingerprintText(_ sha256: Data) -> String {
        sha256.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// A server's scheme-less identity for trust decisions: host and port.
struct ServerOrigin: Hashable, Sendable {
    let host: String
    let port: Int

    /// Host lowercased with any IPv6 brackets removed, so an origin built from
    /// a challenge's `URLProtectionSpace` compares equal to the server's.
    init(host: String, port: Int) {
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        self.port = port
    }

    /// Port from the URL, else 443 for https and 80 for http. `nil` without a
    /// host.
    init?(url: URL) {
        guard let host = url.host, !host.isEmpty else { return nil }
        let defaultPort = url.scheme?.lowercased() == "http" ? 80 : 443
        self.init(host: host, port: url.port ?? defaultPort)
    }
}
