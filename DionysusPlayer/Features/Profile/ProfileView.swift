import SwiftUI

/// Which settings pane the iPad sidebar has selected.
///
/// Only used by `ProfileView`'s split layout; the compact layout shows these
/// as `Section`s of one list, with no selection.
private enum ProfileSettingsPane: Identifiable, Hashable {
    /// Selected by the contact card at the top of the sidebar, not a labelled
    /// row — hence its absence from `listed`, and why the type isn't
    /// `CaseIterable`: `allCases` would put a duplicate "Account" row under
    /// the card.
    case account
    case appearance
    case playback
    case downloads
    case about

    var id: Self { self }

    /// The panes shown as labelled sidebar rows, in order. `.account` is
    /// reachable only through the contact card.
    static let listed: [ProfileSettingsPane] = [.appearance, .playback, .downloads, .about]

    /// `String(localized:)` rather than bare literals: these feed
    /// `Label(_:systemImage:)`'s `String` overload, which isn't auto-extracted
    /// into the String Catalog. Each key already exists there from the section
    /// header or navigation title it duplicates.
    var title: String {
        switch self {
        case .account: return String(localized: "Account")
        case .appearance: return String(localized: "Appearance")
        case .playback: return String(localized: "Playback")
        case .downloads: return String(localized: "Downloads")
        case .about: return String(localized: "About")
        }
    }

    /// Unused for `.account`, whose card shows an avatar instead, but kept
    /// total so `listed`'s `ForEach` needs no unwrapping.
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

/// Account/server settings: who's signed in and where, plus sign out and
/// change server.
///
/// ## Two layouts
///
/// On iPhone, one scrolling `List` of sections (`compactLayout`).
///
/// On iPad, a `NavigationSplitView` with the sections as sidebar items and
/// their contents in the detail column, mirroring Settings.app. On an 11-inch
/// iPad in landscape (1180x820pt) the single-column layout ran to y=1044 on an
/// 820pt screen — the About section and version footer below the fold while
/// 40% of the width sat empty — and stretched rows to 1140pt, putting ~1,060pt
/// between a label and its value. The sidebar also flattens a level of depth:
/// Downloads is a destination rather than a push, so
/// `DownloadsSettingsView`'s "Advanced" is the first push on iPad.
///
/// This view owns its navigation container, unlike the other three tabs which
/// `MainTabView` wraps in a `NavigationStack`, because the container differs
/// per layout — a `NavigationSplitView` inside a `NavigationStack` is not
/// supported.
struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(themePreferenceStorageKey) private var themePreference: ThemePreference = .system
    /// Default `true`, matching `HeroHeaderView`'s default for this key. An
    /// `@AppStorage` initial value is local and writes nothing to
    /// `UserDefaults` until the Toggle is flipped, so both sites must declare
    /// the same default to agree before this screen is ever visited.
    @AppStorage(hero3DDepthEnabledStorageKey) private var hero3DDepthEnabled = true
    /// Default `true`, matching `HeroRailView`, same reasoning as
    /// `hero3DDepthEnabled`. VoiceOver forces manual navigation regardless —
    /// see `HeroRailView.manualCarouselModeEnabled`; this is only the
    /// preference.
    @AppStorage(heroAutoCarouselEnabledStorageKey) private var autoCarouselEnabled = true
    /// Default `.seconds30`, matching `NextUpPreferenceStore.countdownSeconds`,
    /// same reasoning as `hero3DDepthEnabled`.
    @AppStorage(nextUpCountdownStorageKey) private var nextUpCountdown: NextUpCountdownPreference = .seconds30
    /// Default `true`, matching `PlayerControlsOverlay`'s read of this key. See
    /// `chaptersInScrubberEnabledDefault` for what it does and doesn't gate.
    @AppStorage(chaptersInScrubberEnabledStorageKey) private var isChaptersInScrubberEnabled = chaptersInScrubberEnabledDefault
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAccountDetails = false
    @State private var avatarImageURL: URL?

