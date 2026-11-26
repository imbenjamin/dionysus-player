import SwiftUI

/// The trust offer (#466) on the Apple TV: iOS's sheet as a full-screen
/// cover, like `TVHTTPPortPage`, so Menu closes it. Cancel takes focus, so a
/// stray Select trusts nothing.
///
/// The certificate's rows are one focusable section, as Full Details' are
/// (`DionysusTV/CLAUDE.md`): its heading as label, every row as value, since
/// focus is the only way VoiceOver reaches text here. Acting on the answer is
/// the caller's, after the cover has gone (`TVServerSetupView`).
struct TVCertificateTrustPage: View {
    @Environment(\.dismiss) private var dismiss
    let offer: ServerSetupViewModel.CertificateTrustOffer
    let onAnswer: (CertificateTrustAnswer) -> Void

    private enum Focus: Hashable { case details, trust, http, cancel }
    @FocusState private var focus: Focus?

    private var description: CertificateDescription { CertificateDescription(details: offer.details) }
    private var reason: String { description.reason(host: offer.configuration.baseURL.host) }
    private var title: String { String(localized: "Can't Verify “\(offer.serverName)”") }

    var body: some View {
        HStack(alignment: .center, spacing: 80) {
            VStack(alignment: .leading, spacing: 30) {
                Text(verbatim: title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: reason)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(A11yID.TV.Onboarding.certificateTrustReason)
                CertificateDetailsRows(description: description)
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(focus == .details ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 24))
                    .focusable()
                    .focused($focus, equals: .details)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Certificate"))
                    // The pin note, which nothing else focusable reaches,
                    // is read after the rows.
                    .accessibilityValue(Text(verbatim: detailsSpokenValue))
                    .accessibilityIdentifier(A11yID.TV.Onboarding.certificateTrustDetails)
                if let note = description.pinNote {
                    Text(verbatim: note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Spoken with the details, the focusable element.
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 1000, alignment: .leading)

            VStack(spacing: 24) {
                Button { answer(.trust) } label: {
                    Text("Trust This Certificate").frame(width: 500)
                }
                .focused($focus, equals: .trust)
                .accessibilityIdentifier(A11yID.TV.Onboarding.certificateTrustTrust)
                if offer.offersHTTP {
                    Button { answer(.useHTTP) } label: {
                        Text("Use Unencrypted HTTP").frame(width: 500)
                    }
                    .focused($focus, equals: .http)
                    .accessibilityIdentifier(A11yID.TV.Onboarding.certificateTrustHTTP)
                }
                Button(role: .cancel) { answer(.cancel) } label: {
                    Text("Cancel").frame(width: 500)
                }
                .focused($focus, equals: .cancel)
                .accessibilityIdentifier(A11yID.TV.Onboarding.certificateTrustCancel)
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focus, .cancel)
        // Focus lands on Cancel, so the question itself is said once as the
        // page opens.
        .onAppear {
            AccessibilityNotification.Announcement(title + " " + reason).post()
        }
    }

    /// Every row, then the pin note when there is one.
    private var detailsSpokenValue: String {
        [description.spokenRows, description.pinNote].compactMap { $0 }.joined(separator: "\n")
    }

    private func answer(_ choice: CertificateTrustAnswer) {
        onAnswer(choice)
        dismiss()
    }
}
