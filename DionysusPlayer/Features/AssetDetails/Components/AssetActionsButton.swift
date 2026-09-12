import SwiftUI

/// The asset detail page's trailing-toolbar control for the two actions that
/// aren't reversible metadata toggles: **deleting** an item from the Jellyfin
/// server, and **adding** it to a playlist.
///
/// Its own `ToolbarItem` after `HeroActionButtons` rather than a third glyph
/// inside that group, which holds reversible metadata toggles. It shares their
/// `HeroToolbarGlyph` chrome but sits outside their `GlassEffectContainer`, so
/// it doesn't merge into one capsule with them.
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
/// In practice the third row is unreachable and the first means "this user may
/// also delete": adding to a playlist is always available, since Jellyfin's
/// `POST /Playlists` has no permission gate at all (see
/// `JellyfinAPIClient.createPlaylist`) and a user with no editable playlist can
/// still create one. The branch stays because the collapse rule is about the two
/// groups, not about delete.
///
/// Within each group the same collapse applies one level down: a single target
/// is a flat row or button, two or three become a submenu naming each entity,
/// as `HeroActionButtons` collapses its menu on a Movie page.
///
/// ## Permissions
///
/// Deletion is gated on `MediaItem.canDelete`, the server's per-item verdict
/// rather than anything derived locally — see `BaseItemDto.canDelete` for why
/// that matters and `JellyfinAPIClient.deleteItem` for what happens when the
/// gate is wrong. Nothing renders when it's false, rather than a disabled
/// control advertising a permission the user doesn't have. Adding to a playlist
/// is gated the same way one level in: `AddToPlaylistSheet` lists only playlists
/// the server says this user may edit.
///
/// Scoped to movies, episodes, seasons and shows.
/// `CollectionDetailView`/`PlaylistDetailView` don't host this view: deleting
/// either needs different semantics (a playlist owns no media; a collection's
/// members live in other libraries), and this app doesn't add playlists to
/// playlists.
struct AssetActionsButton: View {
    let viewModel: AssetDetailViewModel
    let downloadManager: DownloadManager
    /// `ShowDetailView`'s season-picker selection, as in
    /// `HeroActionButtons.selectedSeasonID`.
    var selectedSeasonID: String? = nil

    @Environment(\.dismiss) private var dismiss
    /// `nil` outside the Home/Search stacks (see
    /// `EnvironmentValues.popNavigationToRoot`); the fallback is `dismiss()`.
    @Environment(\.popNavigationToRoot) private var popToRoot

    @State private var pendingTarget: MediaItem?
    @State private var errorMessage: String?
    /// The entity whose "Add to Playlist" sheet is open, driving `.sheet(item:)`
    /// directly rather than pairing a `Bool` with a stored target — same reason
    /// as `confirmationBinding` below.
    @State private var playlistTarget: MediaItem?

    private var item: MediaItem? { viewModel.item }
    private var isEpisodeContent: Bool { viewModel.item?.kind == .episode }
    private var isPending: Bool { !viewModel.deletingItemIDs.isEmpty }

    /// Every entity this page could offer to delete, most specific last.
    ///
    /// Mirrors `FavoriteWatchedShowScope` with one difference: the episode row is
    /// offered only when the page is genuinely showing an episode, never for
    /// `viewModel.showPlaybackEpisode`. Getting favorite/watched wrong costs a
    /// toggle; offering to delete an episode the user never selected destroys a
    /// file.
    private var deletableTargets: [MediaItem] {
        guard let item else { return [] }
        guard let show = viewModel.seriesItem else {
            // Movie or other standalone content: one possible target.
            return [item].filter(\.canDelete)
        }
        let season = viewModel.seasons.first { $0.id == selectedSeasonID }
        let episode = isEpisodeContent ? item : nil
        return [show, season, episode].compactMap { $0 }.filter(\.canDelete)
    }

