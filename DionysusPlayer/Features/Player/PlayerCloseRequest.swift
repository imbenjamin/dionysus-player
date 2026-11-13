import Observation

/// Lets something other than the player close it the way its own close
/// button does (#406: a link that arrives mid-playback). Dismissing the
/// full-screen cover from outside would skip `PlayerView.close()`, which
/// reports the session's stop and position to the server.
@Observable
@MainActor
final class PlayerCloseRequest {
    static let shared = PlayerCloseRequest()

    /// How many players are on screen (one in practice).
    private(set) var openPlayers = 0
    /// Bumped to ask every open player to close.
    private(set) var token = 0

    var isPlayerUp: Bool { openPlayers > 0 }

    func playerAppeared() { openPlayers += 1 }

    func playerDisappeared() { openPlayers = max(0, openPlayers - 1) }

    func closeAll() { token += 1 }
}
