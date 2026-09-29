import SwiftUI

/// Quick Connect on the shared `QuickConnectViewModel`: a code to approve on
/// another signed-in device. The copy names no menu path, because where Quick
/// Connect lives differs between Jellyfin clients.
struct TVQuickConnectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: QuickConnectViewModel
    let serverName: String

    init(client: JellyfinAPIClient, serverName: String) {
        _viewModel = State(initialValue: QuickConnectViewModel(client: client))
        self.serverName = serverName
    }

    var body: some View {
        TVBrandBackground {
            VStack(spacing: 40) {
                Text("Sign In with Quick Connect").font(.title2.bold())
                switch viewModel.state {
                case .waiting(let code):
                    Text(code)
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("On a device already signed in to \(serverName), open Quick Connect and enter this code.")
                        .foregroundStyle(.secondary)
                case .expired:
                    Text("The code expired.")
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                default:
                    ProgressView()
                }
                Button("Cancel") { dismiss() }
            }
            .padding(80)
        }
        .task {
            await viewModel.run { secret in
                _ = try await appState.signInWithQuickConnect(secret: secret)
            }
        }
    }
}
