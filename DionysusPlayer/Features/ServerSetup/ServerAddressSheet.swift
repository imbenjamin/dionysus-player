import SwiftUI

/// Typing a server address: the field, the HTTPS toggle and the hint, moved
/// off `ServerSetupView` so the main screen stops asking everyone to know an
/// IP address.
///
/// Hand-built rather than a `Form` in a `NavigationStack`, so on iPad it can
/// be a form sheet exactly as tall as its content — detents don't apply
/// there, and a default form sheet around three rows was mostly empty.
struct ServerAddressSheet: View {
    @Bindable var viewModel: ServerSetupViewModel
    let onConnected: (ServerConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.onboardingLayout) private var layout
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("Cancel", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .modifier(OnboardingCircleButtonStyle(isProminent: false))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(A11yID.ServerSetup.addressSheetCancelButton)
                Spacer()
                Text("Server Address")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Connect", systemImage: "checkmark") {
                    Task { await connect() }
                }
                .labelStyle(.iconOnly)
                .modifier(OnboardingCircleButtonStyle(isProminent: true))
                .disabled(!viewModel.canSubmit)
                .keyboardShortcut(.defaultAction)
                .overlay {
                    if viewModel.isTesting {
                        ProgressView()
                            .accessibilityHidden(true)
                    }
                }
                // The name stays put while the spinner shows; the state is
                // the value.
                .accessibilityValue(viewModel.isTesting ? String(localized: "Connecting") : "")
                .accessibilityIdentifier(A11yID.ServerSetup.connectButton)
            }

            VStack(spacing: 0) {
                TextField("Server Address", text: $viewModel.address, prompt: Text(verbatim: "192.168.1.50:8096"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isAddressFocused)
                    .frame(minHeight: 50)
                    .onSubmit { Task { await connect() } }
                    .onChange(of: viewModel.address) { _, newAddress in
                        viewModel.syncHTTPSToggle(withAddress: newAddress)
                    }
                    .accessibilityIdentifier(A11yID.ServerSetup.addressField)
                Divider()
                Toggle("Use HTTPS", isOn: $viewModel.useHTTPS)
                    .frame(minHeight: 50)
                    .accessibilityIdentifier(A11yID.ServerSetup.httpsToggle)
            }
            .padding(.horizontal, 16)
            .background(.fill.tertiary, in: .rect(cornerRadius: 18))

            Text("Enter your server's local IP and port, a domain name, or a full URL.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    // See `Color.dionysusMagentaHighContrast` for the measured
                    // contrast of this colour, and why the dynamic one.
                    .foregroundStyle(Color.dionysusPrimary)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier(A11yID.ServerSetup.errorMessage)
            }
        }
        .padding(24)
        .modifier(AddressSheetSizing(isRegular: layout.isRegular))
        // A sheet doesn't inherit `OnboardingFlowView`'s scoped appearance.
        .preferredColorScheme(.dark)
        .onAppear { isAddressFocused = true }
    }

    private func connect() async {
        guard viewModel.canSubmit, let configuration = await viewModel.testConnection() else { return }
        onConnected(configuration)
    }
}

/// Half height on a phone; on iPad a form sheet exactly as tall as its
/// content.
private struct AddressSheetSizing: ViewModifier {
    let isRegular: Bool

    func body(content: Content) -> some View {
        if isRegular {
            content
                .frame(width: 520)
                .fixedSize(horizontal: false, vertical: true)
                .presentationSizing(.fitted)
        } else {
            content
                .frame(maxHeight: .infinity, alignment: .top)
                .presentationDetents([.medium])
        }
    }
}
