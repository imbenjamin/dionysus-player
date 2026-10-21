import SwiftUI

/// Picks where "Add to Playlist" puts its target: a playlist the user may
/// edit, or a new one. iOS's `AddToPlaylistSheet` on the shared
/// `AddToPlaylistViewModel`, row for row: New Playlist first, then the
/// playlists, one already holding everything the target would add drawn
/// ticked and dimmed. A full-screen cover opened from More Actions' menu;
/// New Playlist pushes its form inside it, so Menu steps back a page, then
/// closes the cover onto More.
///
/// A show or season asks first (it adds every episode beneath it); a single
/// movie or episode is added at once. Success posts iOS's toast and closes
/// the cover; a failure says so and leaves the picker up.
struct TVAddToPlaylistPage: View {
    @State private var viewModel: AddToPlaylistViewModel
    /// Closes the whole cover, onto More.
    let close: () -> Void

    @State private var pendingPlaylist: PlaylistChoice?
    /// Confirmed, and added once the question has gone: closing this cover
    /// while the question's own is still dismissing could leave it up.
    @State private var confirmedPlaylist: PlaylistChoice?
    @State private var isShowingCreateForm = false
    @State private var errorMessage: String?
    @FocusState private var focused: String?

    init(client: JellyfinAPIClient, userID: String, target: MediaItem, close: @escaping () -> Void) {
        _viewModel = State(initialValue: AddToPlaylistViewModel(client: client, userID: userID, target: target))
        self.close = close
    }

