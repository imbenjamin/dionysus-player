import SwiftUI

/// The asset detail page's trailing-toolbar control for the two actions that
/// aren't reversible metadata toggles: **deleting** an item from the Jellyfin
/// server, and **adding** it to a playlist.
///
/// Placed as its own `ToolbarItem` *after* `HeroActionButtons` rather than as
/// a third glyph inside that group: favorite and watched are reversible
/// metadata toggles that belong together, and neither of these is one. It
/// shares their chrome (`HeroToolbarGlyph`) so it still reads as part of the
/// same toolbar, but sits outside their `GlassEffectContainer` so it doesn't
/// merge into one capsule with them.
///
/// ## Which control gets drawn
///
/// The two actions have *independent* availability, so this collapses rather
/// than always drawing an overflow:
///
/// | available | drawn |
/// |---|---|
/// | both | one `ellipsis` `Menu` — the overflow (`A11yID.AssetDetail.moreButton`) |
/// | add only | the add control alone (`text.badge.plus`) |
/// | delete only | the delete control alone (`trash`) |
/// | neither | nothing at all |
///
/// In practice the third row is unreachable today and the first means
/// "this user may also delete": **adding to a playlist is always available**,
/// because Jellyfin's `POST /Playlists` has no permission gate whatsoever
/// (see `JellyfinAPIClient.createPlaylist`) — a user with no editable
/// playlist can still always create one. The branch stays because the
/// collapse rule is about the two groups, not about delete specifically, and
/// a future host that offers only deletion would otherwise draw a
/// one-item overflow menu.
///
/// Within each group the same collapse applies one level down: a single
/// target is a flat row/button, and two or three become a submenu naming each
/// entity, exactly as `HeroActionButtons` collapses its own menu on a Movie
/// page.
///
/// ## Permissions
///
/// **Deletion is gated on `MediaItem.canDelete`**, which is the server's own
/// per-item verdict rather than anything derived locally — see
/// `BaseItemDto.canDelete` for why that distinction matters, and
/// `JellyfinAPIClient.deleteItem` for what happens when the gate is wrong.
/// Nothing renders at all when it's false, so a user without delete rights
/// never sees an affordance they can't use (as opposed to a disabled one,
/// which would just advertise a permission they don't have). The
/// *destination* side of adding to a playlist is gated the same way, but one
/// level in — `AddToPlaylistSheet` lists only playlists the server says this
/// user may edit.
///
/// Scoped to movies, episodes, seasons and shows. Collections and playlists
/// are deliberately excluded — `CollectionDetailView`/`PlaylistDetailView`
/// don't host this view at all — since deleting either would need different
/// semantics (a playlist owns no media of its own; a collection's members
/// live in other libraries), and adding a playlist to a playlist is not a
/// thing this app offers.
struct AssetActionsButton: View {
    let viewModel: AssetDetailViewModel
    let downloadManager: DownloadManager
    /// `ShowDetailView`'s season-picker selection — same prop, and the same
    /// reason for it, as `HeroActionButtons.selectedSeasonID`.
    var selectedSeasonID: String? = nil

    @Environment(\.dismiss) private var dismiss
    /// `nil` outside the Home/Search stacks — see
    /// `EnvironmentValues.popNavigationToRoot`; the fallback is `dismiss()`.
    @Environment(\.popNavigationToRoot) private var popToRoot

    @State private var pendingTarget: MediaItem?
    @State private var errorMessage: String?
    /// The entity whose "Add to Playlist" sheet is open. Drives
    /// `.sheet(item:)` directly rather than pairing a `Bool` with a separate
    /// stored target, for the same reason `confirmationBinding` does below.
    @State private var playlistTarget: MediaItem?

    private var item: MediaItem? { viewModel.item }
    private var isEpisodeContent: Bool { viewModel.item?.kind == .episode }
    private var isPending: Bool { !viewModel.deletingItemIDs.isEmpty }

