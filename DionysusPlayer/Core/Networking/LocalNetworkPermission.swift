import Foundation
import Network
import UIKit

/// Whether the app is active, and how often it has changed, as far as
/// `AppActivityMonitor` has seen.
///
/// The only signal there is that iOS's Local Network prompt is up: there is
/// no API to ask for that permission or read its state, and a system prompt
/// makes the app inactive. Counting transitions rather than only reading
/// `isActive` means a brief spell between two reads still registers.
struct AppActivityState: Equatable, Sendable {
    var isActive = true
    var activations = 0
    var deactivations = 0
}

protocol AppActivityObserving: AnyObject, Sendable {
    var state: AppActivityState { get }
}

extension AppActivityObserving {
    /// Polls until `condition` holds or `timeout` passes; whether it held.
    func wait(until condition: @Sendable (AppActivityState) -> Bool, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition(state) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition(state)
    }
}

/// Tracks the app's active state from `UIApplication`'s notifications,
/// readable from any thread — the discovery scan reads it from its background
/// queue. Assumes active at creation: it's created by a screen on show, or by
/// a scan started from a tap.
final class AppActivityMonitor: AppActivityObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var current = AppActivityState()
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.update {
                    $0.isActive = false
                    $0.deactivations += 1
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.update {
                    $0.isActive = true
                    $0.activations += 1
                }
            },
        ]
        lock.withLock { self.observers = observers }
    }

    deinit { stop() }

    var state: AppActivityState { lock.withLock { current } }

    func stop() {
        let removed = lock.withLock {
            defer { observers = [] }
            return observers
        }
        removed.forEach(NotificationCenter.default.removeObserver)
    }

    private func update(_ change: (inout AppActivityState) -> Void) {
        lock.withLock { change(&current) }
    }
}

extension URLError {
    /// The request never left the device because Local Network access is off —
    /// or not yet granted: the first LAN request is what raises the prompt, and
    /// it fails this way while the prompt is still up.
    ///
    /// Read from the network path `URLSession` attaches to the error. The key
    /// is undocumented, so a miss just means the caller falls back to its
    /// generic handling; it never produces a false positive.
    var isLocalNetworkDenied: Bool {
        guard let path = errorUserInfo["_NSURLErrorNWPathKey"] as? nw_path_t else { return false }
        return nw_path_get_unsatisfied_reason(path) == nw_path_unsatisfied_reason_local_network_denied
    }
}
