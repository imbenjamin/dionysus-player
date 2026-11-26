import CryptoKit
import Foundation
import Security
import SwiftASN1

/// A certificate the system refused, read and classified for the trust offer
/// (#466): who it's for, who issued it, when it expires, and which kind of
/// trust accepting it stores.
///
/// Security reads the subject, issuer and expiry; only the DNS names need
/// parsing, which iOS and tvOS expose no API for (`subjectAltDNSNames`, with
/// swift-asn1). Not compiled into the Top Shelf extension, which never
/// offers trust.
struct ServerCertificateDetails: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Chains to a trusted root but doesn't cover the host connected to;
        /// valid for these of its names, in the certificate's order.
        case nameMismatch(validFor: [String])
        /// One certificate, issued by itself.
        case selfSigned
        /// Anything else: an unknown root, an expired certificate.
        case untrustedIssuer
    }

    /// The presented certificate's DER bytes.
    let leaf: Data
    /// Security's summary of its subject (the common name, when it has one).
    let subject: String
    /// The next certificate up the chain's subject summary; `nil` with none.
    let issuer: String?
    let notAfter: Date?
    /// Its subject alternative DNS names, in order.
    let dnsNames: [String]
    /// SHA-256 of `leaf`.
    let fingerprint: Data
    let kind: Kind

    /// What accepting it stores: the names it's valid for, or the pinned leaf.
    var trust: ServerCertificateTrust {
        if case .nameMismatch(let names) = kind { return .names(names) }
        return .certificate(leaf)
    }

    /// `nil` when the trust has no certificate.
    ///
    /// Evaluates the trust synchronously (it may fetch over the network), so
    /// never call it on the main actor.
    init?(trust: SecTrust) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else { return nil }
        let leaf = SecCertificateCopyData(certificate) as Data
        let dnsNames = Self.subjectAltDNSNames(der: leaf)

        self.leaf = leaf
        self.subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
        self.issuer = chain.dropFirst().first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        self.notAfter = SecCertificateCopyNotValidAfterDate(certificate) as Date?
        self.dnsNames = dnsNames
        self.fingerprint = Data(SHA256.hash(data: leaf))

        let validFor = ServerTrustPolicy.systemAccepts(trust, host: nil)
            ? dnsNames.filter { ServerTrustPolicy.systemAccepts(trust, host: ServerTrustPolicy.probeHost(for: $0)) }
            : []
        if !validFor.isEmpty {
            self.kind = .nameMismatch(validFor: validFor)
        } else if chain.count == 1, Self.isSelfIssued(certificate) {
            self.kind = .selfSigned
        } else {
            self.kind = .untrustedIssuer
        }
    }

    /// From the chain a `ServerTrustRefusal` carries (DER, leaf first), under
    /// the system's anchors. `adjustingTrust` changes the trust before it's
    /// read (tests anchor their own CA and pin the verify date). `nil` when
    /// the chain is empty or holds something that isn't a certificate.
    ///
    /// Evaluates synchronously (it may fetch over the network), so never call
    /// it on the main actor.
    init?(chain: [Data], adjustingTrust: (SecTrust) -> Void = { _ in }) {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty, certificates.count == chain.count else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess,
              let trust else { return nil }
        adjustingTrust(trust)
        self.init(trust: trust)
    }

    private static func isSelfIssued(_ certificate: SecCertificate) -> Bool {
        guard let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?,
              let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data? else { return false }
        return issuer == subject
    }

    // MARK: Subject alternative names

    /// The dNSName entries of a DER certificate's SubjectAltName extension,
    /// in order. Fails soft: anything unexpected gives an empty list.
    ///
    /// Certificate ::= SEQUENCE { tbsCertificate, … }; tbsCertificate holds
    /// `[3] EXPLICIT Extensions`; each Extension is SEQUENCE { extnID,
    /// critical BOOLEAN OPTIONAL, extnValue OCTET STRING }, and 2.5.29.17's
    /// value is GeneralNames, whose dNSName is `[2] IA5String`.
    static func subjectAltDNSNames(der: Data) -> [String] {
        guard let certificate = try? DER.parse(Array(der)),
              let tbs = children(of: certificate).first,
              let extensionsTag = children(of: tbs).first(where: { isContextSpecific($0, 3) }),
              let extensions = children(of: extensionsTag).first
        else { return [] }

        for candidate in children(of: extensions) {
            let fields = children(of: candidate)
            guard let id = fields.first,
                  let oid = try? ASN1ObjectIdentifier(derEncoded: id),
                  oid == subjectAltNameOID,
                  let value = fields.last, value.identifier == .octetString,
                  case .primitive(let bytes) = value.content,
                  let generalNames = try? DER.parse(Array(bytes))
            else { continue }

            // Printable ASCII only, no spaces: these names are shown and may
            // be stored, so a self-signed certificate's NUL or newline can't
            // dress one name up as another.
            return children(of: generalNames).compactMap { name in
                guard isContextSpecific(name, 2), case .primitive(let ia5) = name.content,
                      !ia5.isEmpty, ia5.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
                return String(decoding: ia5, as: UTF8.self)
            }
        }
        return []
    }

    private static let subjectAltNameOID: ASN1ObjectIdentifier = [2, 5, 29, 17]

    private static func children(of node: ASN1Node) -> [ASN1Node] {
        guard case .constructed(let nodes) = node.content else { return [] }
        return Array(nodes)
    }

    private static func isContextSpecific(_ node: ASN1Node, _ tag: UInt) -> Bool {
        node.identifier.tagClass == .contextSpecific && node.identifier.tagNumber == tag
    }
}
