import SwiftUI

/// Which settings pane the iPad sidebar has selected.
///
/// Only used by `ProfileView`'s split layout — the compact layout shows
/// every one of these as a `Section` of one long list instead, so it has
/// no need for a selection type.
private enum ProfileSettingsPane: Identifiable, Hashable {
    /// Selected by the contact card at the top of the sidebar, not by a
    /// labelled row — which is why this deliberately isn't in `listed`
    /// below, and why the type is no longer `CaseIterable` (an
    /// `allCases` that silently included `.account` would put a
    /// duplicate "Account" row underneath the card).
    case account
    case appearance
    case playback
    case downloads
    case about

    var id: Self { self }

    /// The panes shown as labelled sidebar rows, in order. `.account` is
    /// reachable only through the contact card above them.
    static let listed: [ProfileSettingsPane] = [.appearance, .playback, .downloads, .about]

    /// `String(localized:)` rather than a bare literal because these are
    /// consumed by `Label(_:systemImage:)`'s `String` overload, which
    /// isn't auto-extracted into the String Catalog — see CLAUDE.md's
    /// Localization section. Every one of these keys already exists in
    /// the catalog from the section headers/navigation titles they
    /// duplicate.
    var title: String {
        switch self {
        case .account: return String(localized: "Account")
        case .appearance: return String(localized: "Appearance")
        case .playback: return String(localized: "Playback")
        case .downloads: return String(localized: "Downloads")
        case .about: return String(localized: "About")
        }
    }

    /// Unused for `.account` — the contact card shows the user's avatar
    /// instead of a symbol — but kept total so `listed`'s `ForEach` needs
    /// no unwrapping.
    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .appearance: return "paintbrush"
        case .playback: return "play.rectangle"
        case .downloads: return "arrow.down.circle"
        case .about: return "info.circle"
        }
    }
}

