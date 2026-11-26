import SwiftUI

/// What the app says about a certificate it couldn't verify (#466): why it
/// failed, and its four rows. Shared by the trust offer (iOS's sheet, the
/// Apple TV's page), the changed-certificate warning and Profile.
struct CertificateDescription: Equatable {
    struct Row: Identifiable, Equatable {
        /// `validFor`: a trust kept by name, on the changed-certificate
        /// warning, where it stands in for a fingerprint.
        enum ID: String {
            case issuedTo, issuedBy, expires, fingerprint, validFor

            /// The row a caller's `fingerprintIdentifier` goes on.
            var isIdentified: Bool { self == .fingerprint || self == .validFor }
        }
        let id: ID
        let title: String
        let value: String
        /// What VoiceOver reads for `value`, when it differs.
        let spokenValue: String
    }

    let details: ServerCertificateDetails

    /// "This certificate is valid for media.example.com, not 192.168.1.50.",
    /// "… is self-signed." or "… isn't from a trusted authority."
    func reason(host: String?) -> String {
        switch details.kind {
        case .nameMismatch(let names):
            let list = names.formatted(.list(type: .and))
            guard let host, !host.isEmpty else {
                return String(localized: "This certificate is valid for \(list), not for this address.")
            }
            return String(localized: "This certificate is valid for \(list), not \(host).")
        case .selfSigned:
            return String(localized: "This certificate is self-signed.")
        case .untrustedIssuer:
            return String(localized: "This certificate isn't from a trusted authority.")
        }
    }

    /// For a pinned certificate (anything but the name case): trusting it
    /// keeps this exact certificate, so a renewal asks again, and a private
    /// CA that renews often is better installed as a profile (#499).
    var pinNote: String? {
        if case .nameMismatch = details.kind { return nil }
        return String(localized: "Trusting keeps this exact certificate, so you'll be asked again whenever it changes. If it comes from a private certificate authority that renews often, install that authority on this device as a configuration profile instead.")
    }

    var rows: [Row] { rows(pairsPerLine: 8) }

    /// The rows with the fingerprint broken after `pairsPerLine` pairs: the
    /// Apple TV's warning page, with two certificates to fit on one screen,
    /// sets 16 to a line.
    func rows(pairsPerLine: Int) -> [Row] {
        let subject = details.subject.isEmpty ? (details.dnsNames.first ?? unknown) : details.subject
        let issuer = details.issuer ?? (details.kind == .selfSigned ? subject : unknown)
        let expires = details.notAfter?.formatted(date: .long, time: .omitted) ?? unknown
        let fingerprint = ServerCertificateTrust.fingerprintText(details.fingerprint)
        return [
            Row(id: .issuedTo, title: String(localized: "Issued To"), value: subject, spokenValue: subject),
            Row(id: .issuedBy, title: String(localized: "Issued By"), value: issuer, spokenValue: issuer),
            Row(id: .expires, title: String(localized: "Expires"), value: expires, spokenValue: expires),
            // Shown whole pairs to a line, so no pair breaks across two;
            // read as pairs, not "colon" between each.
            Row(id: .fingerprint, title: "SHA-256", value: Self.lines(of: fingerprint, pairsPerLine: pairsPerLine),
                spokenValue: fingerprint.replacingOccurrences(of: ":", with: " "))
        ]
    }

    /// Every row as one line each, for a single accessibility value.
    var spokenRows: String {
        rows.map { "\($0.title): \($0.spokenValue)" }.joined(separator: "\n")
    }

    private var unknown: String { String(localized: "Unknown") }

    /// "AA:BB:…" broken after every `pairsPerLine` pairs.
    static func lines(of fingerprint: String, pairsPerLine: Int) -> String {
        let pairs = fingerprint.split(separator: ":")
        return stride(from: 0, to: pairs.count, by: pairsPerLine)
            .map { pairs[$0..<min($0 + pairsPerLine, pairs.count)].joined(separator: ":") }
            .joined(separator: "\n")
    }
}

/// The changed-certificate warning's three answers (#466), acted on once its
/// page has gone (iOS's `CertificateWarningPresenter`, `TVRootView`).
enum CertificateWarningAnswer {
    case trust, changeServer, notNow
}

/// What the changed-certificate warning says (#466), on both platforms.
/// `changed` puts the trusted certificate beside the new one; `untrusted`
/// (nothing stored yet) is the setup offer's wording.
extension CertificateWarning {
    var certificateDescription: CertificateDescription { CertificateDescription(details: details) }

    var isChanged: Bool {
        if case .changed = kind { return true }
        return false
    }

    /// For a trust kept by name, the trusted names the presented certificate
    /// still carries (`ServerTrustPolicy.dnsName(_:covers:)`): the same
    /// certificate, or its renewal, that stopped verifying (expired, or its
    /// authority no longer trusted), not another one. `nil` otherwise,
    /// a pinned trust included.
    var lapsedNames: [String]? {
        guard case .changed(.names(let names)) = kind else { return nil }
        let still = names.filter { name in
            details.dnsNames.contains { ServerTrustPolicy.dnsName($0, covers: name) }
        }
        return still.isEmpty ? nil : still
    }

