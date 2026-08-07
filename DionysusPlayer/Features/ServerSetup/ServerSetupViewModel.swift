import Foundation
import Observation

@MainActor
@Observable
final class ServerSetupViewModel {
    var address: String = ""
    var useHTTPS = false
    private(set) var isTesting = false
    private(set) var errorMessage: String?

    var canSubmit: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTesting
    }

    /// Parses the entered address and pings `/System/Info/Public` to
    /// confirm a Jellyfin server actually answers there.
    func testConnection() async -> ServerConfiguration? {
        errorMessage = nil
        guard var configuration = ServerConfiguration.parse(rawAddress: address, preferHTTPS: useHTTPS) else {
            errorMessage = String(localized: "Enter a valid server address, like 192.168.1.50:8096.")
            return nil
        }

        isTesting = true
        defer { isTesting = false }

        let client = JellyfinAPIClient(baseURL: configuration.baseURL)
        do {
            let info = try await client.publicSystemInfo()
            if let serverName = info.serverName, !serverName.isEmpty {
                configuration.name = serverName
            }
            return configuration
        } catch {
            errorMessage = String(localized: "Couldn't reach a Jellyfin server at that address. Check it and try again.")
            return nil
        }
    }
}
