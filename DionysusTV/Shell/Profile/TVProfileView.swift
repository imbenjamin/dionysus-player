import SwiftUI

/// Profile (prototype screen 11): who is signed in and the app's versions on
/// the left, the settings as focusable rows on the right. Profile is the only
/// way to settings; there is no separate Settings page.
///
/// iOS's sections minus Downloads, 3D Depth Effects and Theme, plus Switch
/// User, Sign Out and the two Apple TV session settings. Next Episode
/// Countdown, Chapters in Scrubber, Subtitle Styling and the stats button are
/// stored now and take effect with their player features in M4.
struct TVProfileView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(heroAutoCarouselEnabledStorageKey) private var autoCarousel = true
    @AppStorage(nextUpCountdownStorageKey) private var nextUpCountdown: NextUpCountdownPreference = .seconds30
    @AppStorage(chaptersInScrubberEnabledStorageKey) private var chaptersInScrubber = chaptersInScrubberEnabledDefault

    /// Each sub-screen is a cover: Menu closes it, and the row beneath keeps
    /// focus. Not `.confirmationDialog`, whose buttons lose their
    /// accessibility identifiers on tvOS, nor a push, which would put the
    /// sidebar beside a page that belongs to Profile.
    private enum Cover: String, Identifiable {
        case changeServer, signOut, quickConnect, nextUpCountdown, advanced, license, privacyPolicy
        var id: String { rawValue }
    }

    @State private var cover: Cover?
    @State private var quickConnectAvailable = false
    /// Switch User is the default focus (`tvClaimsFocus`).
    @FocusState private var focus: String?
    @State private var remembered: String?
    /// Copies to draw from: these settings live in the keychain, which
    /// nothing observes.
    @State private var followsAppleTVUsers = SessionScopeSetting.followsAppleTVUsers
    @State private var selectsUserEveryRelaunch = SessionScopeSetting.selectsUserEveryRelaunch

    private var user: UserDto? {
        TVProfileIdentity.user(currentUser: appState.currentUser, credentials: appState.sessionStore.credentials)
    }

    private var server: ServerConfiguration? { appState.sessionStore.serverConfiguration }

    private func onOff(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }

    /// In the order drawn, Switch User first.
    private var focusIDs: [String] {
        [A11yID.TV.Profile.switchUser]
            + (quickConnectAvailable ? [A11yID.TV.Profile.approveQuickConnect] : [])
            + [A11yID.TV.Profile.changeServer, A11yID.TV.Profile.signOut, A11yID.TV.Profile.followsAppleTVUsers]
            // The second setting only means something with one shared
            // session, so it's only there while the first is off.
            + (followsAppleTVUsers ? [] : [A11yID.TV.Profile.selectsUserEveryRelaunch])
            + [A11yID.TV.Profile.autoCarousel, A11yID.TV.Profile.nextUpCountdown, A11yID.TV.Profile.chaptersInScrubber,
               A11yID.TV.Profile.advanced, A11yID.TV.Profile.license, A11yID.TV.Profile.privacyPolicy]
    }

    var body: some View {
        TVPageScaffold {
            HStack(alignment: .top, spacing: 60) {
                brandPane
                rows
            }
        }
        .tvClaimsFocus($focus, ids: focusIDs, remembered: $remembered)
        .task {
            guard let client = appState.apiClient else { return }
            quickConnectAvailable = await QuickConnectApprovalViewModel.isAvailable(on: client)
        }
        .fullScreenCover(item: $cover) { cover in
            switch cover {
            case .changeServer:
                TVConfirmation(
                    title: "Change Server?",
                    message: "Everyone on this Apple TV will need to find a server and sign in again.",
                    action: "Change Server",
                    actionIdentifier: A11yID.TV.Profile.changeServerConfirm
                ) { appState.changeServer() }
            case .signOut:
                // iOS's title: you sign out *of* a server.
                TVConfirmation(
                    title: "Sign out of \(appState.sessionStore.serverConfiguration?.name ?? String(localized: "your server"))?",
                    message: "This Apple TV will forget the account, so signing in again needs its password or a new Quick Connect code.",
                    action: "Sign Out",
                    actionIdentifier: A11yID.TV.Profile.signOutConfirm
                ) { appState.signOutForgettingAccount() }
            case .quickConnect:
                if let client = appState.apiClient {
                    TVQuickConnectApprovalView(viewModel: QuickConnectApprovalViewModel(
                        client: client, userName: user?.name ?? "", serverName: server?.name ?? ""
                    ))
                }
            case .nextUpCountdown:
                TVSettingsPicker(
                    title: "Next Episode Countdown",
                    selection: $nextUpCountdown,
                    id: { String($0.rawValue) },
                    label: \.displayName,
                    accessibilityLabel: \.accessibilityLabel
                )
            case .advanced:
                TVAdvancedPlaybackView()
            case .license:
                TVTextPageView(title: "License", paragraphs: TVTextPageView.paragraphs(resource: "LICENSE", extension: nil, markdown: false))
            case .privacyPolicy:
                TVTextPageView(title: "Privacy Policy", paragraphs: TVTextPageView.paragraphs(resource: "PRIVACY", extension: "md", markdown: true))
            }
        }
    }

    /// The prototype's left pane: who this is, and what's running.
    private var brandPane: some View {
        VStack(spacing: 26) {
            if let user {
                UserAvatar(user: user, serverURL: server?.baseURL, size: 220)
                Text(verbatim: user.name)
                    .font(.title2.bold())
                    .accessibilityIdentifier(A11yID.TV.Profile.name)
            }
            if let server {
                let address = server.baseURL.host() ?? server.baseURL.absoluteString
                VStack(spacing: 6) {
                    Text(verbatim: server.name)
                        .foregroundStyle(.secondary)
                    Text(verbatim: address)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                // One element: the server, with its address as the value.
                // Read as a label of its own, a host name isn't
                // human-readable to the accessibility audit.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: server.name))
                .accessibilityValue(Text(verbatim: address))
                .accessibilityIdentifier(A11yID.TV.Profile.server)
            }
            // "AetherEngine" is a product name, not translated.
            Text(verbatim: "\(AppVersionInfo.footerText())\nAetherEngine \(AetherEngineVersion.current)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 30)
                .accessibilityIdentifier(A11yID.TV.Profile.version)
        }
        .frame(width: 520)
        .frame(maxHeight: .infinity)
    }

    private var rows: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TVSettingsHeader(title: "Account")
                row("Switch User", id: A11yID.TV.Profile.switchUser) { appState.signOut() }
                if quickConnectAvailable {
                    row("Approve Quick Connect Code", opensPage: true, id: A11yID.TV.Profile.approveQuickConnect) { cover = .quickConnect }
                }
                row("Change Server", role: .destructive, id: A11yID.TV.Profile.changeServer) { cover = .changeServer }
                row("Sign Out", role: .destructive, id: A11yID.TV.Profile.signOut) { cover = .signOut }

                TVSettingsHeader(title: "Apple TV Users")
                row("Follow Apple TV Users", value: onOff(followsAppleTVUsers), id: A11yID.TV.Profile.followsAppleTVUsers) {
                    appState.setFollowsAppleTVUsers(!followsAppleTVUsers)
                    followsAppleTVUsers = SessionScopeSetting.followsAppleTVUsers
                }
                if !followsAppleTVUsers {
                    row("Select a User Every Relaunch", value: onOff(selectsUserEveryRelaunch), id: A11yID.TV.Profile.selectsUserEveryRelaunch) {
                        SessionScopeSetting.setSelectsUserEveryRelaunch(!selectsUserEveryRelaunch)
                        selectsUserEveryRelaunch = SessionScopeSetting.selectsUserEveryRelaunch
                    }
                }
                TVSettingsFooter(text: "Attempts to match Jellyfin users to this Apple TV's users. Turn off to keep user switching inside the app, and when users become out of sync.")

                TVSettingsHeader(title: "Appearance")
                row("Auto Carousel on Home", value: onOff(autoCarousel), id: A11yID.TV.Profile.autoCarousel) { autoCarousel.toggle() }

                TVSettingsHeader(title: "Playback")
                row("Next Episode Countdown", value: nextUpCountdown.displayName, opensPage: true, id: A11yID.TV.Profile.nextUpCountdown) {
                    cover = .nextUpCountdown
                }
                row("Chapters in Scrubber", value: onOff(chaptersInScrubber), id: A11yID.TV.Profile.chaptersInScrubber) {
                    chaptersInScrubber.toggle()
                }
                row("Advanced", opensPage: true, id: A11yID.TV.Profile.advanced) { cover = .advanced }
                TVSettingsFooter(text: "Next Episode Countdown sets how long before the end of an episode to count down the next one, if end credits aren't detected. Chapters in Scrubber overlays chapter markers on the scrubber with magnetic snapping while dragging.")

                TVSettingsHeader(title: "About")
                row("License", opensPage: true, id: A11yID.TV.Profile.license) { cover = .license }
                row("Privacy Policy", opensPage: true, id: A11yID.TV.Profile.privacyPolicy) { cover = .privacyPolicy }
            }
            .padding(.top, 60)
            .padding(.bottom, 120)
            .padding(.trailing, 80)
        }
        .scrollClipDisabled()
    }

    private func row(_ title: LocalizedStringKey, value: String? = nil, opensPage: Bool = false, role: ButtonRole? = nil, id: String, action: @escaping () -> Void) -> some View {
        TVSettingsRow(title: title, value: value, opensPage: opensPage, role: role, identifier: id, action: action)
            .focused($focus, equals: id)
    }
}

/// Asks before a destructive account action. Change Server forgets the
/// server for every Apple TV user: their stored sign-ins then fail the server
/// check at launch, so they all start again. Sign Out forgets the account on
/// this Apple TV (Benjamin, 2026-10-05). Cancel takes focus, so a stray
/// Select changes nothing.
private struct TVConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let action: LocalizedStringKey
    let actionIdentifier: String
    let onConfirm: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            Text(title).font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            VStack(spacing: 24) {
                Button(role: .destructive) {
                    dismiss()
                    onConfirm()
                } label: {
                    Text(action).frame(width: 500)
                }
                .accessibilityIdentifier(actionIdentifier)
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel").frame(width: 500)
                }
                .focused($cancelFocused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque enough that Profile's own text and buttons don't read
        // through as part of the question.
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($cancelFocused, true)
    }
}
