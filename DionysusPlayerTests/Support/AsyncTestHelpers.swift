import Foundation

struct TestTimedOut: Error, CustomStringConvertible {
    let description = "Condition never became true within the timeout"
}

/// Polls `condition` until it's true or `timeout` elapses, throwing if it
/// never does. For asserting on state that updates asynchronously — a
/// debounced search, a detached `Task` — without hardcoding a sleep long
/// enough to (hopefully) never flake.
///
/// `@MainActor`: every call site is a `@MainActor` ViewModel test checking
/// `@MainActor`-isolated state (e.g. `engine.seekedTimes`). Without this,
/// Swift 6 flags the closure argument as an unsafe cross-actor "send" —
/// isolating this function to match its callers is the fix, not `@Sendable`.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw TestTimedOut() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
