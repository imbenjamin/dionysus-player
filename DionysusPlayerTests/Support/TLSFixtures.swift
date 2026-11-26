import Foundation
import Security

/// The certificates under `Fixtures/TLS` (made by
/// `Scripts/generate-tls-fixtures.sh`; test-only keys). `name` is the file's
/// base name, e.g. "selfSignedA".
enum TLSFixtures {
    private final class BundleToken {}

    static func der(_ name: String) -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "der")
                ?? bundle.url(forResource: name, withExtension: "der", subdirectory: "TLS")
                ?? bundle.url(forResource: name, withExtension: "der", subdirectory: "Fixtures/TLS"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing TLS fixture \(name).der")
        }
        return data
    }

    static func certificate(_ name: String) -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, der(name) as CFData) else {
            fatalError("TLS fixture \(name).der isn't a certificate")
        }
        return certificate
    }

    /// The certificate with its private key, from `<name>.p12` (password `dionysus`).
    static func identity(_ name: String) -> SecIdentity {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "p12")
                ?? bundle.url(forResource: name, withExtension: "p12", subdirectory: "TLS")
                ?? bundle.url(forResource: name, withExtension: "p12", subdirectory: "Fixtures/TLS"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing TLS fixture \(name).p12")
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: "dionysus"] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            fatalError("SecPKCS12Import failed for \(name): \(status)")
        }
        return identity as! SecIdentity // swiftlint:disable:this force_cast
    }

    /// A trust for `leaf` that evaluates nothing yet. `anchors` replace the
    /// system's (anchors only), so a fixture CA is trusted and nothing else is.
    /// `host` adds an SSL policy that checks the name; nil checks no name.
    static func trust(leaf: String, anchors: [String], host: String?) -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate(leaf), SecPolicyCreateSSL(true, host as CFString?), &trust)
        guard status == errSecSuccess, let trust else { fatalError("SecTrustCreateWithCertificates failed: \(status)") }
        SecTrustSetAnchorCertificates(trust, anchors.map { certificate($0) } as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return trust
    }
}