    /// Non-optional default so the detail column never opens on a "select
    /// something" placeholder, like Settings.app. Declared `Optional` because
    /// that's what `List(selection:)` binds to.
    @State private var selectedPane: ProfileSettingsPane? = .appearance

    /// See `SettingsLayout` for why this ANDs both size classes rather than
    /// testing width alone like the Home/Search/Downloads grids.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    /// Recomputed on every `body` evaluation: a `FileManager` directory scan
    /// (`DownloadFileStore.totalSizeOnDisk()`), neither cached nor tied to
    /// `DownloadManager`. Cheap enough for an occasionally-visited settings row
    /// to not need a dedicated `@Observable` size tracker.
    private var downloadsStorageUsedText: String {
        ByteCountFormatter.string(fromByteCount: DownloadFileStore.totalSizeOnDisk(), countStyle: .file)
    }

    /// Identical copy of `DownloadedInfoMetadataRow.spokenFileSize(_:)`, not
    /// shared, for the reason documented there. Parses an already-formatted
    /// `ByteCountFormatter` string rather than reimplementing its unit
    /// selection and rounding.
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

    /// Fetches the signed-in user's avatar URL via a
    /// `client.makeImageURLBuilder()` actor hop, like
    /// `MainTabView.loadProfileTabIcon()`, but hands it to `AsyncRemoteImage`
    /// rather than rendering it directly — this avatar is large enough to want
    /// the usual retry/placeholder/shimmer treatment.
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
        // Drives `DeviceTiltObserver.shared` from the toggle itself rather
        // than through whichever `HeroHeaderView` happens to still be mounted
        // in another tab's nav stack: with no detail page live, that
        // `.onChange` never runs and `stop()` is never called.
        // `HeroHeaderView` keeps its own `.onChange` for when one is on
        // screen; both calls are idempotent, so they no-op against each other.
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

    /// iPhone, and any non-iPad regular-width container (see
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

                // Page-wide footer, not tied to the section above it: the
                // build's branch/commit, plus a GitHub repo link.
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
    /// The sidebar is pinned open: `.constant(.all)` leaves no writable
    /// binding to collapse it, and `.toolbar(removing:)` drops the show/hide
    /// button. With four fixed destinations, collapsing would leave the detail
    /// pane with no way back to its siblings.
    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            // `.id(pane)` rebuilds the stack on a selection change, so a
            // screen pushed from the previous pane can't be stranded on top of
            // the new one's root. Costs the pane's scroll position on return.
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
            // Tagged, so it selects the Account pane like any other sidebar
            // row — no `Button`, no sheet. No chevron, which would imply a
            // push; selection highlight is the affordance.
            Section {
                accountCardLabel(showsChevron: false)
                    .tag(ProfileSettingsPane.account)
                    // Same identifier as the compact layout's `Button`-wrapped
                    // `accountCard`, so a screen object needn't know which
                    // layout rendered it.
                    .accessibilityIdentifier(A11yID.Profile.accountCard)
            }

