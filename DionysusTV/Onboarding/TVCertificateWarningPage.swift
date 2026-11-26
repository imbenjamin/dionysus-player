import SwiftUI

/// The changed-certificate warning (#466) on the Apple TV: iOS's
/// `CertificateWarningView` as a full-screen page in the trust offer's shape
/// (`TVCertificateTrustPage`), presented by `TVRootView` over everything.
/// "Not Now (Stay Offline)" takes focus, so a stray Select trusts nothing,
/// and Menu answers the same.
///
/// Each certificate is one focusable section, as Full Details' are
/// (`DionysusTV/CLAUDE.md`): its heading as label, every row as value, since
/// focus is the only way VoiceOver reaches text here. "Trust New
/// Certificate" and Change Server (Profile's question) ask first
/// (`TVConfirmation`, Cancel focused); the answer is acted on by the caller
/// once the page has gone.
struct TVCertificateWarningPage: View {
    let warning: CertificateWarning
    let serverName: String
    let host: String?
    let onAnswer: (CertificateWarningAnswer) -> Void

    private enum Focus: Hashable { case previous, current, trust, changeServer, notNow }
    @FocusState private var focus: Focus?
    /// The question up over the page, if any.
    private enum Question: Identifiable {
        case trust, changeServer
        var id: Self { self }
    }
    @State private var question: Question?
    /// The answer a confirmed question gives, acted on once it has gone.
    @State private var confirmed: CertificateWarningAnswer?
    @State private var hasAnswered = false

    private var description: CertificateDescription { warning.certificateDescription }
    private var title: String { warning.title(serverName: serverName) }
    private var message: String { warning.message(host: host) }

    /// Two certificates to fit beside the buttons: each fingerprint on two
    /// lines, not the trust offer's four.
    private static let pairsPerLine = 16

    var body: some View {
        HStack(alignment: .center, spacing: 60) {
            // Scrolls with focus on its sections, should a long list of
            // names push it past the screen.
            ScrollView {
                details
                    .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .frame(width: 1160)

            buttons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focus, .notNow)
        // A cover doesn't stop a page beneath asking the focus system for
        // its own item (Home's "Couldn't Load Home" claims Try Again as it
        // appears, which can land after the warning): focus that leaves the
        // page is taken back, unless the page has been answered or its own
        // question is up.
        .onChange(of: focus) { _, now in
            guard now == nil, !hasAnswered, question == nil else { return }
            focus = .notNow
        }
        // Menu is Not Now: nothing else on the page goes back.
        .onExitCommand { answer(.notNow) }
        // Focus lands on Not Now, so the warning itself is said once as the
        // page opens.
        .onAppear {
            AccessibilityNotification.Announcement(title + " " + message).post()
        }
        // The page closes once the question has gone, never under it.
        .fullScreenCover(item: $question, onDismiss: {
            guard let confirmed else { return }
            self.confirmed = nil
            answer(confirmed)
        }) { question in
            switch question {
            case .trust:
                TVConfirmation(
                    title: Text(verbatim: CertificateWarning.confirmationTitle),
                    message: Text(verbatim: CertificateWarning.confirmationMessage(serverName: serverName)),
                    action: Text("Trust New Certificate"),
                    actionIdentifier: A11yID.TV.CertificateWarning.trustConfirm,
                    isDestructive: false
                ) {
                    confirmed = .trust
                }
            case .changeServer:
                // Profile's question, word for word (`TVProfileView`).
                TVConfirmation(
                    title: Text("Change Server?"),
                    message: Text("Everyone on this Apple TV will need to find a server and sign in again."),
                    action: Text("Change Server"),
                    actionIdentifier: A11yID.TV.CertificateWarning.changeServerConfirm
                ) {
                    confirmed = .changeServer
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(verbatim: title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.TV.CertificateWarning.message)
            if !previousRows.isEmpty {
                certificateSection(
                    heading: warning.previousHeading,
                    rows: previousRows,
                    spoken: previousRows.map { "\($0.title): \($0.spokenValue)" }.joined(separator: "\n"),
                    focus: .previous,
                    identifier: A11yID.TV.CertificateWarning.previousFingerprint
                )
            }
            certificateSection(
                heading: warning.isChanged ? warning.newHeading : nil,
                rows: description.rows(pairsPerLine: Self.pairsPerLine),
                // The pin note, which nothing else focusable reaches, is
                // read after the rows.
                spoken: [description.spokenRows, description.pinNote].compactMap { $0 }.joined(separator: "\n"),
                focus: .current,
                identifier: A11yID.TV.CertificateWarning.newFingerprint
            )
            if let note = description.pinNote {
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Spoken with the new certificate's section.
                    .accessibilityHidden(true)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previousRows: [CertificateDescription.Row] {
        warning.previousRows(pairsPerLine: Self.pairsPerLine)
    }

    private var buttons: some View {
        VStack(spacing: 24) {
            Button {
                if warning.asksBeforeTrusting { question = .trust } else { answer(.trust) }
            } label: {
                Text(warning.isChanged ? "Trust New Certificate" : "Trust This Certificate").frame(width: 500)
            }
            .focused($focus, equals: .trust)
            .accessibilityIdentifier(A11yID.TV.CertificateWarning.trust)
            Button { question = .changeServer } label: {
                Text("Change Server").frame(width: 500)
            }
            .focused($focus, equals: .changeServer)
            .accessibilityIdentifier(A11yID.TV.CertificateWarning.changeServer)
            Button { answer(.notNow) } label: {
                Text("Not Now (Stay Offline)").frame(width: 500)
            }
            .focused($focus, equals: .notNow)
            .accessibilityIdentifier(A11yID.TV.CertificateWarning.notNow)
        }
        .focusSection()
    }

    private func certificateSection(
        heading: String?, rows: [CertificateDescription.Row], spoken: String, focus section: Focus, identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let heading {
                Text(verbatim: heading)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            CertificateDetailsRows(rows: rows)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(focus == section ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 24))
        .focusable()
        .focused($focus, equals: section)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: heading ?? String(localized: "Certificate")))
        .accessibilityValue(Text(verbatim: spoken))
        .accessibilityIdentifier(identifier)
    }

    /// The first answer wins (a second Select or a Menu while the page
    /// closes changes nothing); the presenter closes the page.
    private func answer(_ choice: CertificateWarningAnswer) {
        guard !hasAnswered else { return }
        hasAnswered = true
        onAnswer(choice)
    }
}
