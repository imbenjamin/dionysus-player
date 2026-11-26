import SwiftUI

/// The changed-certificate warning (#466), full screen over the whole app:
/// the configured server's certificate was refused, either because it isn't
/// the one the user trusted (`changed`: both fingerprints) or because nothing
/// was trusted and the system refuses it (`untrusted`: the setup offer's
/// details). Three answers, none of them a dismissal: trust it, change
/// server (confirmed, as Profile's is), or carry on offline.
///
/// The trust offer's sheet in the same family (`CertificateTrustSheet`):
/// dark, the same symbol, rows and buttons. Acting on the answer is the
/// presenter's, once the cover has gone (`CertificateWarningPresentation`).
struct CertificateWarningView: View {
    let warning: CertificateWarning
    let serverName: String
    let host: String?
    let onAnswer: (CertificateWarningAnswer) -> Void

    @State private var confirmsTrust = false
    @State private var trustConfirmed = false
    @State private var confirmsChangeServer = false
    @State private var changeServerConfirmed = false

    private var description: CertificateDescription { warning.certificateDescription }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 540)
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(HardTopScrollEdge())
        .safeAreaInset(edge: .bottom) {
            buttons
                .frame(maxWidth: 540)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                // The page scrolls under the buttons, whose glass would show
                // the fingerprint and note through it: a backing that fades
                // in over the first 20pt.
                .background {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: Color(.systemBackground), location: 0.12)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        // A cover doesn't inherit an appearance, and the buttons are
        // onboarding's, drawn for a dark surface.
        .preferredColorScheme(.dark)
        .alert(CertificateWarning.confirmationTitle, isPresented: $confirmsTrust) {
            Button("Trust") { trustConfirmed = true }
                .accessibilityIdentifier(A11yID.CertificateWarning.trustConfirmButton)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: CertificateWarning.confirmationMessage(serverName: serverName))
        }
        // SwiftUI clears `isPresented` as the button is tapped, before UIKit
        // takes the alert away: answered once that transition has finished,
        // so the cover's dismissal never runs inside the alert's own.
        .onChange(of: confirmsTrust) { _, isShown in
            guard !isShown, trustConfirmed else { return }
            trustConfirmed = false
            RootPresentations.afterTransitions { onAnswer(.trust) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.dionysusPrimary)
                .accessibilityHidden(true)

            Text(verbatim: warning.title(serverName: serverName))
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(verbatim: warning.message(host: host))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.CertificateWarning.message)

            if !warning.previousRows.isEmpty {
                certificateBox(heading: warning.previousHeading) {
                    CertificateDetailsRows(
                        rows: warning.previousRows,
                        fingerprintIdentifier: A11yID.CertificateWarning.previousFingerprint
                    )
                }
            }

            certificateBox(heading: warning.isChanged ? warning.newHeading : nil) {
                CertificateDetailsRows(
                    description: description,
                    fingerprintIdentifier: A11yID.CertificateWarning.newFingerprint
                )
            }

            if let note = description.pinNote {
                Text(verbatim: note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // On the content, not the cover's root (A11yID's rule).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.CertificateWarning.page)
    }

    /// The rows on the offer's tinted panel, under a heading when two sit
    /// one above the other.
    private func certificateBox(heading: String?, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading {
                Text(verbatim: heading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 4)
            }
            rows()
                .padding(16)
                .background(.fill.tertiary, in: .rect(cornerRadius: 18))
        }
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            OnboardingPrimaryButton(title: warning.isChanged ? "Trust New Certificate" : "Trust This Certificate") {
                if warning.asksBeforeTrusting {
                    confirmsTrust = true
                } else {
                    onAnswer(.trust)
                }
            }
            .accessibilityIdentifier(A11yID.CertificateWarning.trustButton)
            OnboardingSecondaryButton(title: "Change Server", systemImage: "server.rack") {
                confirmsChangeServer = true
            }
            .accessibilityIdentifier(A11yID.CertificateWarning.changeServerButton)
            // Profile's question: Change Server forgets the server and signs
            // out, so it asks first here too. On the button, so an iPad's
            // popover points at it.
            .confirmationDialog("Change server?", isPresented: $confirmsChangeServer, titleVisibility: .visible) {
                Button("Change Server", role: .destructive) { changeServerConfirmed = true }
                    .accessibilityIdentifier(A11yID.CertificateWarning.changeServerConfirmButton)
                Button("Cancel", role: .cancel) {}
            }
            // Answered once the dialog has gone, as Trust's alert is.
            .onChange(of: confirmsChangeServer) { _, isShown in
                guard !isShown, changeServerConfirmed else { return }
                changeServerConfirmed = false
                RootPresentations.afterTransitions { onAnswer(.changeServer) }
            }
            OnboardingSecondaryButton(title: "Not Now (Stay Offline)", systemImage: "wifi.slash") {
                onAnswer(.notNow)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(A11yID.CertificateWarning.notNowButton)
        }
    }
}

/// Text scrolled up sits under a solid band behind the status bar rather
/// than showing through it (iOS 26's hard scroll edge; the floor is 18,
/// where the page keeps the system's default).
private struct HardTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}
