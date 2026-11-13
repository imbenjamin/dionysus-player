import SwiftUI

/// The signed-in app, or everything before it — splash, welcome, server setup
/// and sign-in, which `OnboardingFlowView` presents as one continuous scene.
struct RootView: View {
    @Environment(AppState.self) private var appState
    /// A `dionysus://` link (#406), held until the session can take it,
    /// through sign-in if need be.
    @State private var pendingLink: PendingDeepLink?
    /// A link that couldn't be read arrived while the session restored (a
    /// cold launch from it): it's refused out loud once restoring ends.
    @State private var refusesUnreadableLinkAfterRestore = false
    /// A `server?url=` link's address (DEBUG builds only), for server setup
    /// to fill in; cleared once setup is left.
    @State private var linkedServerAddress: LinkedServerAddress?

    private var isInMainApp: Bool {
        !appState.isRestoringSession && appState.phase == .main
    }

    var body: some View {
        Group {
            if isInMainApp {
                MainTabView()
            } else {
                OnboardingFlowView(linkedServerAddress: linkedServerAddress)
            }
        }
        .animation(.default, value: isInMainApp)
        .onOpenURL(perform: receive)
        .onChange(of: appState.isRestoringSession) { _, isRestoring in
            guard !isRestoring, refusesUnreadableLinkAfterRestore else { return }
            refusesUnreadableLinkAfterRestore = false
            if isInMainApp { ToastCenter.shared.post(.notice(DeepLink.cantOpenMessage)) }
        }
        // Server setup is before the main app, so the root applies it.
        .onChange(of: appliedLink, initial: true) { _, link in
            guard case .serverSetup(let address)? = link?.destination else { return }
            linkedServerAddress = LinkedServerAddress(address: address)
            pendingLink = nil
        }
        .onChange(of: appState.phase) { _, phase in
            if phase != .serverSetup { linkedServerAddress = nil }
        }
        .environment(\.pendingDeepLink, appliedLink)
        .environment(\.deepLinkApplied, { pendingLink = nil })
    }

    /// A link replaces any still pending; one that can't be read is refused,
    /// out loud only in the signed-in app, where toasts show (after the
    /// restore, for a cold launch from it).
    private func receive(_ url: URL) {
        guard let link = DeepLink(url: url) else {
            if appState.isRestoringSession {
                refusesUnreadableLinkAfterRestore = true
            } else if isInMainApp {
                ToastCenter.shared.post(.notice(DeepLink.cantOpenMessage))
            }
            return
        }
        pendingLink = PendingDeepLink(
            link: link, receivedAt: Date(), serverIDAtArrival: appState.sessionStore.serverConfiguration?.id
        )
    }

    /// The pending link once the router says it can go; a refused one is
    /// cleared here (saying why, where it says anything), a waiting one is
    /// kept until the session has restored or someone has signed in.
    private var appliedLink: DeepLink? {
        guard let pendingLink else { return nil }
        switch DeepLinkRouter.decide(
            pendingLink,
            now: Date(),
            isRestoringSession: appState.isRestoringSession,
            isSignedIn: appState.phase == .main,
            serverID: appState.sessionStore.serverConfiguration?.id,
            userID: appState.signedInUserID
        ) {
        case .wait, .waitForSignIn: return nil
        case .refuse(let refusal):
            Task { @MainActor in
                self.pendingLink = nil
                // Toasts show only in the signed-in app.
                if let message = refusal.message, isInMainApp { ToastCenter.shared.post(.notice(message)) }
            }
            return nil
        case .apply: return pendingLink.link
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
