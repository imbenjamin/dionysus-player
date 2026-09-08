import SwiftUI

/// Picks a destination for "Add to Playlist" — an existing playlist the user
/// may edit, or a brand new one.
///
/// Presented as a `.sheet` from `AssetActionsButton`, one instance per target
/// (`.sheet(item:)`), so nothing here has to cope with the target changing
/// underneath it.
///
/// **Three structural choices here are not free-form**, each avoiding a trap
/// this codebase has already paid for once:
///
/// - `.presentationDetents([.large])`, never `[.medium]`.
///   `AdvancedDownloadOptionsView` records that a row which *pushes* inside a
///   fixed `.medium` detent reliably loses a hit-testing fight with the
///   sheet's own pan/resize recognizer — most taps highlight and never
///   complete. This sheet's whole purpose is rows that push or act, so it
///   takes the detent that doesn't have a resize gesture to fight.
/// - Rows are plain `Button`s. There is no `NavigationLink` anywhere in this
///   file; "New Playlist" pushes via `.navigationDestination(isPresented:)`
///   from inside a button action, so the push is programmatic and the row
///   itself is an ordinary control that always registers its tap.
/// - The list is only ever *one* level of `List` inside the `NavigationStack`.
///   The create form is a pushed page rather than a second sheet — stacking
///   sheets to collect a name would put two presentation contexts between the
///   user and the asset page they started on.
struct AddToPlaylistSheet: View {
    @State private var viewModel: AddToPlaylistViewModel
    @Environment(\.dismiss) private var dismiss

    /// Set to a playlist when tapping its row needs to stop and confirm
    /// first — only ever non-`nil` for a show/season target, per
    /// `AddToPlaylistViewModel.requiresConfirmation`.
    @State private var pendingPlaylist: PlaylistChoice?
    @State private var isShowingCreateForm = false
    @State private var errorMessage: String?
    /// Bumped on every successful add so `.sensoryFeedback` fires. Pairs
    /// with the `Toast` posted alongside it: the haptic confirms
    /// *something* happened, the toast says what — a haptic alone was tried
    /// first and can't be the whole answer, since it says nothing to a user
    /// who has haptics off.
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
        // An `.alert`, not a `.confirmationDialog`. The dialog form dropped
        // its Cancel action entirely here (reported from a device,
        // 2026-09-08) — the same omission `AssetActionsButton`'s delete
        // dialog documents for a toolbar-anchored dialog, which iOS renders
        // as a popover with tap-outside dismissal. Inside a sheet there's no
        // equivalent "tap outside", so losing Cancel leaves the user with a
        // dialog whose only visible action is the one they may not want.
        // An alert always renders both.
        //
        // Driven off `pendingPlaylist` rather than a separate `Bool`, so the
        // playlist a confirmation applies to can't drift from the row that
        // raised it — same reasoning as `AssetActionsButton`'s delete dialog.
        .alert(
            confirmationTitle,
            isPresented: .init(
                get: { pendingPlaylist != nil },
                set: { if !$0 { pendingPlaylist = nil } }
            ),
            presenting: pendingPlaylist
        ) { playlist in
            // Titled with the count ("Add 6 Episodes"), not a bare "Add":
            // on a dialog about a whole show, how many things are about to
            // be appended is the detail worth putting on the button itself.
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
                // Attached to *this* section rather than given an empty
                // section of its own, which wouldn't reliably render a
                // footer at all. Not an `ErrorStateView` and not a disabled
                // row either: there's still a perfectly good action directly
                // above it, so this explains an absence rather than
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

    /// A destination row. The already-added state is a trailing checkmark
    /// plus a disabled row, not a hidden one — a playlist silently missing
    /// from the list reads as "something went wrong", where a greyed row
    /// with a tick reads as "you've already done this".
    ///
    /// The checkmark carries no accessibility element of its own; the whole
    /// row collapses to one, with the state spoken as its *value* rather
    /// than baked into the label, so VoiceOver reads "Weekend Watchlist,
    /// Already added, dimmed" instead of a name that changes shape.
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
        // A `Button` label containing a `Spacer` only hit-tests where its
        // content is actually painted — the gap in the middle of this row
        // would otherwise be dead.
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

    /// Runs one mutating call, then either dismisses the whole sheet on
    /// success or surfaces the failure without dismissing, so the user's
    /// selection isn't thrown away by an error they might want to retry.
    ///
    /// The toast is posted *before* `dismiss()`, and to `ToastCenter` rather
    /// than to anything in this view's own hierarchy: this sheet is about to
    /// stop existing, so a confirmation it owned would be torn down in the
    /// same frame it appeared. See `ToastHost`.
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

/// The pushed "name your new playlist" page.
///
/// Split out rather than inlined so the parent's `body` stays readable, and
/// kept `private` to this file — nothing else presents it.
private struct NewPlaylistForm: View {
    let viewModel: AddToPlaylistViewModel
    let onCreate: (String, Bool) async -> Void

    @State private var name = ""
    /// Private by default, matching Jellyfin's own web client (whose "Public"
    /// checkbox ships unchecked). Note this must always be *sent*, whichever
    /// way it's set — see `CreatePlaylistRequest.isPublic`.
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
                    // The placeholder is this field's only visible label and
                    // vanishes on the first keystroke, so VoiceOver needs an
                    // explicit one — the same rule `ServerSetupView` and
                    // `LoginView` follow for their own fields.
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
        // `.alert`, not `.confirmationDialog`, for the same reason the add
        // confirmation in the parent uses one — see its comment.
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
