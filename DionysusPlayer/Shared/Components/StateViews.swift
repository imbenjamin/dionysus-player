import SwiftUI

/// Generic centered spinner for a screen/section that's loading.
struct LoadingView: View {
    var body: some View {
        ProgressView()
            .tint(.dionysusPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Generic centered error state with an optional retry action.
struct ErrorStateView: View {
    var message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
