import Foundation
import Observation

/// Drives one Quick Connect sign-in: asks the server for a code, polls until
/// another client approves it, then hands the approved secret to `signIn`.
///
/// One `run` is one code. `QuickConnectView` calls it from `.task(id:)`, so
/// dismissing the sheet cancels the poll and "Get New Code" starts a fresh
/// `run` rather than this type restarting itself.
@MainActor
@Observable
final class QuickConnectViewModel {
    enum State: Equatable {
        case requesting
        case waiting(code: String)
        /// Approved; exchanging the secret for a session.
        case authorizing
        /// The server forgot the code — 10 minutes after it was issued.
        case expired
        case failed(String)
    }

    private(set) var state: State = .requesting

    private let client: JellyfinAPIClient
    private let pollInterval: Duration
    /// Consecutive failed polls tolerated before giving up. A single dropped
    /// request mid-wait shouldn't throw away a code the user may be typing
    /// on another device right now.
    private let maxConsecutivePollFailures: Int

    init(client: JellyfinAPIClient, pollInterval: Duration = .seconds(5), maxConsecutivePollFailures: Int = 3) {
        self.client = client
        self.pollInterval = pollInterval
        self.maxConsecutivePollFailures = maxConsecutivePollFailures
    }

    func run(signIn: (_ secret: String) async throws -> Void) async {
        state = .requesting
        let request: QuickConnectResult
        do {
            request = try await client.initiateQuickConnect()
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(String(localized: "Couldn't get a Quick Connect code from the server."))
            return
        }
        state = .waiting(code: request.code)

        var consecutiveFailures = 0
        poll: while true {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return // Cancelled: the sheet went away.
            }
            do {
                let current = try await client.quickConnectState(secret: request.secret)
                consecutiveFailures = 0
                if current.authenticated { break poll }
            } catch JellyfinAPIError.http(status: 404, message: _) {
                state = .expired
                return
            } catch {
                guard !Task.isCancelled else { return }
                consecutiveFailures += 1
                if consecutiveFailures >= maxConsecutivePollFailures {
                    state = .failed(String(localized: "Lost contact with the server while waiting for approval."))
                    return
                }
            }
        }

        state = .authorizing
        do {
            try await signIn(request.secret)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(String(localized: "The code was approved, but signing in failed. Try again."))
        }
    }

    /// The code spelled out digit by digit for VoiceOver, which otherwise
    /// reads "482913" as a six-figure number.
    static func spokenCode(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }
}
