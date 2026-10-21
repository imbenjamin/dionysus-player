import SwiftUI

/// Asks before an action that's hard to undo, as a full-screen cover: Sign
/// Out and Change Server on Profile, deleting from a detail page's More
/// Actions, and adding a whole show or season to a playlist. Cancel takes
/// focus, so a stray Select changes nothing (Benjamin, 2026-10-05).
///
/// Takes `Text`, so a caller passes a localized literal (`Text("Sign Out")`)
/// or copy built elsewhere (`Text(verbatim:)` over a `String(localized:)`).
struct TVConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let title: Text
    let message: Text
    let action: Text
    let actionIdentifier: String
    /// A plain button when the action destroys nothing ("Add 6 Episodes").
    var isDestructive = true
    let onConfirm: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            title.font(.title2.bold())
            message
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            VStack(spacing: 24) {
                Button(role: isDestructive ? .destructive : nil) {
                    dismiss()
                    onConfirm()
                } label: {
                    action.frame(width: 500)
                }
                .accessibilityIdentifier(actionIdentifier)
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel").frame(width: 500)
                }
                .focused($cancelFocused)
                .accessibilityIdentifier(A11yID.TV.confirmationCancel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque enough that the page's own text and buttons don't read
        // through as part of the question.
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($cancelFocused, true)
    }
}
