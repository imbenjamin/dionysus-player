import SwiftUI

/// Asks which port a discovered HTTPS server's plain HTTP is on, when nothing
/// answered on Jellyfin's default (`ServerSetupViewModel.httpPortRequest`):
/// iOS's alert, as a full-screen cover like the Apple TV's other questions,
/// so Menu closes it. The port is typed with the system keyboard, as Quick
/// Connect approval's code is.
///
/// Trying the port is the caller's, after the cover has gone
/// (`TVServerSetupView`), so the confirmation that may follow never
/// presents while this one is still closing.
struct TVHTTPPortPage: View {
    @Environment(\.dismiss) private var dismiss
    let request: ServerSetupViewModel.HTTPPortRequest
    let onTry: (String) -> Void
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            Text("Connect Over HTTP?").font(.title2.bold())
            Text(verbatim: request.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            TextField("HTTP Port", text: $text)
                .keyboardType(.numberPad)
                .frame(width: 500)
                .focused($fieldFocused)
                .accessibilityIdentifier(A11yID.TV.Onboarding.httpPortField)
            VStack(spacing: 24) {
                Button {
                    onTry(text)
                    dismiss()
                } label: {
                    Text("Try Port").frame(width: 500)
                }
                .disabled(ServerSetupViewModel.parsePort(text) == nil)
                .accessibilityIdentifier(A11yID.TV.Onboarding.httpPortTry)
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel").frame(width: 500)
                }
                .accessibilityIdentifier(A11yID.TV.Onboarding.httpPortCancel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($fieldFocused, true)
        // Only buttons and the field take focus, so the question itself is
        // said once as the page opens.
        .onAppear {
            AccessibilityNotification.Announcement(
                String(localized: "Connect Over HTTP?") + " " + request.message
            ).post()
        }
    }
}
