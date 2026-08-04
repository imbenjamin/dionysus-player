import SwiftUI

/// One-time setup screen where the user points the app at their Jellyfin
/// server (LAN IP:port, domain name, or full URL).
struct ServerSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var addressFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    Text("Server Address")
                        .font(.headline)

                    TextField("192.168.1.50:8096", text: $viewModel.address)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($addressFieldFocused)
                        .onSubmit { Task { await connect() } }

                    Toggle("Use HTTPS", isOn: $viewModel.useHTTPS)

                    Text("Enter your server's local IP and port, a domain name, or a full URL.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.dionysusMagenta)
                }

                Spacer()

                Button {
                    Task { await connect() }
                } label: {
                    if viewModel.isTesting {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canSubmit)
            }
            .padding(24)
            .navigationTitle("Connect to Server")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { addressFieldFocused = true }
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

    private func connect() async {
        guard let configuration = await viewModel.testConnection() else { return }
        appState.completeServerSetup(configuration)
    }
}

#Preview {
    ServerSetupView()
        .environment(AppState())
}
