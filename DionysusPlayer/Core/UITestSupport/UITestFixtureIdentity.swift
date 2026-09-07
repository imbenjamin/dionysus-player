import Foundation

/// The ids and names of the stub catalogue, with no dependency on the app's
/// DTOs.
///
/// Split out of `UITestFixtureLibrary` (which builds real `BaseItemDto`
/// values, and so can only compile inside the app) purely so this half can
/// be compiled into `DionysusPlayerUITests` as well. A UI test bundle
/// launches the app as a separate process and does not link the app module,
/// so without this the tests would carry their own copy of every id — two
/// lists that agree only until one of them changes.
///
/// Not `#if DEBUG`-gated, unlike the rest of `UITestSupport` — so unlike the
/// harness, the stub and the fixture catalogue (all of which are verifiably
/// absent from a Release binary), these constants do ship. That is the
/// deliberate trade: gating them would work today, since a UI test bundle is
/// always built with the Debug configuration, but it would fail confusingly
/// for anyone who ever ran the tests against Release. What ships is a dozen
/// inert strings with no code path in the app that reads them.
enum UITestFixtureIdentity {
    static let moviesLibraryID = "lib-movies"
    static let showsLibraryID = "lib-tvshows"
    static let boxSetsLibraryID = "lib-boxsets"
    static let playlistsLibraryID = "lib-playlists"

    static let seriesID = "series-northern-lights"
    static let seriesName = "Northern Lights"
    static let boxSetID = "boxset-aurora-trilogy"
    static let playlistID = "playlist-weekend"

    /// The catalogue holds twelve movies, `movie-01` through `movie-12`.
    static func movieID(_ index: Int) -> String { String(format: "movie-%02d", index) }
    static let movieCount = 12

    /// `movie-01`, "The Quiet Ascent" — the item playback tests use. Unwatched
    /// and favourited, so the detail page shows Play (not Resume) and the
    /// favourite control starts in its "on" state.
    static let primaryMovieID = movieID(1)
    static let primaryMovieTitle = "The Quiet Ascent"

    /// `movie-02`, "Signal Fire" — the one part-watched movie, so the detail
    /// page shows Resume and a Restart button beside it.
    static let partWatchedMovieID = movieID(2)

    static let serverName = "Dionysus UI Test Server"
    static let username = "uitester"
    static let password = "uitest-password"
    static let serverAddress = "http://dionysus-uitest.invalid"
}