    func title(serverName: String) -> String {
        if lapsedNames != nil { return String(localized: "“\(serverName)”’s Certificate Is No Longer Valid") }
        return isChanged
            ? String(localized: "“\(serverName)” Has a New Certificate")
            : String(localized: "Can't Verify “\(serverName)”")
    }

    /// Why it's shown: for `changed`, what that can mean (for a trust by name
    /// that lapsed, that it did); for `untrusted`, the offer's reason line.
    func message(host: String?) -> String {
        guard isChanged else { return certificateDescription.reason(host: host) }
        if let names = lapsedNames {
            let list = names.formatted(.list(type: .and))
            return String(localized: "This certificate is still for \(list), but it can no longer be verified. It may have expired, or the authority that issued it is no longer trusted.")
        }
        return String(localized: "This isn't the certificate you trusted. If you didn't replace it, something on this network may be intercepting the connection, such as a Wi-Fi sign-in page.")
    }

    /// The trusted certificate as one row (`changed` only): its fingerprint,
    /// or for a trust kept by name, the names.
    var previousRows: [CertificateDescription.Row] { previousRows(pairsPerLine: 8) }

    func previousRows(pairsPerLine: Int) -> [CertificateDescription.Row] {
        guard case .changed(let previous) = kind else { return [] }
        if let fingerprint = previous.fingerprint {
            let text = ServerCertificateTrust.fingerprintText(fingerprint)
            return [CertificateDescription.Row(
                id: .fingerprint, title: "SHA-256",
                value: CertificateDescription.lines(of: text, pairsPerLine: pairsPerLine),
                spokenValue: text.replacingOccurrences(of: ":", with: " ")
            )]
        }
        guard case .names(let names) = previous else { return [] }
        let list = names.formatted(.list(type: .and))
        return [CertificateDescription.Row(id: .validFor, title: String(localized: "Valid For"), value: list, spokenValue: list)]
    }

    /// The heading over the presented certificate's rows: not "New" for a
    /// trust by name that lapsed, which is still the certificate trusted.
    var newHeading: String {
        isChanged && lapsedNames == nil ? String(localized: "New Certificate") : String(localized: "Certificate")
    }

    /// The heading over `previousRows`.
    var previousHeading: String { String(localized: "Trusted Certificate") }

    /// Asked before trusting a changed certificate; `untrusted` doesn't ask,
    /// as the setup offer doesn't.
    var asksBeforeTrusting: Bool { isChanged }

    static var confirmationTitle: String { String(localized: "Trust the New Certificate?") }

    static func confirmationMessage(serverName: String) -> String {
        String(localized: "Only trust it if you replaced the certificate on “\(serverName)” yourself. Dionysus will accept this certificate from now on, and no longer the one you trusted before.")
    }
}

/// The certificate's four rows: Issued To, Issued By, Expires, SHA-256. The
/// fingerprint is shown in full, monospaced, since it's what a person checks
/// against the server's.
///
/// On iOS each row is one accessibility element; on the Apple TV the caller
/// makes the whole block one focusable element (`TVCertificateTrustPage`),
/// as Full Details does, since a tvOS scroll view moves only with focus.
struct CertificateDetailsRows: View {
    let rows: [CertificateDescription.Row]
    /// The fingerprint row's identifier, when the caller's journeys need it.
    var fingerprintIdentifier: String?

    init(description: CertificateDescription, fingerprintIdentifier: String? = nil) {
        self.init(rows: description.rows, fingerprintIdentifier: fingerprintIdentifier)
    }

    /// Any rows in the same layout: the changed-certificate warning's
    /// trusted certificate is one row of its own.
    init(rows: [CertificateDescription.Row], fingerprintIdentifier: String? = nil) {
        self.rows = rows
        self.fingerprintIdentifier = fingerprintIdentifier
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: titleSpacing, verticalSpacing: rowSpacing) {
            ForEach(rows) { row in
                GridRow {
                    // The value cell speaks for the row: a modifier on a
                    // `GridRow` lands on each of its cells.
                    Text(verbatim: row.title)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                        .accessibilityHidden(true)
                    Text(verbatim: row.value)
                        .font(row.id == .fingerprint ? valueFont.monospaced() : valueFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: row.title))
                        .accessibilityValue(Text(verbatim: row.spokenValue))
                        .modifier(OptionalIdentifier(identifier: row.id.isIdentified ? fingerprintIdentifier : nil))
                }
            }
        }
        .font(titleFont)
    }

    #if os(tvOS)
    private var titleFont: Font { .callout }
    private var valueFont: Font { .callout }
    private var titleSpacing: CGFloat { 40 }
    private var rowSpacing: CGFloat { 14 }
    #else
    private var titleFont: Font { .subheadline }
    private var valueFont: Font { .subheadline }
    private var titleSpacing: CGFloat { 16 }
    private var rowSpacing: CGFloat { 10 }
    #endif
}

private struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
