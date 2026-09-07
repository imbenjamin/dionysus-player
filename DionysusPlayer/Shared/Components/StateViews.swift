import SwiftUI

/// Generic centered spinner for a screen/section that's loading.
struct LoadingView: View {
    var body: some View {
        ProgressView()
            .tint(.dionysusPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(A11yID.State.loading)
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
    /// Defaults to the generic error triangle — every real-error call site
    /// leaves this unset. A caller using this view for an *empty* state
    /// rather than a failure (e.g. `DownloadsView`'s "no downloads yet")
    /// can pass something more on-topic instead.
    var icon: String = "exclamationmark.triangle"
    /// A second, non-destructive action alongside `retry` — e.g. a Close
    /// button for a failure `retry` can't plausibly fix (the Player's
    /// `.refused` playback failures, where it's shown with `retry: nil`).
    /// `nil` (every existing call site before this was added) omits it
    /// entirely — mirrors `OfflineStateView`'s existing `secondaryAction`
    /// in this same file rather than inventing a new shape.
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(A11yID.State.retryButton)
            }
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // On the container, not the message `Text`: a test asserting "this
        // screen failed" wants the state to exist, and the message itself
        // is localized copy that changes.
        .accessibilityIdentifier(A11yID.State.error)
    }
}

/// Generic "can't reach your Jellyfin server" state — the screen any
/// connectivity-failure event in the app routes to, driven by
/// `ConnectivityMonitor.shared.isOffline`. `retry` should reload whatever
/// the caller was already trying to show (not restart some unrelated
/// flow); `secondaryAction`, when provided, offers an escape hatch to
/// something else reachable without a live server — `PlayerView` uses it
/// for a "Close" button back out of a title that failed to start offline.
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
                .accessibilityIdentifier(A11yID.State.retryButton)
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11yID.State.offline)
    }
}