    /// Every entity this page could offer to delete, most specific last.
    ///
    /// Mirrors `FavoriteWatchedShowScope` with **one deliberate difference**:
    /// the episode row is only offered when the page is genuinely showing an
    /// episode, never for `viewModel.showPlaybackEpisode`. Favorite/watched
    /// can safely offer the show's next-up episode as a third target because
    /// getting it wrong costs a toggle; silently offering to *delete* an
    /// episode the user never selected — and whose name they may not even
    /// have noticed in the menu — is a mis-tap that destroys a file.
    private var deletableTargets: [MediaItem] {
        guard let item else { return [] }
        guard let show = viewModel.seriesItem else {
            // Movie or other standalone content — one possible target.
            return [item].filter(\.canDelete)
        }
        let season = viewModel.seasons.first { $0.id == selectedSeasonID }
        let episode = isEpisodeContent ? item : nil
        return [show, season, episode].compactMap { $0 }.filter(\.canDelete)
    }

    /// Every entity this page could offer to add to a playlist, most specific
    /// last.
    ///
    /// The same shape as `deletableTargets`, including its restriction to
    /// genuine episode content rather than `viewModel.showPlaybackEpisode`.
    /// That restriction exists for a *destructive* reason there, which
    /// doesn't apply here — but the two menus sit inside one overflow, so
    /// they have to agree on what "this episode" means; offering the two
    /// groups different episodes under the same button would be worse than
    /// either rule on its own.
    ///
    /// No permission filter, unlike `deletableTargets`' `.filter(\.canDelete)`
    /// — every target is always addable somewhere, since a user with no
    /// editable playlist can still create one.
    private var playlistTargets: [MediaItem] {
        guard let item else { return [] }
        guard let show = viewModel.seriesItem else {
            return [item]
        }
        let season = viewModel.seasons.first { $0.id == selectedSeasonID }
        let episode = isEpisodeContent ? item : nil
        return [show, season, episode].compactMap { $0 }
    }