            Section {
                ForEach(ProfileSettingsPane.listed) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                }
            }
        }
        .navigationTitle("Profile & Settings")
        // The sidebar is pinned open (see `splitLayout`), so its toggle would
        // do nothing.
        .toolbar(removing: .sidebarToggle)
        // Five fixed rows rarely fill a full-height column, so the scroll view
        // rubber-banded and painted touch highlights in the empty space below
        // the last row. `.basedOnSize` makes it inert while the content fits,
        // without hard-disabling scrolling, which would trap rows off-screen at
        // the largest Dynamic Type sizes.
        .scrollBounceBehavior(.basedOnSize)
    }

    /// No section headers: the navigation title already names the pane.
    @ViewBuilder
    private func detailContent(for pane: ProfileSettingsPane) -> some View {
        switch pane {
        case .account:
            // The same rows the iPhone shows in a sheet.
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
            // The whole screen, not a link to it — the level of depth the
            // sidebar flattens on iPad. `.large` to match the other panes; it
            // defaults to `.inline` because elsewhere it's a pushed sub-screen.
            DownloadsSettingsView(titleDisplayMode: .large)
        case .about:
            // The GitHub link and build stamp belong in the About pane rather
            // than under the sidebar, which is navigation, not a place to park
            // content. A plain section footer trailing the rows, not pinned to
            // the bottom of the pane, so it reads as part of this list like the
            // compact layout's page-wide footer.
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
    // Used by both layouts: `compactLayout` wraps them in `Section`s of one
    // list, `detailContent(for:)` gives each its own pane.

    /// The compact layout's contact card; tapping it presents
    /// `AccountDetailsSheet` (username/server/address, Sign Out, Change
    /// Server). iPad instead makes the same card a selectable sidebar row
    /// opening the identical content as a pane, with no `Button` and no sheet.
    private var accountCard: some View {
        Button {
            showAccountDetails = true
        } label: {
            accountCardLabel(showsChevron: true)
                .accessibilityHint("Shows account details and sign-out options.")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Profile.accountCard)
    }

    /// The card's visuals, shared by both layouts. `showsChevron` is false in
    /// the sidebar, where a chevron would imply a push.
    private func accountCardLabel(showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            AsyncRemoteImage(url: avatarImageURL, placeholderSystemImage: "person.fill", glyphSize: 24)
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                // Decorative: `accountDisplayName` below identifies the user,
                // and a loaded `Image(uiImage:)` isn't hidden by default, so
                // it would fold into the row's label as an unlabeled stop.
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
                    // Decorative affordance, same reasoning as the avatar.
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        // The `Spacer()` and padding paint nothing, so without this only the
        // avatar and text hit-test and a tap elsewhere in the row does
        // nothing. Makes the row's full bounds the tap target.
        .contentShape(Rectangle())
        // `.ignore` plus an explicit label, like the Downloads row below,
        // rather than `.combine`, which relies on no child carrying a label of
        // its own. Applied to the label content rather than the `Button`:
        // on the `Button` it would collapse the "Button" trait too, leaving
        // VoiceOver no indication the row is tappable.
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
                // `DeviceTiltObserver.shared`, not anything local to this
                // view, does the work this spinner stands in for — see its
                // `isApplyingChange` for why it takes a perceptible moment
                // even off the main thread.
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
        // Streaming mode/bitrate and the Playback Stats toggle live on their
        // own pushed screen — see `AdvancedPlaybackSettingsView`. "Advanced"
        // is also `DownloadsQualityLadderView`'s link text, so the identifier
        // is what tells the two apart.
        NavigationLink("Advanced") {
            AdvancedPlaybackSettingsView()
        }
        .accessibilityIdentifier(A11yID.Profile.advancedPlaybackLink)
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
                // `LabeledContent` folds title and value into one combined
                // label rather than a label/value pair, so
                // `.accessibilityValue` alone appends a second reading
                // ("Downloads. 2.44 GB. 2.44 gigabytes.") instead of replacing
                // it. `.accessibilityElement(children: .ignore)` suppresses the
                // combine so only the explicit label below is read.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Downloads, \(Self.spokenFileSize(downloadsStorageUsedText))"))
        }
        .accessibilityIdentifier(A11yID.Profile.downloadsSettingsLink)
    }

    @ViewBuilder
    private var aboutRows: some View {
        NavigationLink("License") {
            LicenseView()
        }
        .accessibilityIdentifier(A11yID.Profile.licenseLink)
        NavigationLink("Privacy Policy") {
            PrivacyPolicyView()
        }
        .accessibilityIdentifier(A11yID.Profile.privacyPolicyLink)
    }

    private var versionFooter: some View {
        // Tight, because the Link's frame below already pads out to a 44pt
        // touch target and that padding doubles as the gap to the version text.
        VStack(spacing: 0) {
            Link(destination: URL(string: "https://github.com/imbenjamin/dionysus-player")!) {
                Image("GitHubGlyph")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    // 28pt glyph padded out to HIG's 44pt minimum touch
                    // target; a 44pt mark would look oversized next to the
                    // caption-sized version text.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            // Without this, VoiceOver reads the asset name ("Github Glyph")
            // rather than what the link does.
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
