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
    /// The Quick Connect code the stub issues for the `number`-th request of
    /// a run, 1-based, so a journey can tell a fresh code from an expired one.
    static func quickConnectCode(_ number: Int) -> String { String(format: "48291%d", number % 10) }

    /// Codes another device is "waiting on", for approving from the Account
    /// screen. The stub authorizes the first, answers the second as Jellyfin
    /// does an already-approved code (500), and any other code as unknown or
    /// expired (404).
    static let quickConnectApprovableCode = "246810"
    static let quickConnectUsedCode = "135790"

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

    /// The single cue in the stubbed ASS script
    /// (`UITestStubURLProtocol.assScript`). Lives here rather than beside the
    /// script because the stub is app-target-only, while this file is shared
    /// with the UI-test target — see `StyledSubtitleJourneyTests`.
    static let styledSubtitleCueText = "Styled subtitle fixture"

    /// The `\an8` cue in the same script, for the regression guard on
    /// top-aligned signs being pushed above the picture.
    static let styledSubtitleTopCueText = "Top aligned sign"

    /// The cue `PreviewPlaybackEngine` publishes for whichever subtitle track
    /// is selected — what `SubtitleOverlayView`'s own path paints, as opposed
    /// to libass. Deliberately distinct text from the styled cues above, so a
    /// test can tell the two renderers apart rather than inferring one from the
    /// other's absence.
    static let plainSubtitleCueText = "Plain subtitle fixture"

    /// A styled subtitle must never render this close to the top of the
    /// screen. Misplaced into the top letterbox bar it lands around y 9;
    /// correctly placed it sits at the top of the picture, which on the
    /// fixture's 2.4:1 video in portrait is past y 350.
    static let styledSubtitleMinimumTopY: Double = 150

    static let serverName = "Dionysus UI Test Server"
    /// The fixture user's id — the tile a journey taps on the sign-in screen.
    static let userID = "uitest-user-0001"
    static let username = "uitester"
    static let password = "uitest-password"
    static let serverAddress = "http://dionysus-uitest.invalid"

    /// A second user on the sign-in screen's public list, with no password:
    /// one tap signs in. The stub accepts this name with an empty password.
    static let passwordlessUserID = "uitest-user-guest"
    static let passwordlessUsername = "Guest"

    /// The stub server's login disclaimer, markup and all, as an admin might
    /// write it.
    static let loginDisclaimer = "A test server.<br/>Nothing here is real."

    /// The `SystemId` `UITestServerDiscovery` reports for the stub server, which
    /// is also the suffix of its result row's identifier.
    static let discoveredServerID = "uitest-discovered-server"

    /// The stub server's own `SystemId`, as `/System/Info/Public` reports it.
    static let serverSystemID = "uitest-server-0001"

    /// A second discovery result: the same stub server advertised over HTTPS,
    /// which `UITestStubURLProtocol` fails with a certificate error, so only
    /// the plain-HTTP fallback reaches it. Reported under `serverSystemID`, as
    /// a real server's reply and its `/System/Info/Public` agree.
    static let discoveredHTTPSServerAddress = "https://dionysus-uitest.invalid:8920"
    static let discoveredHTTPSServerName = "Dionysus UI Test Server (HTTPS)"
}
