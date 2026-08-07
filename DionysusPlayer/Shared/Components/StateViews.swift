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
