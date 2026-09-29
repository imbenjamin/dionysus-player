import SwiftUI

/// Find Your Server, on the shared `ServerSetupViewModel`. Scanning starts on
/// arrival; the first server found takes default focus, so one Select connects.
/// Functional only: the prototype's visual design lands in Milestone 2.
struct TVServerSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var focusedServer: DiscoveredServer.ID?
    /// Whether the person has moved focus themselves. Discovery answers after
    /// the screen's first focus pass, so `defaultFocus` alone never reaches a
    /// server; the first one found takes focus unless they've moved already.
    @State private var userMovedFocus = false

    var body: some View {
        TVBrandBackground {
            HStack(spacing: 80) {
                Image("DionysusGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220)
                    .frame(maxWidth: 640)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 30) {
                    Text("Find Your Server")
                        .font(.title2.bold())
                        .accessibilityIdentifier(A11yID.TV.Onboarding.findServerTitle)
                    Text(statusText).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.discoveredServers) { server in
                            serverRow(server)
                        }
                    }
                    .defaultFocus($focusedServer, viewModel.discoveredServers.first?.id)
                    .onChange(of: viewModel.discoveredServers.first?.id) { _, firstID in
                        guard !userMovedFocus, focusedServer == nil, let firstID else { return }
                        focusedServer = firstID
                    }
                    addressRow
                    if let error = viewModel.errorMessage {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(80)
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
            HStack {
                Image(systemName: "server.rack").accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(server.name).font(.headline)
                    Text(server.address.absoluteString).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.connectingServerID == server.id { ProgressView() }
            }
            .frame(width: 820, alignment: .leading)
        }
        .focused($focusedServer, equals: server.id)
        .accessibilityIdentifier(A11yID.TV.Onboarding.serverRow(server.id))
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

    private var statusText: String {
        switch viewModel.scanState {
        case .scanning:
            String(localized: "Looking for Jellyfin servers on this network…")
        default:
            viewModel.discoveredServers.isEmpty
                ? String(localized: "No servers found. Enter an address below.")
                : String(localized: "Servers on this network")
        }
    }
}
