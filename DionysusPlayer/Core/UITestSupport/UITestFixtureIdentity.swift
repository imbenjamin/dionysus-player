import Foundation

/// The ids and names of the stub catalogue, with no dependency on the app's
/// DTOs.
///
/// Split out of `UITestFixtureLibrary`, which builds real `BaseItemDto` values
/// and so compiles only inside the app, purely so this half can compile into the
/// UI test bundle too. That bundle launches the app as a separate process and
/// doesn't link the app module, so without this the tests would carry their own
/// copy of every id — two lists that agree until one changes.
///
/// Not `#if DEBUG`-gated like the rest of `UITestSupport`, so these constants do
/// ship. Gating them works today, since a UI test bundle is always built Debug,
/// but would fail confusingly against Release. What ships is a dozen inert
/// strings no app code path reads.
enum UITestFixtureIdentity {
    static let moviesLibraryID = "lib-movies"
    static let showsLibraryID = "lib-tvshows"
    static let boxSetsLibraryID = "lib-boxsets"
    static let playlistsLibraryID = "lib-playlists"

    static let seriesID = "series-northern-lights"
    static let seriesName = "Northern Lights"

    /// The catalogue's series has two seasons of three episodes each.
    static func episodeID(season: Int, episode: Int) -> String { "episode-s\(season)e\(episode)" }
    static let boxSetID = "boxset-aurora-trilogy"
    static let playlistID = "playlist-weekend"

    /// A second editable playlist, so the picker has more than one row and a
    /// test can add to a playlist other than the one it inspects.
    static let secondPlaylistID = "playlist-late-night"
    static let secondPlaylistName = "Late Night"

    /// A playlist the stub answers 404 "permissions not found" for, as Jellyfin
    /// does when the user neither owns it nor is shared on it. Visible in the
    /// catalogue but never in the picker, which is how a test asserts
    /// `editablePlaylists`' filter does something.
    static let readOnlyPlaylistID = "playlist-shared-readonly"
    static let readOnlyPlaylistName = "Shared With Me"

    /// The `playlistItemId` the stub stamps on the `index`-th item added during a
    /// run, 1-based, so a journey can address a row it just created:
    /// `PlaylistItemList` keys rows on it, and the item id isn't enough since
    /// the same item can appear twice. Here rather than in the stub because the
    /// test bundle can't see it.
    static func addedPlaylistEntryID(playlistID: String, index: Int) -> String {
        "added-entry-\(playlistID)-\(index)"
    }

    /// The id the stub assigns to the `index`-th playlist created in a run,
    /// 1-based.
    static func createdPlaylistID(index: Int) -> String { "playlist-created-\(index)" }

    /// The catalogue holds twelve movies, `movie-01` through `movie-12`.
    static func movieID(_ index: Int) -> String { String(format: "movie-%02d", index) }
    static let movieCount = 12

    /// The item playback tests use: unwatched and favourited, so the detail page
    /// shows Play rather than Resume and the favourite control starts on.
    static let primaryMovieID = movieID(1)
    static let primaryMovieTitle = "The Quiet Ascent"

    /// The one part-watched movie, so the detail page shows Resume with a
    /// Restart button beside it.
    static let partWatchedMovieID = movieID(2)

    static let serverName = "Dionysus UI Test Server"
    static let username = "uitester"
    static let password = "uitest-password"
    static let serverAddress = "http://dionysus-uitest.invalid"
}