    var body: some View {
        if !deletableTargets.isEmpty || !playlistTargets.isEmpty {
            control
                .sheet(item: $playlistTarget) { target in
                    AddToPlaylistSheet(
                        client: viewModel.apiClient,
                        userID: viewModel.currentUserID,
                        target: target
                    )
                }
                .confirmationDialog(
                    confirmationTitle,
                    isPresented: confirmationBinding,
                    titleVisibility: .visible,
                    presenting: pendingTarget
                ) { target in
                    confirmationActions(for: target)
                } message: { target in
                    Text(confirmationMessage(for: target))
                }
                .alert(
                    "Couldn't delete",
                    isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    @ViewBuilder
    private var control: some View {
        if !deletableTargets.isEmpty && !playlistTargets.isEmpty {
            Menu {
                addToPlaylistMenuContent
                // Destructive action last and visually separated, the iOS
                // convention — and the thing standing between a mis-tap on
                // "Add to Playlist" and one on "Delete".
                Divider()
                deleteMenuContent
            } label: {
                HeroToolbarGlyph(systemName: "ellipsis", isPending: isPending)
            }
            // Plain "More" — the actions themselves are the menu's own rows,
            // and VoiceOver reads those on opening it.
            .accessibilityLabel(String(localized: "More Actions"))
            .accessibilityIdentifier(A11yID.AssetDetail.moreButton)
        } else if !playlistTargets.isEmpty {
            addToPlaylistControl
        } else {
            deleteControl
        }
    }

    // MARK: - Delete

    /// The delete action drawn as the toolbar's own control, for a page that
    /// has nothing else to offer alongside it.
    @ViewBuilder
    private var deleteControl: some View {
        // A single target collapses to a plain button, exactly as
        // `HeroActionButtons` collapses its menu on a Movie page — a menu
        // with one row is a pointless extra tap.
        if deletableTargets.count == 1, let only = deletableTargets.first {
            Button(role: .destructive) {
                pendingTarget = only
            } label: {
                HeroToolbarGlyph(systemName: "trash", tint: .red, isPending: isPending)
            }
            .buttonStyle(.plain)
            .disabled(isPending)
            .accessibilityLabel(deleteActionLabel(for: only))
            .accessibilityIdentifier(A11yID.AssetDetail.deleteButton)
        } else {
            Menu {
                deleteTargetRows
            } label: {
                HeroToolbarGlyph(systemName: "trash", tint: .red, isPending: isPending)
            }
            // Plain "Delete" — the individual targets are the menu's own
            // rows, and VoiceOver reads those on opening it.
            .accessibilityLabel(String(localized: "Delete"))
            .accessibilityIdentifier(A11yID.AssetDetail.deleteButton)
        }
    }

    /// The delete action drawn as rows *inside* the overflow menu. Same
    /// collapse rule as `deleteControl`, one level down: a lone target is a
    /// flat row, several become a submenu.
    @ViewBuilder
    private var deleteMenuContent: some View {
        if deletableTargets.count == 1, let only = deletableTargets.first {
            Button(role: .destructive) {
                pendingTarget = only
            } label: {
                Label(deleteActionLabel(for: only), systemImage: "trash")
            }
            .disabled(isPending)
            .accessibilityIdentifier(A11yID.AssetDetail.deleteButton)
        } else {
            Menu {
                deleteTargetRows
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
            .accessibilityIdentifier(A11yID.AssetDetail.deleteButton)
        }
    }

    @ViewBuilder
    private var deleteTargetRows: some View {
        ForEach(deletableTargets, id: \.id) { target in
            Button(role: .destructive) {
                pendingTarget = target
            } label: {
                Label {
                    Text(menuRowLabel(for: target))
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .disabled(viewModel.deletingItemIDs.contains(target.id))
        }
    }

    // MARK: - Add to playlist

    /// The add action drawn as the toolbar's own control — what a user
    /// without delete rights sees, which is the common case on a shared
    /// server.
    @ViewBuilder
    private var addToPlaylistControl: some View {
        if playlistTargets.count == 1, let only = playlistTargets.first {
            Button {
                playlistTarget = only
            } label: {
                HeroToolbarGlyph(systemName: "text.badge.plus", isPending: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Add to Playlist"))
            .accessibilityIdentifier(A11yID.AssetDetail.addToPlaylistButton)
        } else {
            Menu {
                playlistTargetRows
            } label: {
                HeroToolbarGlyph(systemName: "text.badge.plus", isPending: false)
            }
            .accessibilityLabel(String(localized: "Add to Playlist"))
            .accessibilityIdentifier(A11yID.AssetDetail.addToPlaylistButton)
        }
    }

    /// The add action drawn as rows inside the overflow menu.
    @ViewBuilder
    private var addToPlaylistMenuContent: some View {
        if playlistTargets.count == 1, let only = playlistTargets.first {
            Button {
                playlistTarget = only
            } label: {
                Label(String(localized: "Add to Playlist"), systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier(A11yID.AssetDetail.addToPlaylistButton)
        } else {
            Menu {
                playlistTargetRows
            } label: {
                Label(String(localized: "Add to Playlist"), systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier(A11yID.AssetDetail.addToPlaylistButton)
        }
    }

    @ViewBuilder
    private var playlistTargetRows: some View {
        ForEach(playlistTargets, id: \.id) { target in
            Button {
                playlistTarget = target
            } label: {
                Label {
                    Text(menuRowLabel(for: target))
                } icon: {
                    Image(systemName: "text.badge.plus")
                }
            }
        }
    }

    /// Drives the dialog off `pendingTarget` rather than a separate `Bool`,
    /// so the target a confirmation applies to can't drift from the one that
    /// raised it.
    private var confirmationBinding: Binding<Bool> {
        .init(get: { pendingTarget != nil }, set: { if !$0 { pendingTarget = nil } })
    }

    @ViewBuilder
    private func confirmationActions(for target: MediaItem) -> some View {
        let downloads = downloadedItemIDs(under: target)
        if downloads.isEmpty {
            Button("Delete", role: .destructive) { perform(on: target, alsoDeletingDownloads: []) }
                .accessibilityIdentifier(A11yID.AssetDetail.deleteConfirmButton)
        } else {
            Button("Delete from Server", role: .destructive) { perform(on: target, alsoDeletingDownloads: []) }
                .accessibilityIdentifier(A11yID.AssetDetail.deleteConfirmButton)
            Button("Delete from Server and Device", role: .destructive) {
                perform(on: target, alsoDeletingDownloads: downloads)
            }
            .accessibilityIdentifier(A11yID.AssetDetail.deleteWithDownloadButton)
        }
        // No identifier: presented as a popover (which is how iOS renders a
        // `confirmationDialog` anchored to a toolbar button on both iPhone
        // and iPad here), the system omits the cancel action entirely and
        // dismisses on a tap outside instead — confirmed against the live
        // accessibility tree, where no Cancel element exists at all. The
        // button stays because other presentation contexts do render it.
        Button("Cancel", role: .cancel) {}
    }

    private func perform(on target: MediaItem, alsoDeletingDownloads downloadIDs: [String]) {
        // Deliberately a bare `Task`, not `viewModel.track(...)`: tracked
        // tasks are cancelled by `AssetDetailView.onDisappear`, and this one
        // routinely *causes* that disappearance. See
        // `AssetDetailViewModel.delete(_:)`'s own doc comment.
        Task {
            do {
                let outcome = try await viewModel.delete(target)
                // Only once the server has actually accepted the deletion —
                // otherwise a failed request would still strip the user's
                // local copy, which may be the only one left.
                for itemID in downloadIDs {
                    downloadManager.delete(itemID: itemID)
                }
                switch outcome {
                case .stayAndRefresh:
                    break
                case .popOneLevel:
                    dismiss()
                case .popToRoot:
                    // Falls back to a single pop where no stack owner
                    // published a way to unwind (Downloads/Profile).
                    if let popToRoot { popToRoot() } else { dismiss() }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Downloads

    /// Local downloads that would be orphaned by deleting `target` — the
    /// item itself for a movie/episode, every downloaded episode beneath it
    /// for a season or show. Drives whether the dialog offers the
    /// "and Device" option at all.
    private func downloadedItemIDs(under target: MediaItem) -> [String] {
        // Establishes a real dependency on the store's contents so the
        // dialog re-evaluates when a download completes or is removed —
        // same mechanism `DownloadButton.downloadedItem` documents.
        _ = downloadManager.store.changeCount
        switch target.kind {
        case .series:
            return downloadManager.store.allItems().filter { $0.seriesID == target.id }.map(\.itemID)
        case .season:
            return downloadManager.store.allItems().filter { $0.seasonID == target.id }.map(\.itemID)
        default:
            return downloadManager.store.item(itemID: target.id).map { [$0.itemID] } ?? []
        }
    }

    // MARK: - Copy

    private var confirmationTitle: String {
        guard let target = pendingTarget else { return String(localized: "Delete") }
        return deleteActionLabel(for: target)
    }

    /// The action's own name, used for the dialog title and as the collapsed
    /// button's VoiceOver label.
    private func deleteActionLabel(for target: MediaItem) -> String {
        switch target.kind {
        case .series: return String(localized: "Delete Show")
        case .season: return String(localized: "Delete Season")
        case .episode: return String(localized: "Delete Episode")
        default: return String(localized: "Delete")
        }
    }

    /// Menu rows name the specific entity, not just its type — the whole
    /// point of the menu is telling three similar targets apart.
    private func menuRowLabel(for target: MediaItem) -> String {
        switch target.kind {
        case .series, .season:
            return target.name
        case .episode:
            return target.episodeLabel.map { "\($0)  \(target.name)" } ?? target.name
        default:
            return target.name
        }
    }

    /// Deliberately spells out that the file leaves the server, and that it
    /// isn't recoverable — this deletes from the filesystem, not just the
    /// library (see `JellyfinAPIClient.deleteItem`).
    ///
    /// The show and season variants are two separate literals with the noun
    /// written into each, rather than one string interpolating "show"/
    /// "season" as a value. The rendered English is identical, but a
    /// substituted bare noun can't be translated correctly into languages
    /// where the surrounding words inflect for it — and this catalog exists
    /// to be handed to a translation vendor.
    private func confirmationMessage(for target: MediaItem) -> String {
        switch target.kind {
        case .series:
            if let count = target.episodeCount, count > 0 {
                return String(localized: "Deleting this show will delete all \(count) episodes from the Jellyfin server. This cannot be undone.")
            }
            return String(localized: "Deleting this show will delete all of its episodes from the Jellyfin server. This cannot be undone.")
        case .season:
            if let count = target.episodeCount, count > 0 {
                return String(localized: "Deleting this season will delete all \(count) episodes from the Jellyfin server. This cannot be undone.")
            }
            return String(localized: "Deleting this season will delete all of its episodes from the Jellyfin server. This cannot be undone.")
        default:
            return String(localized: "Deleting \"\(target.name)\" will remove it from the Jellyfin server. This cannot be undone.")
        }
    }
}
