import SwiftUI

/// Find Your Server, on the shared `ServerSetupViewModel`, in the prototype's
/// layout: a scanning radar on the left, the servers found on the right.
/// Scanning starts on arrival; the first server found takes default focus, so
/// one Select connects. Typing an address is the secondary route, behind
/// Enter Server Address, which heads the field once it's open. Once a scan
/// is over, Rescan scans again from an empty list.
struct TVServerSetupView: View {
    /// A `server?url=` link's address (#406, DEBUG builds only): the
    /// address field opens with it filled in and focused; Connect is still
    /// the person's press.
    var linkedAddress: LinkedServerAddress? = nil

    @Environment(AppState.self) private var appState
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var focusedServer: DiscoveredServer.ID?
    @FocusState private var addressFocused: Bool
    /// Whether the person has moved focus themselves. Discovery answers after
    /// the screen's first focus pass, so `defaultFocus` alone never reaches a
    /// server; the first one found takes focus unless they've moved already.
    @State private var userMovedFocus = false
    @State private var showsAddressEntry = false
    /// The HTTP fallback's question on show (#429), mirrored from the view
    /// model, whose own state stays set until `fallbackDismissed` answers it.
    @State private var fallbackCover: FallbackCover?
    /// What the question's cover was closed with; nil is Cancel or Menu.
    @State private var fallbackAnswer: FallbackAnswer?

    /// A discovered HTTPS server whose certificate fails, but which may answer
    /// over plain HTTP: which port (when 8096 is silent), then whether to
    /// connect unencrypted. iOS asks both in alerts; here each is a cover.
    private enum FallbackCover: Identifiable {
        case port(ServerSetupViewModel.HTTPPortRequest)
        case offer(ServerSetupViewModel.InsecureFallbackOffer)

        var id: String {
            switch self {
            case .port(let request): "port.\(request.server.id).\(request.problem ?? "")"
            case .offer(let offer): "offer.\(offer.configuration.baseURL)"
            }
        }
    }

    private enum FallbackAnswer {
        case tryPort(String, ServerSetupViewModel.HTTPPortRequest)
        case connect
    }

