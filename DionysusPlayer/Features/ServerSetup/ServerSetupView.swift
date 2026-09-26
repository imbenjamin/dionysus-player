import SwiftUI

/// Finds the user's Jellyfin server, scan first: a local-network scan
/// (`ServerDiscovery.swift`) starts on arrival — the user has just tapped
/// "Get Started", and the screen says why iOS may ask about the local network
/// — and each server found is one tap. Typing an address moves into a sheet
/// (`ServerAddressSheet`) for the minority who need it.
///
/// Part of `OnboardingFlowView`, which supplies the background, the glyph's
/// transition and the composition.
struct ServerSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.onboardingLayout) private var layout
    @State private var viewModel = ServerSetupViewModel()
    @State private var httpPortText = ""
    @State private var isShowingAddressSheet = false

    var body: some View {
        OnboardingScreen {
            header
        } content: {
            results
                // Reserves the results' space on iPad, where the block is
                // centred: without it the header jumps as the radar gives way
                // to cards of a different height.
                .frame(minHeight: layout.isRegular ? 280 : nil, alignment: .top)
        } actions: {
            OnboardingSecondaryButton(title: "Enter Address Manually", systemImage: "keyboard") {
                isShowingAddressSheet = true
            }
            .disabled(viewModel.isTesting)
            .accessibilityIdentifier(A11yID.ServerSetup.manualEntryButton)
        }
        .sheet(isPresented: $isShowingAddressSheet) {
            ServerAddressSheet(viewModel: viewModel) { configuration in
                isShowingAddressSheet = false
                appState.completeServerSetup(configuration)
            }
        }
        .task { viewModel.startScanOnArrival() }
        .onDisappear { viewModel.cancelScan() }
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
        // A separate `.alert` on a separate view from the one above, so the
        // two presentations never share a view: one follows the other
        // directly. `.alert` rather than `.confirmationDialog`, which isn't
        // guaranteed to render its cancel button — and backing out is half
        // the point here.
        .background {
            Color.clear
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
        }
        // A message appearing mid-screen is silent to VoiceOver, so a failed
        // connection otherwise reads as nothing happening at all.
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        // Results arrive where VoiceOver's focus isn't, so say how the scan
        // ended.
        .onChange(of: viewModel.scanState) { _, state in
            guard let announcement = scanAnnouncement(for: state) else { return }
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    // MARK: - Header

    /// Centred, like the welcome and sign-in headers either side of it, so the
    /// glyph stays on one axis through the whole journey.
    private var header: some View {
        VStack(spacing: layout.isRegular ? 16 : 10) {
            DionysusGlassGlyph()
                .onboardingGlyph()
                .frame(width: layout.headerGlyph, height: layout.headerGlyph)
            OnboardingTitle("Find Your Server")
            FadingText(text: subtitle)
                .font(layout.isRegular ? .title3 : .body)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        switch viewModel.scanState {
        case .idle, .scanning:
            String(localized: "Looking for Jellyfin servers on your Wi-Fi. If iOS asks, allow Local Network access so Dionysus can find yours.")
        case .finished where viewModel.discoveredServers.isEmpty, .failed:
            String(localized: "You can still connect by entering your server's address.")
        case .finished:
            String(localized: "Choose your server to continue.")
        }
    }

    // MARK: - Results

    private var results: some View {
        VStack(spacing: 20) {
            if viewModel.scanState == .scanning && viewModel.discoveredServers.isEmpty {
                ScanRadar(scale: layout.isRegular ? 1.3 : 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: layout.isRegular ? 260 : 200)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            VStack(spacing: 12) {
                ForEach(viewModel.discoveredServers) { server in
                    serverCard(server)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Servers answer one by one, and a scan runs on for a few seconds
            // after the first: without this, the radar giving way to the first
            // card read as the scan having finished.
            if viewModel.scanState == .scanning && !viewModel.discoveredServers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Still searching…")
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .frame(minHeight: 44)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(A11yID.ServerSetup.scanningIndicator)
            }

            if let errorMessage = viewModel.errorMessage, !isShowingAddressSheet {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onboardingGlass(in: .rect(cornerRadius: 18))
                    .accessibilityIdentifier(A11yID.ServerSetup.errorMessage)
            }

            scanStatus
        }
        .animation(.smooth, value: viewModel.discoveredServers)
        .animation(.smooth, value: viewModel.scanState)
    }

    private func serverCard(_ server: DiscoveredServer) -> some View {
        Button {
            Task { await connect(to: server) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(layout.isRegular ? .title2 : .title3)
                    .frame(width: layout.isRegular ? 52 : 44, height: layout.isRegular ? 52 : 44)
                    .background(.white.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name)
                        .font(layout.isRegular ? .title3.weight(.semibold) : .headline)
                    Text(server.displayAddress)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                    if let version = viewModel.serverVersions[server.id] {
                        // A product name and a version number, not translated.
                        Text(verbatim: "Jellyfin \(version)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .transition(.opacity)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if viewModel.connectingServerID == server.id {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityHidden(true)
                }
            }
            .padding(layout.isRegular ? 20 : 16)
            // The label has a `Spacer`, which doesn't hit-test on its own.
            .contentShape(.rect(cornerRadius: 22))
            .hoverEffect(.lift)
        }
        .buttonStyle(.plain)
        .onboardingGlass(in: .rect(cornerRadius: 22), interactive: true)
        .disabled(viewModel.isTesting)
        .animation(.smooth, value: viewModel.serverVersions[server.id])
        .accessibilityValue(viewModel.connectingServerID == server.id ? String(localized: "Connecting") : "")
        .accessibilityHint("Connects to this server")
        .accessibilityIdentifier(A11yID.ServerSetup.discoveredServer(server.id))
    }

    /// Nothing while scanning; "Scan Again" once servers are listed; a card
    /// explaining an empty or failed scan otherwise.
    @ViewBuilder
    private var scanStatus: some View {
        switch viewModel.scanState {
        case .idle, .scanning:
            EmptyView()
        case .finished where viewModel.discoveredServers.isEmpty:
            statusCard(
                title: "No servers found",
                systemImage: "wifi.exclamationmark",
                message: "Make sure this device is on the same Wi-Fi as your server, or enter its address instead."
            ) {
                rescanButton("Try Again")
            }
        case .finished:
            rescanButton("Scan Again")
                .foregroundStyle(.white.opacity(0.85))
        case .failed(.noLocalNetwork):
            statusCard(
                title: "Not on Wi-Fi",
                systemImage: "wifi.slash",
                message: "Connect to Wi-Fi to scan for servers on your network."
            ) {
                rescanButton("Try Again")
            }
        case .failed(.localNetworkAccessDenied):
            statusCard(
                title: "No local network access",
                systemImage: "lock.shield",
                message: "Dionysus doesn't have access to your local network. Turn on Local Network for Dionysus in Settings, then scan again."
            ) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("Open Settings")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .hoverEffect(.highlight)
                rescanButton("Scan Again")
            }
        }
    }

    private func statusCard(
        title: LocalizedStringKey,
        systemImage: String,
        message: LocalizedStringKey,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                actions()
            }
            .foregroundStyle(.white)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingGlass(in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.ServerSetup.scanStatus)
    }

    private func rescanButton(_ title: LocalizedStringKey) -> some View {
        Button {
            viewModel.startScan()
        } label: {
            Label(title, systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .keyboardShortcut("r", modifiers: .command)
        .disabled(viewModel.isTesting)
        .accessibilityIdentifier(A11yID.ServerSetup.scanButton)
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

    // MARK: - Actions

    private func connect(to server: DiscoveredServer) async {
        guard let configuration = await viewModel.connect(to: server) else { return }
        appState.completeServerSetup(configuration)
    }

    private func httpPortMessage(for request: ServerSetupViewModel.HTTPPortRequest) -> String {
        let explanation = String(localized: "\(request.server.name)'s security certificate can't be verified. If the server also accepts unencrypted HTTP connections, enter the port it uses for them.")
        guard let problem = request.problem else { return explanation }
        return problem + "\n\n" + explanation
    }
}

/// Concentric rings pulsing out from an antenna while a scan runs — still
/// rings under Reduce Motion.
private struct ScanRadar: View {
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if OnboardingMotion.isAllowed(reduceMotion: reduceMotion) {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3) { ring in
                            let progress = (time / 2.4 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .strokeBorder(.white.opacity(0.55 * (1 - progress)), lineWidth: 1.5)
                                .frame(width: (60 + 140 * progress) * scale)
                        }
                    }
                }
            } else {
                ForEach(1..<4) { ring in
                    Circle()
                        .strokeBorder(.white.opacity(0.35 - Double(ring) * 0.08), lineWidth: 1.5)
                        .frame(width: (60 + CGFloat(ring) * 44) * scale)
                }
            }
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(scale > 1 ? .title : .title2)
                .frame(width: 64 * scale, height: 64 * scale)
                .onboardingGlass(in: Circle())
        }
        .accessibilityElement()
        .accessibilityLabel("Searching for servers")
    }
}

#Preview {
    ZStack {
        OnboardingBackground()
        ServerSetupView()
    }
    .environment(AppState())
    .environment(\.colorScheme, .dark)
    .foregroundStyle(.white)
}
