import Foundation
import Observation

@MainActor
@Observable
final class AssetDetailViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What `ShowDetailView`/`MovieDetailView` actually render as the page's
    /// hero/synopsis/metadata/Play button/tabs content. For a Movie (or a
    /// Series tapped directly), this is just the requested item. For a
    /// Season or Episode tapped directly (e.g. a deep link, or an episode
    /// from Home's Continue Watching rail), the *page* is still the Show's —
    /// see `seriesID`/`preselectedSeasonID` below — but `item` itself is
    /// only swapped to the Series' own item for a Season selection; an
    /// Episode selection keeps `item` as that episode, so its own overview/
    /// artwork/technical details/versions are what actually show, matching
    /// what other Jellyfin clients do when you deep-link straight to an
    /// episode. See `load()` for exactly which case does which.
    private(set) var item: MediaItem?
    /// The Show these seasons/episodes belong to — always set alongside
    /// `item` for a Series/Season/Episode load (never for a Movie). Distinct
    /// from `item.id`: `item` can be an Episode's own id while this is its
    /// parent Series' id, which is what `SeasonEpisodeList` and
    /// `showPlaybackEpisode`'s resolution actually need to scope their
    /// fetches.
    private(set) var seriesID: String?
    /// Which season `ShowDetailView`'s season picker should default to,
    /// rather than always the first — the tapped Season itself, or an
    /// Episode's parent season. `nil` for a Series tapped directly (falls
    /// back to the first season, the pre-existing default).
    private(set) var preselectedSeasonID: String?
    private(set) var seasons: [MediaItem] = []
    private(set) var similar: [MediaItem] = []
    private(set) var collections: [MediaItem] = []
    private(set) var loadState: LoadState = .idle

    /// For Show content only (`item.kind == .series`, i.e. a Series tapped
    /// directly or a Season swapped to its parent Series — see `item`'s doc
    /// comment): the specific episode `PlayResumeButtonRow` should target,
    /// resolved once as part of `load()` so the button can show a real
    /// "Play S2:E4"/"Resume S2:E4" label instead of a bare one. `nil` for
    /// Movie/Episode content (where `item` itself is already the thing to
    /// play — `ShowDetailView`'s episode-content branch never reads this),
    /// and briefly `nil` for Show content too until `load()` resolves it.
    ///
    /// Resolution differs by how the page was reached:
    /// - Season tapped directly (`preselectedSeasonID` set): the first
    ///   episode of *that* season specifically — a Season tap reads as
    ///   "start this season", not "continue the show overall".
    /// - Series tapped directly (`preselectedSeasonID` nil): Jellyfin's
    ///   NextUp, which already returns whichever's more relevant — an
    ///   in-progress episode if one exists (so this doubles as "the most
    ///   recently watched part-watched episode" without needing to hunt for
    ///   it across every season ourselves), else the next unwatched one —
    ///   falling back to the first episode of the first season when NextUp
    ///   has nothing at all (a never-started show).
    ///
    /// Either way, `PlayResumeButtonRow` decides Play-vs-Resume purely from
    /// *this resolved episode's own* watched state (via `effectiveItem` —
    /// see that property's doc comment), not any aggregate on the Series/
    /// Season item — which is what makes a Season tap correctly say
    /// "Resume" when its first episode happens to already be part-watched,
    /// rather than always blindly "Play".
    private(set) var showPlaybackEpisode: MediaItem?

    /// The id `refreshItem()` should re-fetch to keep `item` current —
    /// `itemID` itself for a Movie/Series/Episode load (where `item` is
    /// built straight from `itemID`'s own DTO), but the *Series'* id for a
    /// Season load, where `item` was swapped to the Series' DTO instead
    /// of the tapped Season's. Set alongside `item` in `load()`.
    private var displayedItemID: String?

    let itemID: String
    private let client: JellyfinAPIClient
    private let userID: String
    private let versionPreferenceStore: MediaVersionPreferenceStore

    /// `preloadedItem` — see `AppRoute.assetDetail`'s doc comment — seeds
    /// `item` immediately so the page has something to render (and a zoom
    /// transition something to land on) before `load()`'s network round
    /// trip resolves. It's necessarily partial (fetched via the rail's
    /// lighter `Fields` list, missing `MediaSources`/`People`), so `load()`
    /// still runs regardless and replaces it with the full item once ready.
    init(
        client: JellyfinAPIClient, userID: String, itemID: String, preloadedItem: MediaItem? = nil,
        versionPreferenceStore: MediaVersionPreferenceStore = MediaVersionPreferenceStore()
    ) {
        self.client = client
        self.userID = userID
        self.itemID = itemID
        self.item = preloadedItem
        self.versionPreferenceStore = versionPreferenceStore
    }

    /// The version `PlayResumeButtonRow` should silently continue with for a
    /// "Resume" tap on `playableItemID` — whatever was deliberately chosen
    /// the last time that item was started fresh (via the version-choice
    /// prompt), or `nil` to let `PlayerViewModel` fall back to the server's
    /// own default. See `MediaVersionPreferenceStore`'s doc comment for why
    /// this can't just come from the server.
    func preferredMediaSourceID(forPlayableItem playableItemID: String) -> String? {
        versionPreferenceStore.preferredMediaSourceID(forItem: playableItemID, userID: userID)
    }

    /// Records the version-choice prompt's answer so a later "Resume" (see
    /// `preferredMediaSourceID(forPlayableItem:)`) continues the same one.
    func setPreferredMediaSourceID(_ mediaSourceID: String, forPlayableItem playableItemID: String) {
        versionPreferenceStore.setPreferredMediaSourceID(mediaSourceID, forItem: playableItemID, userID: userID)
    }

    /// Guards on `loadState`, not `item` — a preloaded item already makes
    /// `item` non-nil before `load()` has ever run, which would otherwise
    /// make this look like a no-op-needed reload and skip fetching the full
    /// item (cast, technical details, similar/collections rails) entirely.
    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await load()
    }

    func load() async {
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            let dto = try await client.item(userID: userID, itemID: itemID)

            // See `item`/`seriesID`/`preselectedSeasonID`/`displayedItemID`'s
            // own doc comments for what each branch below is actually
            // establishing — this is the one place that decides it.
            switch dto.type {
            case .episode:
                item = MediaItem(dto: dto, images: images)
                displayedItemID = itemID
                seriesID = dto.seriesId
                preselectedSeasonID = dto.seasonId
            case .season:
                if let seriesID = dto.seriesId {
                    // The page's content is the *Show's* own item, not the
                    // Season's (a Season has no overview/artwork/media of
                    // its own worth showing) — so this is the one case
                    // where `displayedItemID` ends up different from
                    // `itemID`.
                    self.seriesID = seriesID
                    preselectedSeasonID = dto.id
                    let seriesDTO = try await client.item(userID: userID, itemID: seriesID)
                    item = MediaItem(dto: seriesDTO, images: images)
                    displayedItemID = seriesID
                    // `preselectedSeasonID` (just set, above) is what tells
                    // this it's resolving a Season tap's target, not a
                    // Series tap's — see `resolveShowPlaybackEpisode`.
                    await resolveShowPlaybackEpisode(seriesID: seriesID, images: images)
                } else {
                    // Shouldn't happen — degrades to showing the Season's
                    // own mostly-empty item rather than crashing.
                    item = MediaItem(dto: dto, images: images)
                    displayedItemID = itemID
                }
            default:
                // Series (the pre-existing path), or a Movie/BoxSet/
                // anything else — none of which have a `seriesID` at all
                // except Series itself, set just below.
                item = MediaItem(dto: dto, images: images)
                displayedItemID = itemID
                if dto.type == .series { seriesID = dto.id }
                preselectedSeasonID = nil
            }

            // Similar/collections are scoped to the Show for every
            // Series/Season/Episode case (an episode's own "similar items"
            // via the API is empty/meaningless) — falls back to `itemID`
            // only for a Movie, where there's no Show to scope to at all.
            let similarCollectionsID = seriesID ?? itemID
            async let similarResult = client.similarItems(itemID: similarCollectionsID, userID: userID)
            async let collectionsResult = client.collectionsContaining(itemID: similarCollectionsID, userID: userID)

            if let seriesID {
                let seasonsResult = try await client.seasons(seriesID: seriesID, userID: userID)
                seasons = seasonsResult.items.map { MediaItem(dto: $0, images: images) }
            }

            // Series tapped directly — see `showPlaybackEpisode`'s doc
            // comment. `dto.type == .series` (the *originally requested*
            // item's real kind), not `item?.kind`, since a Season load also
            // ends up with `item.kind == .series` after the swap above but
            // already resolved its own (season-scoped) target just above —
            // `resolveShowPlaybackEpisode` tells the two apart via
            // `preselectedSeasonID` (`nil` here, set for the Season case).
            if dto.type == .series, let seriesID {
                await resolveShowPlaybackEpisode(seriesID: seriesID, images: images)
            }

            similar = try await similarResult.items.map { MediaItem(dto: $0, images: images) }
            collections = try await collectionsResult.map { MediaItem(dto: $0, images: images) }

            loadState = .loaded
        } catch {
            loadState = .failed(
                (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't load this title.")
            )
        }
    }

    /// Switches this Show-content page's displayed content to `episodeID`
    /// in place — tapping the text area of an episode row in
    /// `SeasonEpisodeList` (as opposed to its play button, which plays that
    /// episode directly without changing what this page shows). Fetches the
    /// episode's *full* item (technical details/versions/cast — unlike the
    /// lighter list-fetch `SeasonEpisodeList` itself already has), then
    /// swaps `item`/`displayedItemID` to it — the exact same shape a direct
    /// Episode tap already produces (see `item`'s doc comment), so
    /// everything downstream (`PlayResumeButtonRow`'s `isEpisodeContent`
    /// branch, `DetailTabsView`, the episode list's own highlighted row)
    /// just follows `item` reactively with no special-casing needed here.
    /// Deliberately doesn't touch `seriesID`/`preselectedSeasonID`/
    /// `seasons` — the tapped episode is already within whichever season is
    /// currently being browsed, so none of those need to change.
    func selectEpisode(_ episodeID: String) async {
        guard let dto = try? await client.item(userID: userID, itemID: episodeID) else { return }
        let images = await client.makeImageURLBuilder()
        item = MediaItem(dto: dto, images: images)
        displayedItemID = episodeID
    }

    /// Re-fetches just the main item's DTO so the Play/Resume button and its
    /// progress bar reflect the latest server-side watch state (e.g. after
    /// returning from the player). Skips the sibling rails/seasons — they
    /// haven't meaningfully changed during one playback session.
    ///
    /// `PlayerViewModel.stop()` awaits the `/Sessions/Playing/Stopped` POST,
    /// but Jellyfin commits the userData write asynchronously after that
    /// response returns — and the commit latency varies. Rather than gamble
    /// on a fixed delay, this polls the item endpoint on a short schedule
    /// until the returned userData actually differs from what we had (which
    /// means the server has caught up), or we hit the last attempt.
    func refreshItem() async {
        // `displayedItemID`, not `itemID` — see that property's doc comment.
        // They're the same value except for a Season load, where `item` was
        // swapped to the Show's own DTO; re-fetching `itemID` there would
        // overwrite `item` with the tapped Season's DTO instead.
        guard let displayedItemID else { return }
        let previousTicks = item?.dto.userData?.playbackPositionTicks
        let previousPercentage = item?.dto.userData?.playedPercentage
        let previouslyPlayed = item?.dto.userData?.played
        let images = await client.makeImageURLBuilder()

        for delay in [0.25, 0.5, 1.0, 1.5] as [Double] {
            try? await Task.sleep(for: .seconds(delay))
            guard let dto = try? await client.item(userID: userID, itemID: displayedItemID) else { continue }
            item = MediaItem(dto: dto, images: images)
            if dto.userData?.playbackPositionTicks != previousTicks
                || dto.userData?.playedPercentage != previousPercentage
                || dto.userData?.played != previouslyPlayed {
                break
            }
        }

        // Show content's Play/Resume target can change after a playback
        // session — e.g. the previously-resolved episode just got fully
        // watched, so a Series-direct page's NextUp resolution should now
        // point at the following episode. Episode content
        // (`showPlaybackEpisode` always nil there) and a Movie (no
        // `seriesID` at all) both no-op via the guard below.
        if item?.kind == .series, let seriesID {
            await resolveShowPlaybackEpisode(seriesID: seriesID, images: images)
        }
    }

    /// Resolves `showPlaybackEpisode` — see that property's doc comment for
    /// exactly which episode each case picks. `preselectedSeasonID` being
    /// set is what tells this it's resolving a *Season* tap's target
    /// (scoped to that one season) rather than a *Series* tap's (NextUp,
    /// falling back to the first episode of the first season) — safe to
    /// rely on here because this is only ever called for Show content
    /// (`load()`'s `.season` case and its post-`seasons` `.series` case;
    /// `refreshItem()`'s `item?.kind == .series` guard), never for Episode
    /// content, where `preselectedSeasonID` is *also* set (to that
    /// episode's own season) but this function is simply never invoked.
    private func resolveShowPlaybackEpisode(seriesID: String, images: ImageURLBuilder) async {
        if let preselectedSeasonID {
            if let firstEpisodeDto = try? await client.episodes(
                seriesID: seriesID, seasonID: preselectedSeasonID, userID: userID
            ).items.first {
                showPlaybackEpisode = MediaItem(dto: firstEpisodeDto, images: images)
            }
        } else if let nextUpDto = try? await client.nextUp(userID: userID, seriesID: seriesID).items.first {
            showPlaybackEpisode = MediaItem(dto: nextUpDto, images: images)
        } else if let firstSeason = seasons.first,
                  let firstEpisodeDto = try? await client.episodes(
                      seriesID: seriesID, seasonID: firstSeason.id, userID: userID
                  ).items.first {
            showPlaybackEpisode = MediaItem(dto: firstEpisodeDto, images: images)
        }
    }
}
