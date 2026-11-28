import SwiftUI

/// The trust offer (#466): an `https://` server whose certificate the system
/// refuses, with what the certificate is and three answers: trust it, try
/// plain HTTP instead (discovered servers only), or cancel.
///
/// Hand-built like `ServerAddressSheet`, dark like the rest of onboarding.
/// The answer is acted on once the sheet has gone
/// (`CertificateTrustPresenter`), so the HTTP fallback's alert never presents
/// while this is still closing.
struct CertificateTrustSheet: View {
    let offer: ServerSetupViewModel.CertificateTrustOffer
    let onAnswer: (CertificateTrustAnswer) -> Void

    @Environment(\.onboardingLayout) private var layout

    /// The regular layout's natural heights, measured so the fitted sheet asks
    /// for exactly its content's height.
    @State private var contentHeight: CGFloat?
    @State private var buttonsHeight: CGFloat?

    private var description: CertificateDescription { CertificateDescription(details: offer.details) }

    /// What the fitted sheet asks for; the system clamps it to the space it
    /// has, and the content scrolls under the buttons beyond that.
    private var idealHeight: CGFloat? {
        guard let contentHeight, let buttonsHeight else { return nil }
        return contentHeight + buttonsHeight
    }

    var body: some View {
        Group {
            if layout.isRegular {
                // Fitted, but neither fixed nor unscrollable: on the Duo in
                // book pose the system gives a sheet one page (459×653pt),
                // narrower and shorter than this content, which a fixed 540pt
                // laid out past the sheet's edges, buttons and all, where taps
                // never reached them.
                ScrollView {
                    content
                        .padding([.horizontal, .top], 28)
                        .padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom) {
                    buttons
                        .padding(.horizontal, 28)
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { buttonsHeight = $0 }
                }
                .frame(idealWidth: 540, maxWidth: 540, idealHeight: idealHeight)
                .presentationSizing(.fitted)
            } else {
                ScrollView {
                    content
                        .padding(.horizontal, 24)
                        .padding(.top, 32)
                        .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom) {
                    buttons
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
            }
        }
        // A sheet doesn't inherit `OnboardingFlowView`'s scoped appearance.
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.dionysusPrimary)
                .accessibilityHidden(true)

            Text("Can't Verify “\(offer.serverName)”")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(verbatim: description.reason(host: offer.configuration.baseURL.host))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.ServerSetup.certificateTrustReason)

            CertificateDetailsRows(
                description: description,
                fingerprintIdentifier: A11yID.ServerSetup.certificateTrustFingerprint
            )
            .padding(16)
            .background(.fill.tertiary, in: .rect(cornerRadius: 18))

            if let note = description.pinNote {
                Text(verbatim: note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // On the content, not the sheet's root (A11yID's rule).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.ServerSetup.certificateTrustSheet)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            OnboardingPrimaryButton(title: "Trust This Certificate") {
                onAnswer(.trust)
            }
            .accessibilityIdentifier(A11yID.ServerSetup.certificateTrustTrustButton)
            if offer.offersHTTP {
                OnboardingSecondaryButton(title: "Use Unencrypted HTTP", systemImage: "lock.open") {
                    onAnswer(.useHTTP)
                }
                .accessibilityIdentifier(A11yID.ServerSetup.certificateTrustHTTPButton)
            }
            OnboardingSecondaryButton(title: "Cancel", systemImage: "xmark") {
                onAnswer(.cancel)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(A11yID.ServerSetup.certificateTrustCancelButton)
        }
    }
}

extension ServerSetupViewModel.CertificateTrustOffer: Identifiable {
    var id: String { "\(configuration.baseURL.absoluteString)#\(details.fingerprint.base64EncodedString())" }
}

/// Presents `CertificateTrustSheet` whenever `viewModel` makes an offer, and
/// acts on its answer once it has gone. `onTrusted` gets the configuration
/// to save.
struct CertificateTrustPresenter: ViewModifier {
    let viewModel: ServerSetupViewModel
    /// Off while another sheet from the same screen should present it instead
    /// (the address sheet presents its own).
    var isEnabled = true
    let onTrusted: (ServerConfiguration) -> Void

    @State private var presented: ServerSetupViewModel.CertificateTrustOffer?
    @State private var answer: CertificateTrustAnswer?

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.certificateTrustOffer, initial: true) { _, offer in
                guard isEnabled else { return }
                presented = offer
            }
            .sheet(item: $presented, onDismiss: dismissed) { offer in
                CertificateTrustSheet(offer: offer) { choice in
                    answer = choice
                    presented = nil
                }
            }
    }

    private func dismissed() {
        let choice = answer
        answer = nil
        switch choice {
        case .trust:
            Task {
                if let configuration = await viewModel.trustOfferedCertificate() {
                    onTrusted(configuration)
                }
            }
        case .useHTTP:
            Task { await viewModel.useUnencryptedHTTPInstead() }
        case .cancel, nil:
            // The certificate error stays on screen.
            viewModel.declineCertificateTrust()
        }
    }
}

extension View {
    func certificateTrustOffer(
        from viewModel: ServerSetupViewModel,
        isEnabled: Bool = true,
        onTrusted: @escaping (ServerConfiguration) -> Void
    ) -> some View {
        modifier(CertificateTrustPresenter(viewModel: viewModel, isEnabled: isEnabled, onTrusted: onTrusted))
    }
}
