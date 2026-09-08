import Foundation
import Observation

/// One selectable row in `AddToPlaylistSheet` — a playlist the signed-in user
/// is allowed to add items to.
///
/// Deliberately not `MediaItem`: the picker renders a name and nothing else,
/// and `JellyfinAPIClient.editablePlaylists` fetches these with `fields: ""`
/// for exactly that reason, so a `MediaItem` here would be a view-facing model
/// whose artwork, user data and media sources are all knowingly empty. This
/// still keeps the "DTOs don't reach views" rule the rest of `Core/Models`
/// follows — it's just a much smaller view-facing model than `MediaItem`.
struct PlaylistChoice: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    /// Whether this playlist already holds *everything* the current target
    /// would add — which is what disables its row.
    ///
    /// All, not any: a show whose episodes are only partly in a playlist is
    /// still worth offering, since the user can top it up. That does mean
    /// re-adding the episodes already there (Jellyfin permits duplicates and
    /// its own web client does the same), which is the lesser of the two
    /// wrongs — the alternative is disabling a row that could still usefully
    /// be tapped.
    var alreadyContainsTarget: Bool = false
}

/// Backs `AddToPlaylistSheet`: lists the playlists this user may edit, and
/// performs the two ways of adding `target` to one (an existing playlist, or
/// a newly created one).
///
/// Constructed with an already-resolved `client`/`userID` rather than reaching
/// into `AppState`, per the feature-module convention (see
/// `HomeViewModel.init`). Scoped to a single `target` for its lifetime — the
/// sheet is presented per-target via `.sheet(item:)`, so a new target means a
/// new view model rather than a mutable one that could drift from the
/// confirmation copy already on screen.
@MainActor
@Observable
final class AddToPlaylistViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The movie/show/season/episode being added. Read by the sheet for its
    /// confirmation copy as well as by `add`/`create` for the id to send.
    let target: MediaItem

    private let client: JellyfinAPIClient
    private let userID: String

    private(set) var loadState: LoadState = .idle
    private(set) var playlists: [PlaylistChoice] = []
    /// Blocks the picker's rows while a request is in flight, so a double tap
    /// can't send the same add twice — Jellyfin has no idempotency on
    /// `POST /Playlists/{id}/Items` and would happily append the item again.
    private(set) var isSubmitting = false

    /// Every item id this target actually resolves to server-side: just the
    /// target itself for a movie or episode, and each episode beneath it for
    /// a show or season (Jellyfin expands folder-shaped items — see
    /// `JellyfinAPIClient.addItemsToPlaylist`).
    ///
    /// Resolved once in `load()` and used for two things: deciding which
    /// destination rows are already full, and counting the confirmation's
    /// "Add 6 Episodes". Empty until the load finishes, or if the episode
    /// fetch fails — both of which the readers below treat as "unknown"
    /// rather than "none".
    private(set) var constituentItemIDs: [String] = []

    init(client: JellyfinAPIClient, userID: String, target: MediaItem) {
        self.client = client
        self.userID = userID
        self.target = target
    }

    // MARK: - Loading

    func load() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            // Both fetches are needed before the list can render a correct
            // enabled/disabled state, so they run concurrently rather than
            // one after the other — the picker is a modal the user is
            // waiting on.
            async let editableResult = client.editablePlaylists(userID: userID)
            async let constituentsResult = resolveConstituentItemIDs()

            let editable = try await editableResult
            constituentItemIDs = await constituentsResult

            let required = Set(constituentItemIDs)
            playlists = editable.map { entry in
                PlaylistChoice(
                    id: entry.item.id,
                    name: entry.item.name,
                    // An unresolved target (empty `required`) never marks
                    // anything as already-added — better a redundant add
                    // than a row the user can't tap for a reason they can't
                    // see.
                    alreadyContainsTarget: !required.isEmpty
                        && required.isSubset(of: entry.memberItemIDs)
                )
            }
            loadState = .loaded
        } catch {
            // Only the playlist browse can land here; a single playlist's
            // permission or membership check failing is absorbed inside
            // `editablePlaylists`, and the episode fetch below fails soft.
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Fails soft to an empty array: not knowing which episodes a show
    /// contains costs the picker its already-added marks and its exact
    /// count, neither of which is worth failing the whole sheet over.
    private func resolveConstituentItemIDs() async -> [String] {
        switch target.kind {
        case .series:
            let result = try? await client.episodes(
                seriesID: target.id, userID: userID, fields: ""
            )
            return result?.items.map(\.id) ?? []
        case .season:
            guard let seriesID = target.seriesID else { return [] }
            let result = try? await client.episodes(
                seriesID: seriesID, seasonID: target.id, userID: userID, fields: ""
            )
            return result?.items.map(\.id) ?? []
        default:
            return [target.id]
        }
    }

    // MARK: - Adding

    func add(to playlistID: String) async throws {
        isSubmitting = true
        defer { isSubmitting = false }
        try await client.addItemsToPlaylist(
            playlistID: playlistID, itemIDs: [target.id], userID: userID
        )
    }

    /// Creates a playlist already containing `target`, in one request —
    /// Jellyfin's create endpoint seeds from `Ids`, so there's no
    /// create-then-add window in which a failure could leave an empty
    /// playlist behind.
    func create(named name: String, isPublic: Bool) async throws {
        isSubmitting = true
        defer { isSubmitting = false }
        _ = try await client.createPlaylist(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            itemIDs: [target.id],
            userID: userID,
            isPublic: isPublic
        )
    }

    // MARK: - Copy

    /// Whether adding `target` expands into more than one item server-side,
    /// which is what decides whether adding to an *existing* playlist stops
    /// to confirm.
    ///
    /// A single movie or episode is added straight away: it's one item, and
    /// removing it again is one long-press away in `PlaylistItemList`, so a
    /// confirmation would be exactly the kind of prompt-for-a-reversible-
    /// action the HIG argues against. A show or season is different in kind
    /// rather than degree — Jellyfin expands it into every episode beneath it
    /// (see `JellyfinAPIClient.addItemsToPlaylist`), so one tap can append
    /// dozens of entries, potentially to a playlist shared with other users,
    /// each of which would then have to be removed one at a time.
    var requiresConfirmation: Bool {
        switch target.kind {
        case .series, .season: return true
        default: return false
        }
    }

    /// How many items `target` will actually add. `nil` means "unknown", not
    /// "one" — the copy helpers below fall back to count-free phrasing
    /// rather than guessing.
    ///
    /// Prefers the episode list `load()` resolved over the server's
    /// `recursiveItemCount`: the former is the exact set of ids this add
    /// will expand into, while the latter is only populated when something
    /// asked for `Fields=RecursiveItemCount` and, on a Season, often isn't
    /// there at all. The fallback keeps the confirmation useful if that
    /// fetch failed.
    var expandedItemCount: Int? {
        guard requiresConfirmation else { return nil }
        if !constituentItemIDs.isEmpty { return constituentItemIDs.count }
        guard let count = target.episodeCount, count > 0 else { return nil }
        return count
    }

    /// The confirmation's own action title. Says what will happen and to how
    /// many things — "Add 6 Episodes" rather than a bare "Add", which on a
    /// dialog about a whole show is the one detail worth putting on the
    /// button itself.
    var addActionTitle: String {
        guard requiresConfirmation else { return String(localized: "Add") }
        guard let count = expandedItemCount else { return String(localized: "Add All Episodes") }
        return String(localized: "Add \(count) Episodes")
    }

    /// What the toast says once an add succeeds. Names the destination,
    /// since the sheet that named it has closed by the time this shows.
    func addedToastMessage(playlistName: String) -> String {
        guard requiresConfirmation else {
            return String(localized: "Added to \"\(playlistName)\"")
        }
        guard let count = expandedItemCount else {
            return String(localized: "Added all episodes to \"\(playlistName)\"")
        }
        return String(localized: "Added \(count) episodes to \"\(playlistName)\"")
    }

    /// The create flow's own toast. Distinct copy from
    /// `addedToastMessage(playlistName:)` because "Created" is the part the
    /// user needs confirmed — a playlist that didn't exist a moment ago now
    /// does, and is findable in their library.
    func createdToastMessage(playlistName: String) -> String {
        String(localized: "Created \"\(playlistName)\" and added this")
    }

    /// Body copy for "add to an existing playlist", used only when
    /// `requiresConfirmation` is true.
    ///
    /// The show and season variants are separate literals with the noun
    /// written into each rather than one string interpolating "show"/"season"
    /// as a value — the same localization rule `AssetActionsButton
    /// .confirmationMessage(for:)` documents: the rendered English is
    /// identical, but a substituted bare noun can't be translated correctly
    /// into languages whose surrounding words inflect for it.
    func addConfirmationMessage(playlistName: String) -> String {
        switch target.kind {
        case .season:
            if let count = expandedItemCount {
                return String(localized: "This adds all \(count) episodes of this season to \"\(playlistName)\".")
            }
            return String(localized: "This adds every episode of this season to \"\(playlistName)\".")
        default:
            if let count = expandedItemCount {
                return String(localized: "This adds all \(count) episodes of this show to \"\(playlistName)\".")
            }
            return String(localized: "This adds every episode of this show to \"\(playlistName)\".")
        }
    }

    /// Body copy for "create a playlist and add to it". Unlike
    /// `addConfirmationMessage(playlistName:)` this is shown for every kind of
    /// target, including a single movie — creating is a new, named, persistent
    /// thing rather than an edit to something that already exists.
    func createConfirmationMessage(playlistName: String) -> String {
        switch target.kind {
        case .series:
            if let count = expandedItemCount {
                return String(localized: "This creates \"\(playlistName)\" and adds all \(count) episodes of this show to it.")
            }
            return String(localized: "This creates \"\(playlistName)\" and adds every episode of this show to it.")
        case .season:
            if let count = expandedItemCount {
                return String(localized: "This creates \"\(playlistName)\" and adds all \(count) episodes of this season to it.")
            }
            return String(localized: "This creates \"\(playlistName)\" and adds every episode of this season to it.")
        default:
            return String(localized: "This creates \"\(playlistName)\" and adds \"\(target.name)\" to it.")
        }
    }
}
