import SwiftUI

/// The asset detail page's trailing-toolbar control for the two actions that
/// aren't reversible metadata toggles: **deleting** an item from the Jellyfin
/// server, and **adding** it to a playlist.
///
/// Its own `ToolbarItem` after `HeroActionButtons` rather than a third glyph
/// inside that group, which holds reversible metadata toggles. It shares their
/// `HeroToolbarGlyph` glyph treatment but sits in a separate `ToolbarItem`
/// past a `ToolbarSpacer(.fixed)`, so the nav bar gives it its own capsule
/// rather than merging it into theirs.
///
/// ## Which control gets drawn
///
/// Always one `ellipsis` `Menu`, the overflow (`A11yID.AssetDetail.moreButton`):
/// "Add to Playlist" for everyone, then "Delete" below a divider when the
/// server allows it.
///
/// This used to collapse to whichever single action was available — a bare
/// `text.badge.plus` button for a user without delete rights — which made the
/// control's *kind* depend on `MediaItem.canDelete`. That's only known once
/// the full item has loaded (`Fields=CanDelete` is too expensive for the rail
/// and grid fetches a preloaded item comes from; see
/// `JellyfinAPIClient.detailFields`), so every push from a rail or grid by a
/// user who *could* delete started as the button and became the menu about
/// 300ms later. On iOS 26 swapping a bar button for a menu rebuilds the whole
/// trailing toolbar group, and every glyph in it — heart and eye included —
/// blanked for around 100ms. A control that never changes kind can't do
/// that; its contents can change freely, because a menu builds them only
/// when it opens.
///
/// Adding to a playlist is always available — Jellyfin's `POST /Playlists`
/// has no permission gate (see `JellyfinAPIClient.createPlaylist`) and a user
/// with no editable playlist can still create one — so the menu is never
/// empty.
///
/// Inside the menu, a single target is a flat row and two or three become a
/// submenu naming each entity, as `HeroActionButtons` collapses its menu on a
/// Movie page.
///
/// ## Permissions
///
/// Deletion is gated on `MediaItem.canDelete`, the server's per-item verdict
/// rather than anything derived locally — see `BaseItemDto.canDelete` for why
/// that matters and `JellyfinAPIClient.deleteItem` for what happens when the
/// gate is wrong. The Delete row is absent when it's false, rather than a
/// disabled row advertising a permission the user doesn't have. Adding to a playlist
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

    /// Always the one `ellipsis` overflow, whatever is available inside it —
    /// see "Which control gets drawn" on this type.
    private var control: some View {
        Menu {
            addToPlaylistMenuContent
            if !deletableTargets.isEmpty {
                // Destructive action last and visually separated, per iOS
                // convention, and what stands between a mis-tap on "Add to
                // Playlist" and one on "Delete".
                Divider()
                deleteMenuContent
            }
        } label: {
            HeroToolbarGlyph(systemName: "ellipsis", isPending: isPending)
        }
        .neutralToolbarItem()
        // Plain "More": the actions are the menu's rows, which VoiceOver
        // reads on opening it.
        .accessibilityLabel(String(localized: "More Actions"))
        .accessibilityIdentifier(A11yID.AssetDetail.moreButton)
    }

    // MARK: - Delete

    /// The delete action as rows inside the overflow menu: a lone target is a
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
            return target.numberedEpisodeName
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