    /// Every entity this page could offer to add to a playlist, most specific
    /// last.
    ///
    /// The same shape as `deletableTargets`, including its restriction to genuine
    /// episode content. That restriction is destructive-only in origin, but both
    /// menus sit inside one overflow and must agree on what "this episode"
    /// means.
    ///
    /// No permission filter, unlike `deletableTargets`' `.filter(\.canDelete)`:
    /// every target is addable somewhere, since a user with no editable playlist
    /// can create one.
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
                // Destructive action last and visually separated, per iOS
                // convention, and what stands between a mis-tap on "Add to
                // Playlist" and one on "Delete".
                Divider()
                deleteMenuContent
            } label: {
                HeroToolbarGlyph(systemName: "ellipsis", isPending: isPending)
            }
            // Plain "More": the actions are the menu's rows, which VoiceOver
            // reads on opening it.
            .accessibilityLabel(String(localized: "More Actions"))
            .accessibilityIdentifier(A11yID.AssetDetail.moreButton)
        } else if !playlistTargets.isEmpty {
            addToPlaylistControl
        } else {
            deleteControl
        }
    }

    // MARK: - Delete

    /// The delete action as the toolbar's own control, for a page with nothing
    /// else to offer alongside it.
    @ViewBuilder
    private var deleteControl: some View {
        // A single target collapses to a plain button, as `HeroActionButtons`
        // does on a Movie page: a one-row menu is a pointless extra tap.
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
            // Plain "Delete": the targets are the menu's rows, which VoiceOver
            // reads on opening it.
            .accessibilityLabel(String(localized: "Delete"))
            .accessibilityIdentifier(A11yID.AssetDetail.deleteButton)
        }
    }

    /// The delete action as rows inside the overflow menu. Same collapse rule as
    /// `deleteControl` one level down: a lone target is a flat row, several
    /// become a submenu.
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

    /// The add action as the toolbar's own control — what a user without delete
    /// rights sees, the common case on a shared server.
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

    /// The add action as rows inside the overflow menu.
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

    /// Drives the dialog off `pendingTarget` rather than a separate `Bool`, so
    /// the target a confirmation applies to can't drift from the one that raised
    /// it.
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
        // No identifier: as a popover, which is how iOS renders a
        // `confirmationDialog` anchored to a toolbar button here, the system
        // omits the cancel action and dismisses on an outside tap — no Cancel
        // element exists in the accessibility tree. The button stays for
        // presentation contexts that do render it.
        Button("Cancel", role: .cancel) {}
    }

    private func perform(on target: MediaItem, alsoDeletingDownloads downloadIDs: [String]) {
        // A bare `Task`, not `viewModel.track(...)`: tracked tasks are cancelled
        // by `AssetDetailView.onDisappear`, and this one causes that
        // disappearance. See `AssetDetailViewModel.delete(_:)`.
        Task {
            do {
                let outcome = try await viewModel.delete(target)
                // Only once the server has accepted the deletion; otherwise a
                // failed request still strips the user's local copy, which may
                // be the only one left.
                for itemID in downloadIDs {
                    downloadManager.delete(itemID: itemID)
                }
                switch outcome {
                case .stayAndRefresh:
                    break
                case .popOneLevel:
                    dismiss()
                case .popToRoot:
                    // Falls back to a single pop where no stack owner published
                    // a way to unwind (Downloads/Profile).
                    if let popToRoot { popToRoot() } else { dismiss() }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Downloads

    /// Local downloads orphaned by deleting `target`: the item itself for a
    /// movie or episode, every downloaded episode beneath it for a season or
    /// show. Drives whether the dialog offers the "and Device" option.
    private func downloadedItemIDs(under target: MediaItem) -> [String] {
        // Establishes a dependency on the store's contents so the dialog
        // re-evaluates when a download completes or is removed — the mechanism
        // `DownloadButton.downloadedItem` documents.
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

    /// The action's name, used for the dialog title and the collapsed button's
    /// VoiceOver label.
    private func deleteActionLabel(for target: MediaItem) -> String {
        switch target.kind {
        case .series: return String(localized: "Delete Show")
        case .season: return String(localized: "Delete Season")
        case .episode: return String(localized: "Delete Episode")
        default: return String(localized: "Delete")
        }
    }

    /// Menu rows name the specific entity, not just its type: the menu exists to
    /// tell similar targets apart.
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

    /// Spells out that the file leaves the server and isn't recoverable: this
    /// deletes from the filesystem, not just the library (see
    /// `JellyfinAPIClient.deleteItem`).
    ///
    /// The show and season variants are separate literals with the noun written
    /// into each rather than one string interpolating it. The English is
    /// identical, but a substituted bare noun can't be translated into languages
    /// where the surrounding words inflect for it.
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
