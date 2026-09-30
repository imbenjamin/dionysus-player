import SwiftUI

/// Find Your Server, on the shared `ServerSetupViewModel`, in the prototype's
/// layout: a scanning radar on the left, the servers found on the right.
/// Scanning starts on arrival; the first server found takes default focus, so
/// one Select connects. Typing an address is the secondary route, behind
/// Enter Server Address.
struct TVServerSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var focusedServer: DiscoveredServer.ID?
    @FocusState private var addressFocused: Bool
    /// Whether the person has moved focus themselves. Discovery answers after
    /// the screen's first focus pass, so `defaultFocus` alone never reaches a
    /// server; the first one found takes focus unless they've moved already.
    @State private var userMovedFocus = false
    @State private var showsAddressEntry = false

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
                    HStack(spacing: 30) {
                        Button {
                            showsAddressEntry = true
                        } label: {
                            Label("Enter Server Address", systemImage: "keyboard")
                        }
                        .accessibilityIdentifier(A11yID.TV.Onboarding.enterAddress)
                        if let statusText {
                            Text(statusText).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if showsAddressEntry {
                        addressRow
                    }
                    if let error = viewModel.errorMessage {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
            }
        }
        .onAppear { viewModel.startScanOnArrival() }
        .onMoveCommand { _ in userMovedFocus = true }
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
                .onAppear { addressFocused = true }
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

    /// Beside Enter Server Address: nothing once servers are listed and the
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

/// The brand pane's radar. While a scan runs, gold pings ripple out from the
/// glyph under a turning sweep, so the screen itself says it's still looking;
/// when the scan ends the gold cross-fades into three still grey rings, which
/// mean "stopped". The two never show together. Decorative, so hidden from
/// accessibility. The motion stays off under Reduce Motion and under the
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

    private var animates: Bool { !reduceMotion && !UITestHarness.freezesAmbientMotion }

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
                        .init(color: .dionysusGold.opacity(0.32), location: 1)
                    ],
                    center: .center
                ))
                .rotationEffect(.degrees(sweep * 360))
            ForEach(0..<Self.pingCount, id: \.self) { index in
                let offset = Double(index) / Double(Self.pingCount)
                let progress = (time / Self.pingPeriod + offset).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(Color.dionysusGold.opacity(0.55 * (1 - progress)), lineWidth: 3)
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