    var body: some View {
        content
            .frame(width: 900, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
            .task { await viewModel.load() }
            .navigationDestination(isPresented: $isShowingCreateForm) {
                TVNewPlaylistForm(viewModel: viewModel) { name, isPublic in
                    await perform(toast: viewModel.createdToastMessage(playlistName: name)) {
                        try await viewModel.create(named: name, isPublic: isPublic)
                    }
                }
            }
            .fullScreenCover(item: $pendingPlaylist, onDismiss: addConfirmed) { playlist in
                TVConfirmation(
                    title: Text(verbatim: String(localized: "Add to \"\(playlist.name)\"")),
                    message: Text(verbatim: viewModel.addConfirmationMessage(playlistName: playlist.name)),
                    // "Add 6 Episodes": on a question about a whole show, the
                    // count belongs on the button.
                    action: Text(verbatim: viewModel.addActionTitle),
                    actionIdentifier: A11yID.TV.Actions.addConfirm,
                    isDestructive: false
                ) { confirmedPlaylist = playlist }
            }
            .alert(
                "Couldn't add to playlist",
                isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            // Focusable, so the page has somewhere for focus while it loads.
            ProgressView()
                .padding(24)
                .focusable()
                .accessibilityLabel(Text("Loading"))
                .frame(maxWidth: .infinity)
        case .failed(let message):
            VStack(spacing: 30) {
                Text("Couldn't load your playlists.").font(.title3.bold())
                Text(verbatim: message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Task { await viewModel.load() } } label: { Text("Try Again").frame(width: 400) }
                    .accessibilityIdentifier(A11yID.TV.Actions.playlistsRetry)
            }
            .frame(maxWidth: .infinity)
        case .loaded:
            picker
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add to Playlist")
                    .font(.title2.bold())
                    .padding(.leading, 34)
                    .padding(.bottom, 12)
                // With no playlist to list, the explanation below is also its
                // hint: VoiceOver never reaches text focus can't land on (M5).
                TVSettingsRow(
                    title: "New Playlist",
                    hint: viewModel.playlists.isEmpty ? "You don't have edit access to any existing playlists. Create a new one instead." : nil,
                    opensPage: true, identifier: A11yID.TV.Actions.newPlaylist
                ) {
                    guard !viewModel.isSubmitting else { return }
                    isShowingCreateForm = true
                }
                .focused($focused, equals: A11yID.TV.Actions.newPlaylist)
                if viewModel.playlists.isEmpty {
                    // Explains the absence, beside a working action.
                    Text("You don't have edit access to any existing playlists. Create a new one instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 34)
                        .accessibilityIdentifier(A11yID.TV.Actions.emptyState)
                } else {
                    TVSettingsSection(title: "Your Playlists", identifier: "tv.actions.playlists", headingIdentifier: "tv.actions.playlists.heading") {
                        ForEach(viewModel.playlists) { playlist in
                            row(for: playlist)
                        }
                    }
                }
            }
            .padding(.vertical, 80)
        }
        // A focused row grows past the 900pt column; clipped, its rounded
        // ends were cut off (Benjamin, 2026-10-21).
        .scrollClipDisabled()
        // Select is ignored while a request runs rather than the rows
        // disabled: disabling the focused row hands focus to tvOS.
        .defaultFocus($focused, A11yID.TV.Actions.newPlaylist)
    }

    /// Already holding the target: ticked and dimmed rather than hidden, as on
    /// iOS. A missing playlist reads as something gone wrong; a ticked one as
    /// already done. "Already added" is its value, so VoiceOver says why.
    private func row(for playlist: PlaylistChoice) -> some View {
        Button { select(playlist) } label: {
            HStack {
                Text(verbatim: playlist.name)
                Spacer()
                if playlist.alreadyContainsTarget {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(playlist.alreadyContainsTarget)
        .focused($focused, equals: A11yID.TV.Actions.playlistRow(playlist.id))
        .accessibilityLabel(Text(verbatim: playlist.name))
        .accessibilityValue(playlist.alreadyContainsTarget ? Text("Already added") : Text(verbatim: ""))
        .accessibilityIdentifier(A11yID.TV.Actions.playlistRow(playlist.id))
    }

    private func select(_ playlist: PlaylistChoice) {
        guard !viewModel.isSubmitting, !playlist.alreadyContainsTarget else { return }
        if viewModel.requiresConfirmation {
            pendingPlaylist = playlist
        } else {
            add(to: playlist)
        }
    }

    private func addConfirmed() {
        guard let playlist = confirmedPlaylist else { return }
        confirmedPlaylist = nil
        add(to: playlist)
    }

    private func add(to playlist: PlaylistChoice) {
        Task {
            await perform(toast: viewModel.addedToastMessage(playlistName: playlist.name)) {
                try await viewModel.add(to: playlist.id)
            }
        }
    }

    /// Posts the toast before closing: the cover is about to go, and the
    /// toast lives in the shell (`ToastHost`), so it outlives it.
    private func perform(toast message: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            ToastCenter.shared.post(Toast(message: message))
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Names a new playlist: the name (tvOS's own keyboard), whether everyone on
/// the server sees it (off, as in Jellyfin's web client and on iOS), and
/// Create, which asks first.
private struct TVNewPlaylistForm: View {
    let viewModel: AddToPlaylistViewModel
    let onCreate: (String, Bool) async -> Void

    @State private var name = ""
    /// Private by default; always sent (`CreatePlaylistRequest.isPublic`).
    @State private var isPublic = false
    @State private var isConfirming = false
    /// Created once the question has gone, as the picker adds.
    @State private var isConfirmed = false
    @FocusState private var focused: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Playlist")
                .font(.title2.bold())
                .padding(.leading, 34)
                .padding(.bottom, 12)
            TextField("Playlist Name", text: $name)
                .autocorrectionDisabled()
                .focused($focused, equals: A11yID.TV.Actions.nameField)
                // The placeholder goes on the first keystroke.
                .accessibilityLabel(Text("Playlist Name"))
                .accessibilityIdentifier(A11yID.TV.Actions.nameField)
            TVSettingsRow(
                title: "Visible to Everyone",
                value: isPublic ? String(localized: "On") : String(localized: "Off"),
                hint: "Off keeps this playlist to yourself. On lets every user on your Jellyfin server see it.",
                identifier: A11yID.TV.Actions.visibilityToggle
            ) { isPublic.toggle() }
            TVSettingsFooter(text: "Off keeps this playlist to yourself. On lets every user on your Jellyfin server see it.")
            TVSettingsRow(title: "Create", identifier: A11yID.TV.Actions.create) {
                guard !viewModel.isSubmitting else { return }
                isConfirming = true
            }
            .disabled(trimmedName.isEmpty)
                .padding(.top, 24)
        }
        // At the top, as the actions and the picker are.
        .padding(.top, 80)
        .frame(width: 900, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focused, A11yID.TV.Actions.nameField)
        .fullScreenCover(isPresented: $isConfirming, onDismiss: createConfirmed) {
            TVConfirmation(
                title: Text(verbatim: String(localized: "Create \"\(trimmedName)\"")),
                message: Text(verbatim: viewModel.createConfirmationMessage(playlistName: trimmedName)),
                action: Text("Create"),
                actionIdentifier: A11yID.TV.Actions.createConfirm,
                isDestructive: false
            ) { isConfirmed = true }
        }
    }

    private func createConfirmed() {
        guard isConfirmed else { return }
        isConfirmed = false
        Task { await onCreate(trimmedName, isPublic) }
    }
}
