import SwiftUI

/// One-time setup screen where the user points the app at their Jellyfin
/// server (LAN IP:port, domain name, or full URL), or picks one a
/// local-network scan found (`ServerDiscovery.swift`).
///
/// Deliberately has no `NavigationStack`. It used to sit in one purely to
/// get a "Connect to Server" title bar, which gave the screen two
/// competing names — that title, and the `Find Your Server` large title
/// immediately under it. Dropping the bar keeps the icon-plus-title
/// identity a first-run screen wants, and hands back the ~44pt the bar
/// was spending, the scarcest thing on this layout once the keyboard is
/// up. Neither this screen nor `LoginView` pushes anything, so nothing
/// else was using the stack.
struct ServerSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var addressFieldFocused: Bool
    @State private var httpPortText = ""

    /// The manual-entry block — field, HTTPS toggle and its hint — scrolled
    /// above the keyboard when it appears (see the `keyboardDidShow` handler).
    private let addressEntryID = "addressEntry"

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    discoverySection
                        // On this section rather than beside the other alert on
                        // the scroll view, so the two presentations never share a
                        // view: one follows the other directly.
                        .alert(
                            "Connect Over HTTP?",
                            isPresented: Binding(
                                get: { viewModel.httpPortRequest != nil },
                                set: { if !$0 { viewModel.cancelHTTPPortRequest() } }
                            ),
                            presenting: viewModel.httpPortRequest
                        ) { request in
                            TextField("HTTP Port", text: $httpPortText)
                                .keyboardType(.numberPad)
                                .accessibilityLabel("HTTP Port")
                            Button("Try Port") {
                                let text = httpPortText
                                Task { await viewModel.tryHTTPPort(text, for: request) }
                            }
                            .disabled(ServerSetupViewModel.parsePort(httpPortText) == nil)
                            .accessibilityIdentifier(A11yID.ServerSetup.httpPortConfirmButton)
                            Button("Cancel", role: .cancel) {
                                viewModel.cancelHTTPPortRequest()
                            }
                            .accessibilityIdentifier(A11yID.ServerSetup.httpPortCancelButton)
                        } message: { request in
                            Text(httpPortMessage(for: request))
                        }

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
                    .id(addressEntryID)

                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .accessibilityIdentifier(A11yID.ServerSetup.errorMessage)
                            .font(.footnote)
                            // `dionysusPrimary`, not the raw `dionysusMagenta`
                            // this used to use. Both render the same colour by
                            // default — 4.11:1 against black — because
                            // `dionysusPrimary`'s dark branch *is*
                            // `dionysusMagenta`. That 4.1:1 is the palette's
                            // own documented trade-off (see
                            // `Color.dionysusMagentaHighContrast`), accepted
                            // app-wide, not decided locally.
                            //
                            // What changes is Increase Contrast: the static
                            // constant ignores it (still 4.11:1 with the
                            // setting on — a `Color` literal has no traits to
                            // respond to), while the dynamic one picks up
                            // `dionysusMagentaHighContrast` and measures 6.58:1.
                            // This error label was the only place opted out of
                            // that mechanism.
                            .foregroundStyle(Color.dionysusPrimary)
                    }
                }
                .padding(SignInLayout.contentPadding)
                .signInColumn()
            }
            .statusBarScrollFade()
            // Pinned rather than sitting after a `Spacer()` at the bottom of
            // the content. Keyboard-up is this screen's state for as long as an
            // address is being typed, and in landscape that used to compress
            // the layout until Connect landed at
            // y=381-431.5 behind a keyboard whose top edge is ~y=355 —
            // invisible, with no scroll view to reach it and only a hardware
            // Return key to submit.
            .safeAreaInset(edge: .bottom) { connectButton }
            // The keyboard covers the lower part of the screen, and on a phone
            // that's where the HTTPS toggle sits — which decides how a bare
            // address is connected to, so it has to stay reachable while one
            // is typed. The scroll view only brings the *focused field* into
            // view, so bring the whole block up once the keyboard
            // has settled: on `didShow`, because before that the keyboard's
            // inset isn't in the layout yet and the scroll would stop short.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard addressFieldFocused else { return }
                withAnimation { scrollProxy.scrollTo(addressEntryID, anchor: .bottom) }
            }
        }
        // No autofocus on appear. The field used to take focus straight away,
        // but with scanning above it the keyboard would then cover the scan
        // results, and scrolling the field's block into view would push the
        // Scan button off the top — the easier of the two ways in.
        .onDisappear { viewModel.cancelScan() }
        // `.alert`, not `.confirmationDialog`: the latter isn't guaranteed to
        // render its cancel button, and backing out is half the point here.
        .alert(
            "Connect Without Encryption?",
            isPresented: Binding(
                get: { viewModel.insecureFallbackOffer != nil },
                set: { if !$0 { viewModel.declineInsecureFallback() } }
            ),
            presenting: viewModel.insecureFallbackOffer
        ) { _ in
            Button("Connect Over HTTP") {
                guard let configuration = viewModel.acceptInsecureFallback() else { return }
                appState.completeServerSetup(configuration)
            }
            .accessibilityIdentifier(A11yID.ServerSetup.insecureFallbackConfirmButton)
            Button("Cancel", role: .cancel) {
                viewModel.declineInsecureFallback()
            }
            .accessibilityIdentifier(A11yID.ServerSetup.insecureFallbackCancelButton)
        } message: { offer in
            Text("\(offer.server.name)'s security certificate can't be verified, but the server also answers over unencrypted HTTP at \(offer.httpDisplayAddress). Your password and everything you watch would be sent without encryption, readable by others on this network.")
        }
        // A `Label` appearing mid-screen is silent to VoiceOver, so a
        // failed connection otherwise reads as nothing happening at all.
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        // Results arrive in a list VoiceOver's focus isn't on — it's still on
        // the scan button — so say how the scan ended.
        .onChange(of: viewModel.scanState) { _, state in
            guard let announcement = scanAnnouncement(for: state) else { return }
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    // MARK: - Discovery

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Servers on Your Network")
                .font(.headline)

            ForEach(viewModel.discoveredServers) { server in
                discoveredServerRow(server)
            }

            scanStatus

            Button {
                // The keyboard is up by default (the address field takes
                // focus on appear) and would cover the results.
                addressFieldFocused = false
                viewModel.startScan()
            } label: {
                Group {
                    if viewModel.scanState == .scanning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Scanning…")
                        }
                    } else {
                        Label(
                            viewModel.scanState == .idle ? "Scan for Servers" : "Scan Again",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.scanState == .scanning || viewModel.isTesting)
            .accessibilityIdentifier(A11yID.ServerSetup.scanButton)
        }
    }

    private func discoveredServerRow(_ server: DiscoveredServer) -> some View {
        Button {
            Task { await connect(to: server) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(server.displayAddress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if viewModel.connectingServerID == server.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            // The label has a `Spacer`, which doesn't hit-test on its own.
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isTesting)
        .accessibilityValue(viewModel.connectingServerID == server.id ? String(localized: "Connecting") : "")
        .accessibilityHint("Connects to this server")
        .accessibilityIdentifier(A11yID.ServerSetup.discoveredServer(server.id))
    }

    /// A line under the results once a scan has ended with nothing to show,
    /// or couldn't run. Nothing while scanning or after a scan that found
    /// servers — the rows say it.
    @ViewBuilder
    private var scanStatus: some View {
        switch viewModel.scanState {
        case .idle:
            Text("Look for Jellyfin servers on the same Wi-Fi network as this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .scanning:
            EmptyView()
        case .finished where viewModel.discoveredServers.isEmpty:
            Text("No servers found. Check that this device is on the same Wi-Fi network as your server, or enter its address below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.ServerSetup.scanStatus)
        case .finished:
            EmptyView()
        case .failed(.noLocalNetwork):
            Label("Connect to Wi-Fi to scan for servers on your network.", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.ServerSetup.scanStatus)
        case .failed(.localNetworkAccessDenied):
            VStack(alignment: .leading, spacing: 6) {
                Label("Dionysus doesn't have access to your local network. Turn on Local Network for Dionysus in Settings, then scan again.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .font(.footnote.weight(.semibold))
            }
            .accessibilityIdentifier(A11yID.ServerSetup.scanStatus)
        }
    }

    private func scanAnnouncement(for state: ServerSetupViewModel.ScanState) -> String? {
        switch state {
        case .idle, .scanning:
            return nil
        case .finished:
            let count = viewModel.discoveredServers.count
            return count == 0
                ? String(localized: "No servers found")
                : String(localized: "Servers found: \(count)")
        case .failed(.noLocalNetwork):
            return String(localized: "Connect to Wi-Fi to scan for servers on your network.")
        case .failed(.localNetworkAccessDenied):
            return String(localized: "Dionysus doesn't have access to your local network.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                // Decorative — the heading and body text below already say
                // what this screen is. Without this, SwiftUI falls back to
                // the SF Symbol's own name and VoiceOver announces the
                // literal string "server.rack" (caught by
                // `AccessibilityAuditTests`: "The accessibilityLabel of
                // this SwiftUI.AccessibilityNode is not human-readable").
                .accessibilityHidden(true)
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

    private func httpPortMessage(for request: ServerSetupViewModel.HTTPPortRequest) -> String {
        let explanation = String(localized: "\(request.server.name)'s security certificate can't be verified. If the server also accepts unencrypted HTTP connections, enter the port it uses for them.")
        guard let problem = request.problem else { return explanation }
        return problem + "\n\n" + explanation
    }

    private func connect(to server: DiscoveredServer) async {
        guard let configuration = await viewModel.connect(to: server) else { return }
        appState.completeServerSetup(configuration)
    }
}

#Preview {
    ServerSetupView()
        .environment(AppState())
}
