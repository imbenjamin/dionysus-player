import Foundation
import Observation

/// Whether the configured Jellyfin server is reachable at all, as distinct from
/// a valid response carrying an HTTP error status. Written only by
/// `JellyfinAPIClient.sendRaw(_:)`, the choke point every call funnels through:
/// a transport-level failure reports failure, and any real `HTTPURLResponse`
/// reports success.
///
/// A plain singleton, referenced directly in view bodies rather than through
/// `Environment`; Observation still tracks it.
@MainActor
@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private(set) var isOffline = false

    private init() {}

    func reportFailure() {
        // `@Observable` fires on every assignment, equal or not. This runs on
        // every failed request app-wide, so an unconditional write would
        // recompute the body of every screen reading `isOffline`, for nothing.
        guard !isOffline else { return }
        isOffline = true
    }

    func reportSuccess() {
        // As `reportFailure()`, for the far commoner success path: this runs on
        // every successful request, including the 10s playback heartbeat.
        guard isOffline else { return }
        isOffline = false
    }

    /// Test-only reset; `private(set)` blocks assignment even under
    /// `@testable import`.
    func reset() {
        isOffline = false
    }
}

extension URLError {
    /// Transport-level failures meaning the server wasn't reached. Excludes
    /// `.cancelled`, which is an abandoned request rather than an outage, and
    /// anything implying a response arrived — those surface as
    /// `JellyfinAPIError.http`/`.decoding` and are not offline.
    var indicatesOffline: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed:
            true
        default:
            false
        }
    }
}