    var body: some View {
        TVBrandBackground {
            TVOnboardingPanes {
                TVScanRadar(isScanning: viewModel.scanState == .scanning)
            } task: {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Find Your Server")
                            .font(.title2.bold())
                            .accessibilityIdentifier(A11yID.TV.Onboarding.findServerTitle)
                        Text("Jellyfin servers on this network appear here as they're found.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.discoveredServers) { server in
                            serverRow(server)
                        }
                    }
                    .defaultFocus($focusedServer, viewModel.discoveredServers.first?.id)
                    .onChange(of: viewModel.discoveredServers.first?.id) { _, firstID in
                        guard !userMovedFocus, focusedServer == nil, !showsAddressEntry, let firstID else { return }
                        focusedServer = firstID
                    }
                    .onChange(of: viewModel.discoveredServers.count) { previous, count in
                        guard let text = TVOnboardingSpeech.foundServersAnnouncement(count: count, previousCount: previous) else { return }
                        AccessibilityNotification.Announcement(text).post()
                    }
                    // Rescan, or how the scan is going, on a line of its
                    // own above Enter Server Address (Benjamin, 2026-10-05).
                    if canRescan || statusText != nil {
                        HStack(spacing: 30) {
                            // Once the scan is over: scan again from an
                            // empty list.
                            if canRescan {
                                Button {
                                    userMovedFocus = false
                                    viewModel.rescan()
                                } label: {
                                    Label("Rescan", systemImage: "arrow.clockwise")
                                }
                                .accessibilityIdentifier(A11yID.TV.Onboarding.rescan)
                            }
                            if let statusText {
                                Text(statusText).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if showsAddressEntry {
                        // Heads the field once it's shown, in the button's
                        // own type, rather than offering what's already open
                        // (Benjamin, 2026-10-05).
                        Label("Enter Server Address", systemImage: "keyboard")
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(A11yID.TV.Onboarding.enterAddress)
                    } else {
                        Button {
                            showsAddressEntry = true
                        } label: {
                            Label("Enter Server Address", systemImage: "keyboard")
                        }
                        .accessibilityIdentifier(A11yID.TV.Onboarding.enterAddress)
                    }
                    if showsAddressEntry {
                        addressRow
                    }
                    if let error = viewModel.errorMessage {
                        Text(error).foregroundStyle(.red).font(.callout)
                            .accessibilityIdentifier(A11yID.TV.Onboarding.serverSetupError)
                    }
                }
            }
        }
        .onAppear { viewModel.startScanOnArrival() }
        .onChange(of: linkedAddress, initial: true) { _, linked in
            guard let linked else { return }
            viewModel.address = linked.address
            viewModel.syncHTTPSToggle(withAddress: linked.address)
            userMovedFocus = true
            showsAddressEntry = true
        }
        // Enter Server Address turns into the field's heading, so the focus
        // it had is dropped and tvOS hands it to the server list's default.
        // A claim made as the field appears loses to that, so it's made
        // until it holds.
        .task(id: showsAddressEntry) {
            guard showsAddressEntry else { return }
            var attempts = 0
            while !addressFocused, attempts < 20 {
                addressFocused = true
                attempts += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onChange(of: viewModel.scanState == .scanning) { wasScanning, isScanning in
            guard let text = TVOnboardingSpeech.scanEndedAnnouncement(
                wasScanning: wasScanning, isScanning: isScanning, serverCount: viewModel.discoveredServers.count
            ) else { return }
            AccessibilityNotification.Announcement(text).post()
        }
        // The error shows below everything while focus stays put.
        .onChange(of: viewModel.errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onMoveCommand { _ in userMovedFocus = true }
        .onChange(of: viewModel.httpPortRequest) { _, request in
            if let request { fallbackCover = .port(request) }
        }
        .onChange(of: viewModel.insecureFallbackOffer) { _, offer in
            if let offer { fallbackCover = .offer(offer) }
        }
        // Answered once the cover has gone, as the Apple TV's other questions
        // are, so a port that works can raise the next question cleanly.
        .fullScreenCover(item: $fallbackCover, onDismiss: fallbackDismissed) { cover in
            switch cover {
            case .port(let request):
                TVHTTPPortPage(request: request) { text in
                    fallbackAnswer = .tryPort(text, request)
                }
            case .offer(let offer):
                // iOS's words; Cancel takes focus, so a stray Select doesn't
                // send a password unencrypted.
                TVConfirmation(
                    title: Text("Connect Without Encryption?"),
                    message: Text("\(offer.server.name)'s security certificate can't be verified, but the server also answers over unencrypted HTTP at \(offer.httpDisplayAddress). Your password and everything you watch would be sent without encryption, readable by others on this network."),
                    action: Text("Connect Over HTTP"),
                    actionIdentifier: A11yID.TV.Onboarding.insecureFallbackConfirm,
                    isDestructive: false
                ) { fallbackAnswer = .connect }
            }
        }
    }

    private func fallbackDismissed() {
        let answer = fallbackAnswer
        fallbackAnswer = nil
        switch answer {
        case .tryPort(let text, let request):
            Task {
                await viewModel.tryHTTPPort(text, for: request)
                // A port that fails again with the same reason is the same
                // request, which `onChange` wouldn't see.
                if let request = viewModel.httpPortRequest {
                    fallbackCover = .port(request)
                }
            }
        case .connect:
            if let configuration = viewModel.acceptInsecureFallback() {
                appState.completeServerSetup(configuration)
            }
        case nil:
            // The certificate error stays on screen, with the servers found.
            viewModel.cancelHTTPPortRequest()
            viewModel.declineInsecureFallback()
        }
    }

    private func serverRow(_ server: DiscoveredServer) -> some View {
        Button {
            Task {
                if let config = await viewModel.connect(to: server) {
                    appState.completeServerSetup(config)
                }
            }
        } label: {
            HStack(spacing: 30) {
                Image(systemName: "server.rack")
                    .font(.system(size: 32))
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(.white.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name).font(.headline.weight(.semibold))
                    Text(detail(for: server)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.connectingServerID == server.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 30)
            .frame(width: 900, alignment: .leading)
            .frame(minHeight: 132)
        }
        .buttonStyle(.card)
        .focused($focusedServer, equals: server.id)
        .accessibilityIdentifier(A11yID.TV.Onboarding.serverRow(server.id))
    }

    /// The host, and the server's Jellyfin version once the view model's
    /// background lookup has it.
    private func detail(for server: DiscoveredServer) -> String {
        guard let version = viewModel.serverVersions[server.id] else { return server.displayAddress }
        return "\(server.displayAddress) · Jellyfin \(version)"
    }

    private var addressRow: some View {
        @Bindable var viewModel = viewModel
        return HStack(spacing: 24) {
            TextField("Server Address", text: $viewModel.address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .frame(width: 560)
                .focused($addressFocused)
                .accessibilityIdentifier(A11yID.TV.Onboarding.addressField)
            Button("Connect") {
                Task {
                    if let config = await viewModel.testConnection() {
                        appState.completeServerSetup(config)
                    }
                }
            }
            .disabled(!viewModel.canSubmit || viewModel.isTesting)
        }
    }

    private var canRescan: Bool { viewModel.scanState != .scanning && viewModel.scanState != .idle }

    /// Above Enter Server Address: nothing once servers are listed and the
    /// scan is over.
    private var statusText: String? {
        switch viewModel.scanState {
        case .scanning:
            String(localized: "Still searching…")
        default:
            viewModel.discoveredServers.isEmpty ? String(localized: "No servers found.") : nil
        }
    }
}

/// The brand pane's radar. While a scan runs, rose gold pings ripple out from
/// the glyph under a turning sweep, so the screen itself says it's still
/// looking; when the scan ends the rose gold cross-fades into three still grey
/// rings, which mean "stopped". The two never show together. Decorative, so
/// hidden from accessibility. The motion stays off under Reduce Motion and under the
/// UI-test harness, whose accessibility tree a continuously redrawing view
/// keeps in motion; there the grey rings show throughout.
private struct TVScanRadar: View {
    var isScanning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the motion layer is drawn: it outlives the scan by the fade,
    /// so it fades out moving rather than freezing first.
    @State private var showsMotion = false
    @State private var motionOpacity = 0.0

    private static let size: CGFloat = 520
    private static let glyphSize: CGFloat = 190
    private static let pingPeriod = 2.4
    private static let pingCount = 3
    private static let sweepPeriod = 3.0
    private static let fade = 0.9

    private var animates: Bool {
        #if DEBUG
        if UITestHarness.freezesAmbientMotion { return false }
        #endif
        return !reduceMotion
    }

    var body: some View {
        ZStack {
            ZStack {
                ForEach(Array([0.10, 0.16, 0.24].enumerated()), id: \.offset) { index, opacity in
                    Circle()
                        .stroke(.white.opacity(opacity), lineWidth: 2)
                        .padding(CGFloat(index) * 70)
                }
            }
            .opacity(1 - motionOpacity)
            if showsMotion {
                TimelineView(.animation) { context in
                    motion(at: context.date.timeIntervalSinceReferenceDate)
                }
                .opacity(motionOpacity)
            }
            Image("DionysusGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: Self.glyphSize, height: Self.glyphSize)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
        .onAppear { update(scanning: isScanning) }
        .onChange(of: isScanning) { _, scanning in update(scanning: scanning) }
    }

    /// The sweep, and pings that grow from the glyph's edge to the outer ring
    /// while fading, staggered evenly across one period.
    private func motion(at time: TimeInterval) -> some View {
        let sweep = time.truncatingRemainder(dividingBy: Self.sweepPeriod) / Self.sweepPeriod
        let start = Self.glyphSize / Self.size
        return ZStack {
            Circle()
                // A trail over the whole circle, brightest at the leading
                // edge. A gradient over part of it would fill the rest with
                // its first colour.
                .fill(AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.72),
                        .init(color: .dionysusRoseGoldLight.opacity(0.32), location: 1)
                    ],
                    center: .center
                ))
                .rotationEffect(.degrees(sweep * 360))
            ForEach(0..<Self.pingCount, id: \.self) { index in
                let offset = Double(index) / Double(Self.pingCount)
                let progress = (time / Self.pingPeriod + offset).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(Color.dionysusRoseGoldLight.opacity(0.55 * (1 - progress)), lineWidth: 3)
                    .scaleEffect(start + (1 - start) * progress)
            }
        }
    }

    private func update(scanning: Bool) {
        guard animates else { return }
        if scanning {
            showsMotion = true
            withAnimation(.easeIn(duration: 0.4)) { motionOpacity = 1 }
        } else if showsMotion {
            withAnimation(.easeOut(duration: Self.fade)) {
                motionOpacity = 0
            } completion: {
                // A scan restarted during the fade keeps its motion.
                if !isScanning { showsMotion = false }
            }
        }
    }
}
