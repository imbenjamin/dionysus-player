import SwiftUI

/// Picks a destination for "Add to Playlist" — an existing playlist the user
/// may edit, or a brand new one.
///
/// Presented as a `.sheet` from `AssetActionsButton`, one instance per target
/// (`.sheet(item:)`), so nothing here copes with the target changing underneath.
///
/// Three structural choices are load-bearing:
///
/// - `.presentationDetents([.large])`, never `[.medium]`.
///   `AdvancedDownloadOptionsView` records that a row which pushes inside a
///   fixed `.medium` detent loses a hit-testing fight with the sheet's
///   pan/resize recognizer, so most taps highlight and never complete. This
///   sheet is entirely rows that push or act.
/// - Rows are plain `Button`s, with no `NavigationLink` in the file: "New
///   Playlist" pushes via `.navigationDestination(isPresented:)` from a button
///   action, so the row is an ordinary control that always registers its tap.
/// - Only one level of `List` inside the `NavigationStack`. The create form is a
///   pushed page rather than a second sheet, which would put two presentation
///   contexts between the user and the asset page.
struct AddToPlaylistSheet: View {
    @State private var viewModel: AddToPlaylistViewModel
    @Environment(\.dismiss) private var dismiss

    /// Set when tapping a playlist's row needs to confirm first; non-`nil` only
    /// for a show/season target, per
    /// `AddToPlaylistViewModel.requiresConfirmation`.
    @State private var pendingPlaylist: PlaylistChoice?
    @State private var isShowingCreateForm = false
    @State private var errorMessage: String?
    /// Bumped on every successful add so `.sensoryFeedback` fires. Pairs with the
    /// `Toast` posted alongside it: the haptic confirms something happened, the
    /// toast says what, and a haptic alone says nothing to a user who has them off.
    @State private var successHapticTrigger = 0

