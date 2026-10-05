import SwiftUI

/// Approves another device's Quick Connect code from this Apple TV, on the
/// shared `QuickConnectApprovalViewModel`. The code is typed with the system
/// keyboard (and so the Continuity Keyboard on a nearby iPhone).
struct TVQuickConnectApprovalView: View {
    @State var viewModel: QuickConnectApprovalViewModel
    @State private var text = ""
    @FocusState private var focus: String?

    var body: some View {
        VStack(spacing: 30) {
            // iOS's words (`QuickConnectApprovalView`).
            Text("Quick Connect").font(.title2.bold())
            Text("On the device you're signing in on, choose Quick Connect to get a code, then enter it here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            TextField("Code", text: $text)
                .keyboardType(.numberPad)
                .frame(width: 500)
                .focused($focus, equals: A11yID.TV.Profile.quickConnectCode)
                .accessibilityIdentifier(A11yID.TV.Profile.quickConnectCode)
                .accessibilityLabel("Quick Connect code")
                .onChange(of: text) { _, raw in
                    viewModel.setCode(raw)
                    if text != viewModel.code { text = viewModel.code }
                }
            Button {
                Task { await viewModel.authorize() }
            } label: {
                Text("Authorize").frame(width: 500)
            }
            .disabled(!viewModel.canSubmit)
            .focused($focus, equals: A11yID.TV.Profile.quickConnectAuthorize)
            .accessibilityIdentifier(A11yID.TV.Profile.quickConnectAuthorize)
            message
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900, minHeight: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focus, A11yID.TV.Profile.quickConnectCode)
    }

    @ViewBuilder
    private var message: some View {
        switch viewModel.state {
        case .approved:
            Text("The other device is now signed in as \(viewModel.userName). It can take a few seconds to finish.")
                .accessibilityIdentifier(A11yID.TV.Profile.quickConnectMessage)
        case .failed(let message):
            Text(verbatim: message)
                .accessibilityIdentifier(A11yID.TV.Profile.quickConnectMessage)
        case .submitting:
            ProgressView()
        case .entering:
            Color.clear
        }
    }
}
