import Foundation
import Observation

/// App-wide signal for "can we currently reach the configured Jellyfin
/// server at all" — distinct from a valid server response that happens to
/// carry an HTTP error status. The only writer is `JellyfinAPIClient
/// .sendRaw(_:)`, the single choke point every endpoint call funnels
/// through: a transport-level failure (no response at all) reports
/// failure, and reaching any real `HTTPURLResponse` (success or an HTTP
/// error status) reports success.
///
/// Follows the same plain-singleton convention as `DeviceTiltObserver
/// .shared`/`RemoteImageLoader.shared` — referenced directly in view
/// bodies rather than routed through SwiftUI's `Environment`, which
/// Observation still tracks correctly.
@MainActor
@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private(set) var isOffline = false

    private init() {}

    func reportFailure() {
        isOffline = true
    }

    func reportSuccess() {
        isOffline = false
    }

    /// Test-only reset — `private(set)` blocks direct assignment even from
    /// a `@testable import`, so tests need this instead.
    func reset() {
        isOffline = false
    }
}

extension URLError {
    /// True for transport-level failures that mean "couldn't reach the
    /// server at all" — deliberately excludes `.cancelled` (the request
    /// was abandoned, e.g. the user navigated away, not an outage) and
    /// anything implying a response was actually received (those surface
    /// as `JellyfinAPIError.http`/`.decoding` instead, which per spec
    /// should NOT be treated as offline).
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
