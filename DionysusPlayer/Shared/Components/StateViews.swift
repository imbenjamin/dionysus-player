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
///
/// `message` is a plain `String`, not `LocalizedStringKey` — most call
/// sites pass a `ViewModel`'s already-`String(localized:)`-wrapped error
/// text (business logic constructs those, so it can't use
/// `LocalizedStringKey`, which only exists as a SwiftUI/string-literal
/// convenience), so this stays a `String` to match rather than fighting
/// that at the view boundary. The handful of call sites that pass a plain
/// literal here (e.g. `ErrorStateView(message: "Nothing here yet.")`) wrap
/// it in `String(localized:)` themselves for the same reason `Text(message)`
/// below needs an already-resolved `String`, not a raw literal, to display
/// it correctly.
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

/// Generic "can't reach your Jellyfin server" state — the screen any
/// connectivity-failure event in the app routes to, driven by
/// `ConnectivityMonitor.shared.isOffline`. `retry` should reload whatever
/// the caller was already trying to show (not restart some unrelated
/// flow); `secondaryAction`, when provided, offers an escape hatch to
/// server settings for contexts where the normal tab bar/Profile screen
/// isn't reachable yet (e.g. before sign-in completes).
struct OfflineStateView: View {
    var retry: () -> Void
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("You're Offline")
                .font(.headline)
            Text("Can't reach your Jellyfin server. If it's on your local network, make sure you're connected to the same Wi-Fi.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
