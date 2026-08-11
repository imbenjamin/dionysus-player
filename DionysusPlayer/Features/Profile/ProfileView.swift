import SwiftUI

/// Account/server settings. For now: show who's signed in and where, plus
/// sign out / change server.
struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(themePreferenceStorageKey) private var themePreference: ThemePreference = .system
    /// Default `true` — matches `HeroHeaderView`'s own default for this key
    /// before anyone's ever visited this screen to change it (an
    /// `@AppStorage` property's initial value only applies locally; it
    /// doesn't write anything to `UserDefaults` until this Toggle is
    /// actually flipped, so both call sites declaring the same default is
    /// what keeps them in agreement pre-first-launch-visit).
    @AppStorage(hero3DDepthEnabledStorageKey) private var hero3DDepthEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSignOutConfirmation = false
    @State private var showChangeServerConfirmation = false

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Username", value: appState.currentUser?.name ?? appState.sessionStore.credentials?.username ?? "\u{2014}")
                LabeledContent("Server", value: appState.sessionStore.serverConfiguration?.name ?? "\u{2014}")
                LabeledContent("Address", value: appState.sessionStore.serverConfiguration?.baseURL.absoluteString ?? "\u{2014}")
            }

            Section("Appearance") {
                Picker("Theme", selection: $themePreference) {
                    ForEach(ThemePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                Toggle(isOn: $hero3DDepthEnabled) {
                    HStack {
                        Text("3D Depth Effects")
                        // `DeviceTiltObserver.shared` (not something local
                        // to this view) is what actually does the work this
                        // spinner is standing in for — see its own
                        // `isApplyingChange` doc comment for why this can
                        // take a perceptible moment even off the main
                        // thread: CoreMotion's stop() briefly blocked the
                        // *entire app* before that existed, which is what
                        // this spinner is here to explain rather than leave
                        // silent.
                        if DeviceTiltObserver.shared.isApplyingChange {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirmation = true
                }
            }

            Section {
                Button("Change Server", role: .destructive) {
                    showChangeServerConfirmation = true
                }
            } footer: {
                Text("This signs you out and forgets this server, returning to first-time setup.")
            }

            // Page-wide footer (not tied to the section above it): which
            // branch/commit this build actually came from.
            Section {
            } footer: {
                Text(AppVersionInfo.footerText())
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Profile")
        // Drives `DeviceTiltObserver.shared` directly from the toggle that
        // actually triggers it, rather than relying solely on whichever
        // `HeroHeaderView` (if any) happens to still be mounted in some
        // other tab's nav stack — that indirection is what let a previous
        // fix attempt go untested: if no detail page was live, its
        // `.onChange` never ran, so `stop()` was never called and this
        // screen's own spinner never had anything to show. `HeroHeaderView`
        // keeps its own `.onChange` too (idempotent — see
        // `DeviceTiltObserver.start()/stop()`'s own guard clauses), for the
        // case where a detail page *is* on screen; the two calls just no-op
        // against each other's work.
        .onChange(of: hero3DDepthEnabled) { _, isEnabled in
            Task {
                if isEnabled, !reduceMotion {
                    await DeviceTiltObserver.shared.start()
                } else {
                    await DeviceTiltObserver.shared.stop()
                }
            }
        }
        .confirmationDialog(
            "Sign out of \(appState.currentUser?.name ?? "your account")?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) { appState.signOut() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Change server?",
            isPresented: $showChangeServerConfirmation,
            titleVisibility: .visible
        ) {
            Button("Change Server", role: .destructive) { appState.changeServer() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environment(AppState())
}
