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
    /// Default `true` — matches `HeroRailView`'s own default for this key,
    /// same pre-first-launch-visit reasoning as `hero3DDepthEnabled` above.
    /// VoiceOver still forces manual navigation regardless of this value —
    /// see `HeroRailView.manualCarouselModeEnabled`'s own doc comment; this
    /// toggle only controls the *preference*, not VoiceOver's own
    /// enforcement of the same behavior.
    @AppStorage(heroAutoCarouselEnabledStorageKey) private var autoCarouselEnabled = true
    /// Default `.seconds30` — matches `NextUpPreferenceStore.countdownSeconds`'s
    /// own fallback for the same "both sides declare the same default"
    /// reason as `hero3DDepthEnabled` above.
    @AppStorage(nextUpCountdownStorageKey) private var nextUpCountdown: NextUpCountdownPreference = .seconds30
    /// Default `.allowTranscoding` — matches `StreamPreferenceStore
    /// .decisionMode`'s own fallback for the same "both sides declare the
    /// same default" reason as `hero3DDepthEnabled` above.
    @AppStorage(streamDecisionModeStorageKey) private var streamDecisionMode: StreamDecisionMode = .allowTranscoding
    /// Default `.unlimited` — matches `StreamPreferenceStore
    /// .streamingMaxBitrate`'s own fallback, same reasoning.
    @AppStorage(streamingMaxBitrateStorageKey) private var streamingMaxBitrate: StreamingMaxBitrate = .unlimited
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSignOutConfirmation = false
    @State private var showChangeServerConfirmation = false

    /// Recomputed on every `body` evaluation — a plain `FileManager`
    /// directory scan (`DownloadFileStore.totalSizeOnDisk()`), not cached
    /// or reactively tied to `DownloadManager`. Fine for a settings row
    /// visited occasionally, and simpler than wiring a dedicated
    /// `@Observable` size tracker just for this one label.
    private var downloadsStorageUsedText: String {
        ByteCountFormatter.string(fromByteCount: DownloadFileStore.totalSizeOnDisk(), countStyle: .file)
    }

    /// See `DownloadedInfoMetadataRow.spokenFileSize(_:)` — identical copy,
    /// not shared, for the same reason that one documents. Parses an
    /// already-formatted `ByteCountFormatter` string rather than
    /// reimplementing its unit-selection/rounding, so the two can never
    /// drift out of agreement.
    private static func spokenFileSize(_ text: String) -> String {
        guard let spaceIndex = text.lastIndex(of: " ") else { return text }
        let number = text[..<spaceIndex]
        let unit = text[text.index(after: spaceIndex)...]
        let spokenUnit: String?
        switch unit {
        case "byte", "bytes": spokenUnit = String(localized: "bytes")
        case "KB": spokenUnit = String(localized: "kilobytes")
        case "MB": spokenUnit = String(localized: "megabytes")
        case "GB": spokenUnit = String(localized: "gigabytes")
        case "TB": spokenUnit = String(localized: "terabytes")
        case "PB": spokenUnit = String(localized: "petabytes")
        default: spokenUnit = nil
        }
        guard let spokenUnit else { return text }
        return "\(number) \(spokenUnit)"
    }

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
                Toggle("Auto Carousel on Home", isOn: $autoCarouselEnabled)
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
                Picker("Next Episode Countdown", selection: $nextUpCountdown) {
                    ForEach(NextUpCountdownPreference.allCases) { preference in
                        Text(preference.displayName)
                            .accessibilityLabel(preference.accessibilityLabel)
                            .tag(preference)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("How long before the end of an episode to countdown the next episode, if end credits are not detected.")
            }

            // No header of its own — reads as a continuation of "Playback"
            // just above, same as multiple footer-only sections under one
            // header elsewhere in Settings.app. Kept apart from the
            // countdown section above (rather than one section/footer
            // covering all three controls) so each footer can stay scoped
            // to the control(s) it actually explains — a single combined
            // block covering three unrelated settings read as a wall of
            // text nobody could tell which control it was about
            // (confirmed live, 2026-08-28).
            Section {
                Picker("Streaming", selection: $streamDecisionMode) {
                    ForEach(StreamDecisionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if streamDecisionMode == .allowTranscoding {
                    Picker("Max Streaming Bitrate", selection: $streamingMaxBitrate) {
                        ForEach(StreamingMaxBitrate.allCases) { tier in
                            Text(tier.displayName)
                                .accessibilityLabel(tier.accessibilityLabel)
                                .tag(tier)
                        }
                    }
                }
            } footer: {
                // Switches with the picker above rather than trying to
                // explain both modes unconditionally — only ever one
                // is relevant to what's currently selected.
                if streamDecisionMode == .allowTranscoding {
                    Text("Allow Transcoding asks the server to decide, transcoding when necessary — including to keep the stream under the Max Streaming Bitrate cap, even for a file that could otherwise play untouched.")
                } else {
                    Text("Direct Play Always sends the original file untouched — best quality, but may fail if your device or network can't handle it.")
                }
            }

            Section {
                NavigationLink {
                    DownloadsSettingsView()
                } label: {
                    LabeledContent("Downloads", value: downloadsStorageUsedText)
                        // `LabeledContent` already folds its title and
                        // value into one combined accessibility label by
                        // default (not a separate label+value pair) —
                        // `.accessibilityValue` alone just appended a
                        // second, spoken-out reading on top of that
                        // existing one ("Downloads. 2.44 GB. 2.44
                        // gigabytes."), rather than replacing it.
                        // `.accessibilityElement(children: .ignore)` first
                        // suppresses that default combine so the explicit
                        // label below is the only thing read.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "Downloads, \(Self.spokenFileSize(downloadsStorageUsedText))"))
                }
            }

            Section {
                NavigationLink("License") {
                    LicenseView()
                }
                NavigationLink("Privacy Policy") {
                    PrivacyPolicyView()
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    showSignOutConfirmation = true
                }
                Button("Change Server", role: .destructive) {
                    showChangeServerConfirmation = true
                }
            } footer: {
                Text("Change Server also signs you out and forgets this server, returning to first-time setup.")
            }

            // Page-wide footer (not tied to the section above it): which
            // branch/commit this build actually came from, plus a link to
            // the GitHub repo just above it.
            Section {
            } footer: {
                // Tight spacing here because the Link's own frame (below)
                // already pads the tappable area out to a 44pt touch
                // target — that padding does double duty as the visual gap
                // to the version text, so stacking more on top of it would
                // separate the two too far.
                VStack(spacing: 0) {
                    Link(destination: URL(string: "https://github.com/imbenjamin/dionysus-player")!) {
                        Image("GitHubGlyph")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            // Glyph itself reads better at 28pt, but pad the
                            // tappable area out to HIG's 44pt minimum touch
                            // target rather than sizing the visible mark to
                            // match — matching visually would look oversized
                            // next to the caption-sized version text below.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    // Without this, VoiceOver falls back to the image
                    // asset's own name ("Github Glyph") rather than what
                    // the link actually does.
                    .accessibilityLabel(String(localized: "Open Dionysus Player on GitHub"))
                    Text(AppVersionInfo.footerText())
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Profile & Settings")
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
