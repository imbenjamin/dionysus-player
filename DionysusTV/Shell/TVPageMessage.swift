import SwiftUI

/// A page with nothing to show but a reason and one way forward: a load that
/// failed (Retry), a grid filtered to nothing (Reset Filters). Its button
/// takes focus, so Menu and the rail still work: with focus nowhere, tvOS
/// delivers Menu to nothing.
struct TVPageMessage: View {
    let title: String
    var message: String?
    let actionTitle: LocalizedStringKey
    let actionIdentifier: String
    let action: () -> Void
    @FocusState private var focused: String?
    @State private var remembered: String?

    var body: some View {
        VStack(spacing: 30) {
            Text(verbatim: title).font(.title2.bold())
            if let message {
                Text(verbatim: message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
            }
            Button(action: action) { Text(actionTitle).frame(width: 400) }
                .focused($focused, equals: actionIdentifier)
                .accessibilityIdentifier(actionIdentifier)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, TVShellMetrics.contentInset)
        .tvClaimsFocus($focused, ids: [actionIdentifier], remembered: $remembered)
    }
}
