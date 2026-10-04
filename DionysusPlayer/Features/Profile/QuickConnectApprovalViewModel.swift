import Foundation
import Observation

/// Approves another device's Quick Connect code from this, already signed-in,
/// one — the other half of `QuickConnectViewModel`'s flow.
///
/// There is no "approve iPad (Swiftfin)?" step: the server tells only the
/// requesting device which device and app asked, so typing the code and
/// pressing Authorize is the confirmation, as in Jellyfin's own web client.
@MainActor
@Observable
final class QuickConnectApprovalViewModel {
    enum State: Equatable {
        case entering
        case submitting
        case approved
        case failed(String)
    }

    /// Jellyfin's codes are always this many digits (`QuickConnectManager
    /// .CodeLength`), so anything else can't be one.
    static let codeLength = 6

    private(set) var code = ""
    private(set) var state: State = .entering

    /// Shown in the success message: the other device signs in as this user.
    let userName: String
    let serverName: String
    private let client: JellyfinAPIClient

    init(client: JellyfinAPIClient, userName: String, serverName: String) {
        self.client = client
        self.userName = userName
        self.serverName = serverName
    }

    var canSubmit: Bool {
        code.count == Self.codeLength && state != .submitting && state != .approved
    }

    /// Keeps digits only, up to `codeLength` — pasted text with spaces or a
    /// label ("Code: 482 913") still lands as the code. Editing after a
    /// failure clears it, so the message never describes a code that's no
    /// longer in the field.
    func setCode(_ raw: String) {
        code = String(raw.filter(\.isASCII).filter(\.isNumber).prefix(Self.codeLength))
        if case .failed = state { state = .entering }
    }

    func authorize() async {
        guard canSubmit else { return }
        state = .submitting
        do {
            let approved = try await client.authorizeQuickConnect(code: code)
            state = approved ? .approved : .failed(Self.genericFailure)
        } catch {
            state = .failed(await message(for: error))
        }
    }

    private func message(for error: Error) async -> String {
        switch error {
        case JellyfinAPIError.http(status: 404, message: _):
            return String(localized: "That code didn't work. Check it matches the one on the other device — codes expire after 10 minutes.")
        case JellyfinAPIError.http(status: 500, message: _):
            // Jellyfin's answer for an already-approved code, but also for
            // anything else that goes wrong server-side: say both.
            return String(localized: "The server couldn't authorize this code. It may already have been used — try getting a new code on the other device.")
        case JellyfinAPIError.notPermitted, JellyfinAPIError.notAuthenticated:
            // A 401 means either Quick Connect was turned off since this
            // screen opened or this session is no longer valid. Asking
            // tells them apart.
            switch try? await client.quickConnectEnabled() {
            case false?:
                return String(localized: "Quick Connect has been turned off on this server.")
            case true?:
                return String(localized: "Your session has expired. Sign out and back in to use Quick Connect.")
            case nil:
                return Self.genericFailure
            }
        case let urlError as URLError where urlError.indicatesOffline:
            return String(localized: "Couldn't reach \(serverName).")
        default:
            return Self.genericFailure
        }
    }

    private static var genericFailure: String {
        String(localized: "Something went wrong authorizing this code. Try again.")
    }

    /// Whether to offer Quick Connect at all. `false` on any failure to ask,
    /// so an unreachable server never shows a row that could only fail —
    /// the same rule as the login screen's button.
    static func isAvailable(on client: JellyfinAPIClient) async -> Bool {
        (try? await client.quickConnectEnabled()) ?? false
    }
}