/// Account/server settings. For now: show who's signed in and where, plus
/// sign out / change server.
///
/// ## Two layouts
///
/// On iPhone this is one scrolling `List` of sections — `compactLayout`,
/// unchanged from before the iPad work.
///
/// On iPad it's a `NavigationSplitView`: the sections become sidebar
/// items and their contents move into the detail column, mirroring
/// Settings.app. This isn't cosmetic. Measured on an 11-inch iPad in
/// landscape (1180x820pt), the single-column layout ran its content to
/// y=1044 on an 820pt-tall screen — the whole About section and the
/// version footer sat below the fold while 40% of the screen's *width*
/// was empty. It also stretched every row to 1140pt, putting ~1,060pt of
/// horizontal scan between a label like "Theme" and its own value.
///
/// The sidebar additionally flattens a level of depth: "Downloads" was a
/// push from this screen, and is now a sidebar destination in its own
/// right, so `DownloadsSettingsView`'s own "Advanced" push is the first
/// push on iPad rather than the second.
///
/// This view owns its own navigation container (rather than
/// `MainTabView` wrapping it in a `NavigationStack` the way the other
/// three tabs are) precisely because that container differs per layout —
/// a `NavigationSplitView` nested inside a `NavigationStack` is not a
/// supported arrangement.
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
    /// Default `true` — matches `PlayerControlsOverlay`'s own read of this
    /// key, same "both sides declare the same default" reason as
    /// `nextUpCountdown` above. See `chaptersInScrubberEnabledDefault`'s doc
    /// comment (`PlayerControlsOverlay.swift`) for what this does and
    /// doesn't gate.
    @AppStorage(chaptersInScrubberEnabledStorageKey) private var isChaptersInScrubberEnabled = chaptersInScrubberEnabledDefault
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAccountDetails = false
    @State private var avatarImageURL: URL?

    /// Non-optional default so the detail column never opens empty —
    /// Settings.app behaves the same way, landing on a real pane rather
    /// than a "select something" placeholder. Still declared `Optional`
    /// because that's what `List(selection:)` binds to.
    @State private var selectedPane: ProfileSettingsPane? = .appearance

    /// See `SettingsLayout`'s top-of-file comment for why this ANDs both
    /// size classes rather than testing width alone the way the
    /// Home/Search/Downloads grids do.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

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

    /// Fetches the signed-in user's avatar URL via a `client.makeImageURLBuilder()`
    /// actor hop — same pattern `MainTabView.loadProfileTabIcon()` uses for
    /// the tab-bar icon, just handed to `AsyncRemoteImage` here instead of a
    /// hand-rolled `UIGraphicsImageRenderer` render, since this avatar is
    /// large enough to want the same retry/placeholder/shimmer treatment as
    /// every other image in the app.
    private func loadAvatarImageURL() async {
        guard let user = appState.currentUser, let tag = user.primaryImageTag,
              let client = appState.apiClient else {
            avatarImageURL = nil
            return
        }
        let builder = await client.makeImageURLBuilder()
        avatarImageURL = builder.userImageURL(userID: user.id, tag: tag, maxWidth: 240)
    }

    private var accountDisplayName: String {
        appState.currentUser?.name ?? appState.sessionStore.credentials?.username ?? "\u{2014}"
    }

    private var accountServerName: String {
        appState.sessionStore.serverConfiguration?.name ?? "\u{2014}"
    }

    var body: some View {
        Group {
            if usesSplitLayout {
                splitLayout
            } else {
                compactLayout
            }
        }
        .task(id: appState.currentUser?.id) { await loadAvatarImageURL() }
        .sheet(isPresented: $showAccountDetails) {
            AccountDetailsSheet()
        }
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
    }

    // MARK: Layouts

    /// iPhone (and any non-iPad regular-width container — see
    /// `usesSplitLayout`). One list, every section inline.
    private var compactLayout: some View {
        NavigationStack {
            List {
                Section { accountCard }

                Section("Appearance") { appearanceRows }

                Section {
                    playbackRows
                } header: {
                    Text("Playback")
                } footer: {
                    playbackFooter
                }

                Section { downloadsRow }

                Section("About") { aboutRows }

                // Page-wide footer (not tied to the section above it):
                // which branch/commit this build actually came from, plus
                // a link to the GitHub repo just above it.
                Section {
                } footer: {
                    versionFooter
                }
            }
            .navigationTitle("Profile & Settings")
            .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
        }
    }

    /// iPad. Sidebar of panes + detail column, mirroring Settings.app.
    ///
    /// The sidebar is pinned open: `.constant(.all)` leaves the system no
    /// writable binding to collapse it through, and `.toolbar(removing:)`
    /// takes away the show/hide button that would otherwise sit in the
    /// sidebar's own toolbar. This is a settings screen with four fixed
    /// destinations — there's nothing to gain from hiding the only
    /// navigation it has, and a collapsed sidebar would leave the detail
    /// pane with no way back to its siblings.
    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            // `.id(pane)` rebuilds the stack when the selection changes,
            // so switching panes can never leave a pushed screen from the
            // *previous* pane (e.g. Downloads > Advanced) stranded on top
            // of the new one's root. Costs the pane's scroll position on
            // return, which is the right trade for a settings screen.
            let pane = selectedPane ?? .appearance
            NavigationStack {
                detailContent(for: pane)
                    .navigationDestination(for: AppRoute.self, destination: AppRouteDestinationView.init)
            }
            .id(pane)
        }
    }

    private var sidebar: some View {
        List(selection: $selectedPane) {
            // Tagged, so it selects the Account pane like any other
            // sidebar row — no `Button`, no sheet. The chevron is dropped
            // here because it would imply a push; selection highlight is
            // the affordance instead.
            Section {
                accountCardLabel(showsChevron: false)
                    .tag(ProfileSettingsPane.account)
            }

            Section {
                ForEach(ProfileSettingsPane.listed) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                }
            }
        }
        .navigationTitle("Profile & Settings")
        // See `splitLayout` — the sidebar is pinned open, so its toggle
        // would be a control that does nothing.
        .toolbar(removing: .sidebarToggle)
        // Five fixed rows in a full-height column: the content virtually
        // never fills it, so the scroll view underneath spent its time
        // rubber-banding and painting a touch highlight in the empty
        // space below the last row — the sidebar reading as interactive
        // when it has nothing there to interact with. `.basedOnSize`
        // makes it inert while the content fits, without hard-disabling
        // scrolling, which would trap the rows off-screen at the largest
        // Dynamic Type sizes where they genuinely do overflow.
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Section headers are dropped here — the navigation title already
    /// names the pane, so repeating it immediately underneath just reads
    /// as a stutter.
    @ViewBuilder
    private func detailContent(for pane: ProfileSettingsPane) -> some View {
        switch pane {
        case .account:
            // The same rows the iPhone shows in a sheet — see
            // `AccountDetailsContent`.
            AccountDetailsContent()
                .navigationTitle("Account")
        case .appearance:
            List { Section { appearanceRows } }
                .navigationTitle("Appearance")
        case .playback:
            List {
                Section {
                    playbackRows
                } footer: {
                    playbackFooter
                }
            }
            .navigationTitle("Playback")
        case .downloads:
            // The whole screen, not a link to it — this is the level of
            // depth the sidebar flattens away on iPad. `.large` so its
            // title matches the other three panes; it defaults to
            // `.inline` because everywhere *else* it's a pushed
            // sub-screen.
            DownloadsSettingsView(titleDisplayMode: .large)
        case .about:
            // The GitHub link and build stamp live here on iPad, rather
            // than under the sidebar the way they briefly did: they're
            // *about* the app, so the About pane is where someone goes
            // looking for them, and the sidebar is navigation rather
            // than a place to park content. A plain section footer
            // trailing the rows — not pinned to the bottom of the pane —
            // so it reads as part of this list the way the compact
            // layout's own page-wide footer does below the same two
            // rows, rather than as separate chrome anchored to the
            // column.
            List {
                Section {
                    aboutRows
                } footer: {
                    versionFooter
                }
            }
            .navigationTitle("About")
        }
    }

    // MARK: Shared section content
    //
    // Every one of these is used by both layouts — `compactLayout` wraps
    // them in `Section`s of one list, `detailContent(for:)` gives each its
    // own pane.

    /// The compact layout's "contact card" — tapping it presents
    /// `AccountDetailsSheet`, which holds the username/server/address
    /// detail plus Sign Out/Change Server.
    ///
    /// iPad doesn't use this: there the same card is a selectable sidebar
    /// row (see `sidebar`) that opens the identical content as a detail
    /// pane, so there's no `Button` and no sheet.
    private var accountCard: some View {
        Button {
            showAccountDetails = true
        } label: {
            accountCardLabel(showsChevron: true)
                .accessibilityHint("Shows account details and sign-out options.")
        }
        .buttonStyle(.plain)
    }

    /// The card's visuals, shared by both layouts.
    ///
    /// `showsChevron` is false in the sidebar, where a disclosure chevron
    /// would wrongly imply a push — selection highlight is the affordance
    /// there.
    private func accountCardLabel(showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            AsyncRemoteImage(url: avatarImageURL, placeholderSystemImage: "person.fill", glyphSize: 24)
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                // Decorative — `accountDisplayName` below already
                // identifies who this is; without this, a loaded
                // avatar photo (a plain `Image(uiImage:)`, not
                // hidden by default) would risk getting folded
                // into the row's combined label as a second,
                // unlabeled stop.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(accountDisplayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(accountServerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    // Decorative disclosure affordance, not content —
                    // same reasoning as the avatar above.
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        // Without this, the `Spacer()` above (and the padding)
        // paint nothing, so only the avatar/text actually
        // hit-test as tappable — a tap anywhere else in the row
        // (including the chevron) silently does nothing. This
        // makes the whole row's bounds the tap target, matching
        // what it visually looks like.
        .contentShape(Rectangle())
        // Same "one combined accessibility label" shape as the
        // Downloads row below (`.ignore` + explicit
        // `.accessibilityLabel`), not `.combine` — more robust
        // than relying on every child view happening to carry no
        // label of its own, and consistent with this file's own
        // established pattern. Applied to the label content
        // (not the `Button` itself, as `Downloads`'s own
        // `LabeledContent` does it) — putting it on the `Button`
        // instead would collapse the button's own "Button"
        // accessibility trait along with its children, leaving
        // VoiceOver with no indication this row is tappable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(accountDisplayName), \(accountServerName)"))
    }

    @ViewBuilder
    private var appearanceRows: some View {
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

    @ViewBuilder
    private var playbackRows: some View {
        Picker("Next Episode Countdown", selection: $nextUpCountdown) {
            ForEach(NextUpCountdownPreference.allCases) { preference in
                Text(preference.displayName)
                    .accessibilityLabel(preference.accessibilityLabel)
                    .tag(preference)
            }
        }
        Toggle("Chapters in Scrubber", isOn: $isChaptersInScrubberEnabled)
        // Streaming mode/bitrate and the Playback Stats button
        // toggle live on their own pushed screen — see
        // `AdvancedPlaybackSettingsView`'s doc comment for why.
        NavigationLink("Advanced") {
            AdvancedPlaybackSettingsView()
        }
    }

    private var playbackFooter: some View {
        Text("Next Episode Countdown sets how long before the end of an episode to count down the next one, if end credits aren't detected. Chapters in Scrubber overlays chapter markers on the scrubber with magnetic snapping while dragging.")
            .readableSettingsFooter()
    }

    private var downloadsRow: some View {
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

    @ViewBuilder
    private var aboutRows: some View {
        NavigationLink("License") {
            LicenseView()
        }
        NavigationLink("Privacy Policy") {
            PrivacyPolicyView()
        }
    }

    private var versionFooter: some View {
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

#Preview {
    ProfileView()
        .environment(AppState())
}
