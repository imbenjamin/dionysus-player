import SwiftUI

/// One-time setup screen where the user points the app at their Jellyfin
/// server (LAN IP:port, domain name, or full URL).
///
/// Deliberately has no `NavigationStack`. It used to sit in one purely
/// to get a "Connect to Server" title bar, which gave the screen two
/// competing names — that title, and the `Find Your Server` large title
/// immediately under it. Dropping the bar rather than the in-content
/// header keeps the icon-plus-title identity a first-run screen wants,
/// and hands back the ~44pt the bar was spending, which is the scarcest
/// thing on this layout once the keyboard is up. Neither this screen nor
/// `LoginView` pushes anything, so nothing else was using the stack.
struct ServerSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var addressFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    Text("Server Address")
                        .font(.headline)

                    TextField("192.168.1.50:8096", text: $viewModel.address)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFieldFocused)
                        // The visible "Server Address" heading above is a
                        // separate `Text`, so without this the field
                        // reaches VoiceOver with no label at all —
                        // announced as its placeholder while empty, and
                        // as nothing but the typed address once filled.
                        .accessibilityLabel("Server Address")
                        .accessibilityIdentifier(A11yID.ServerSetup.addressField)
                        .onSubmit { Task { await connect() } }
                        .onChange(of: viewModel.address) { _, newAddress in
                            viewModel.syncHTTPSToggle(withAddress: newAddress)
                        }

                    Toggle("Use HTTPS", isOn: $viewModel.useHTTPS)
                        .accessibilityIdentifier(A11yID.ServerSetup.httpsToggle)

                    Text("Enter your server's local IP and port, a domain name, or a full URL.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .accessibilityIdentifier(A11yID.ServerSetup.errorMessage)
                        .font(.footnote)
                        // `dionysusPrimary`, not the raw `dionysusMagenta`
                        // this used to use. Both render the same colour in
                        // dark mode by default — 4.11:1 against black,
                        // measured live — because `dionysusPrimary`'s dark
                        // branch *is* `dionysusMagenta`. That 4.1:1 is the
                        // palette's own documented trade-off (see
                        // `Color.dionysusMagentaHighContrast`), accepted
                        // app-wide, not something these screens get to
                        // decide locally.
                        //
                        // What changes is Increase Contrast. The static
                        // constant ignored it — verified live, still
                        // 4.11:1 with the setting on, because a `Color`
                        // literal has no traits to respond to. The dynamic
                        // one picks up `dionysusMagentaHighContrast` and
                        // measures 6.58:1. This error label was the only
                        // place in the app opted out of that mechanism.
                        .foregroundStyle(Color.dionysusPrimary)
                }
            }
            .padding(SignInLayout.contentPadding)
            .signInColumn()
        }
        // Pinned rather than sitting after a `Spacer()` at the bottom of
        // the content. The field takes focus in `onAppear`, so
        // keyboard-up is this screen's *default* state, and in landscape
        // that used to compress the layout until Connect landed at
        // y=381-431.5 behind a keyboard whose top edge is ~y=355 — the
        // primary action invisible, with no scroll view to reach it and
        // only a hardware Return key to submit.
        .safeAreaInset(edge: .bottom) { connectButton }
        .onAppear { addressFieldFocused = true }
        // A `Label` appearing mid-screen is silent to VoiceOver, so a
        // failed connection otherwise reads as nothing happening at all.
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Find Your Server")
                .font(.largeTitle.bold())
            Text("Dionysus needs the address of your Jellyfin server to get started.")
                .foregroundStyle(.secondary)
        }
    }

    private var connectButton: some View {
        Button {
            Task { await connect() }
        } label: {
            Group {
                if viewModel.isTesting {
                    ProgressView()
                } else {
                    Text("Connect")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!viewModel.canSubmit)
        // Swapping the label for a `ProgressView` takes the button's name
        // with it, leaving VoiceOver an unlabelled progress indicator
        // where the primary action was. Naming the button here keeps it
        // stable across both states, with the state itself as the value.
        .accessibilityLabel("Connect")
        .accessibilityIdentifier(A11yID.ServerSetup.connectButton)
        .accessibilityValue(viewModel.isTesting ? String(localized: "Connecting") : "")
        .padding(.horizontal, SignInLayout.contentPadding)
        .padding(.vertical, 12)
        .signInColumn()
        .background(.bar)
    }

    private func connect() async {
        guard let configuration = await viewModel.testConnection() else { return }
        appState.completeServerSetup(configuration)
    }
}

#Preview {
    ServerSetupView()
        .environment(AppState())
}