    init(client: JellyfinAPIClient, userID: String, target: MediaItem) {
        _viewModel = State(initialValue: AddToPlaylistViewModel(
            client: client, userID: userID, target: target
        ))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to Playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
                .navigationDestination(isPresented: $isShowingCreateForm) {
                    NewPlaylistForm(viewModel: viewModel) { name, isPublic in
                        await perform(toast: viewModel.createdToastMessage(playlistName: name)) {
                            try await viewModel.create(named: name, isPublic: isPublic)
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .task { await viewModel.load() }
        .sensoryFeedback(.success, trigger: successHapticTrigger)
        // An `.alert`, not a `.confirmationDialog`: the dialog form dropped its
        // Cancel action here, the same omission `AssetActionsButton`'s delete
        // dialog documents for a toolbar-anchored popover with tap-outside
        // dismissal. Inside a sheet there's no tap-outside, so losing Cancel
        // leaves only the action the user may not want. An alert renders both.
        //
        // Driven off `pendingPlaylist` rather than a separate `Bool`, so the
        // playlist a confirmation applies to can't drift from the row that raised
        // it.
        .alert(
            confirmationTitle,
            isPresented: .init(
                get: { pendingPlaylist != nil },
                set: { if !$0 { pendingPlaylist = nil } }
            ),
            presenting: pendingPlaylist
        ) { playlist in
            // Titled with the count ("Add 6 Episodes"), not a bare "Add": on a
            // dialog about a whole show, the count belongs on the button.
            Button(viewModel.addActionTitle) {
                Task {
                    await perform(
                        toast: viewModel.addedToastMessage(playlistName: playlist.name)
                    ) { try await viewModel.add(to: playlist.id) }
                }
            }
            .accessibilityIdentifier(A11yID.AddToPlaylist.addConfirmButton)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(A11yID.AddToPlaylist.addCancelButton)
        } message: { playlist in
            Text(viewModel.addConfirmationMessage(playlistName: playlist.name))
        }
        .alert(
            "Couldn't add to playlist",
            isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var confirmationTitle: String {
        pendingPlaylist.map { String(localized: "Add to \"\($0.name)\"") } ?? String(localized: "Add to Playlist")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            LoadingView()
        case .failed(let message):
            ErrorStateView(message: message, retry: { Task { await viewModel.load() } })
        case .loaded:
            picker
        }
    }

    private var picker: some View {
        List {
            Section {
                Button {
                    isShowingCreateForm = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .accessibilityIdentifier(A11yID.AddToPlaylist.newPlaylistButton)
            } footer: {
                // Attached to this section rather than an empty section of its
                // own, which wouldn't reliably render a footer. Not an
                // `ErrorStateView` or a disabled row either: there's a working
                // action directly above, so this explains an absence rather than
                // replacing the screen with a failure.
                if viewModel.playlists.isEmpty {
                    Text("You don't have edit access to any existing playlists. Create a new one instead.")
                        .accessibilityIdentifier(A11yID.AddToPlaylist.emptyState)
                }
            }

            if !viewModel.playlists.isEmpty {
                Section("Your Playlists") {
                    ForEach(viewModel.playlists) { playlist in
                        Button {
                            select(playlist)
                        } label: {
                            row(for: playlist)
                        }
                        .disabled(playlist.alreadyContainsTarget)
                        .accessibilityIdentifier(A11yID.AddToPlaylist.playlistRow(playlist.id))
                    }
                }
            }
        }
        .disabled(viewModel.isSubmitting)
    }

    /// A destination row. The already-added state is a trailing checkmark on a
    /// disabled row rather than a hidden one: a playlist missing from the list
    /// reads as something going wrong, where a greyed row with a tick reads as
    /// already done.
    ///
    /// The checkmark carries no accessibility element; the row collapses to one,
    /// with the state spoken as its value rather than baked into the label, so
    /// VoiceOver reads "Weekend Watchlist, Already added, dimmed".
    @ViewBuilder
    private func row(for playlist: PlaylistChoice) -> some View {
        HStack {
            Text(playlist.name)
            if playlist.alreadyContainsTarget {
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        // A `Button` label containing a `Spacer` only hit-tests where its content
        // is painted, leaving the gap mid-row dead.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            playlist.alreadyContainsTarget ? Text("Already added") : Text("")
        )
    }

    private func select(_ playlist: PlaylistChoice) {
        guard !viewModel.isSubmitting, !playlist.alreadyContainsTarget else { return }
        if viewModel.requiresConfirmation {
            pendingPlaylist = playlist
        } else {
            Task {
                await perform(toast: viewModel.addedToastMessage(playlistName: playlist.name)) {
                    try await viewModel.add(to: playlist.id)
                }
            }
        }
    }

    /// Runs one mutating call, then dismisses the sheet on success or surfaces
    /// the failure without dismissing, so an error the user might retry doesn't
    /// throw away their selection.
    ///
    /// The toast is posted before `dismiss()`, and to `ToastCenter` rather than
    /// anything in this hierarchy: this sheet is about to stop existing, so a
    /// confirmation it owned would be torn down in the frame it appeared. See
    /// `ToastHost`.
    private func perform(toast message: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            successHapticTrigger += 1
            ToastCenter.shared.post(Toast(message: message))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The pushed "name your new playlist" page. `private`: nothing else presents it.
private struct NewPlaylistForm: View {
    let viewModel: AddToPlaylistViewModel
    let onCreate: (String, Bool) async -> Void

    @State private var name = ""
    /// Private by default, matching Jellyfin's web client, whose "Public" checkbox
    /// ships unchecked. Must always be sent whichever way it's set — see
    /// `CreatePlaylistRequest.isPublic`.
    @State private var isPublic = false
    @State private var isConfirming = false
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            Section {
                TextField("Playlist Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($isNameFocused)
                    // The placeholder is the field's only visible label and
                    // vanishes on the first keystroke, so VoiceOver needs an
                    // explicit one, as in `ServerSetupView` and `LoginView`.
                    .accessibilityLabel("Playlist Name")
                    .accessibilityIdentifier(A11yID.AddToPlaylist.nameField)
                    .onSubmit { if !trimmedName.isEmpty { isConfirming = true } }
            }

            Section {
                Toggle("Visible to Everyone", isOn: $isPublic)
                    .accessibilityIdentifier(A11yID.AddToPlaylist.visibilityToggle)
            } footer: {
                Text("Off keeps this playlist to yourself. On lets every user on your Jellyfin server see it.")
            }
        }
        .navigationTitle("New Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { isConfirming = true }
                    .disabled(trimmedName.isEmpty || viewModel.isSubmitting)
                    .accessibilityIdentifier(A11yID.AddToPlaylist.createButton)
            }
        }
        .onAppear { isNameFocused = true }
        // `.alert`, not `.confirmationDialog`, for the reason the parent's add
        // confirmation gives.
        .alert(
            String(localized: "Create \"\(trimmedName)\""),
            isPresented: $isConfirming
        ) {
            Button("Create") {
                Task { await onCreate(trimmedName, isPublic) }
            }
            .accessibilityIdentifier(A11yID.AddToPlaylist.createConfirmButton)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(A11yID.AddToPlaylist.createCancelButton)
        } message: {
            Text(viewModel.createConfirmationMessage(playlistName: trimmedName))
        }
    }
}
