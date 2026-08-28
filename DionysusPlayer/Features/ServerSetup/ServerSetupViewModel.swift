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

    /// Keeps `useHTTPS` truthful whenever the typed address itself already
    /// specifies a scheme — `ServerConfiguration.parse` always honors that
    /// scheme over `preferHTTPS` (see its doc comment), so without this the
    /// toggle could show "on" while a leftover/pasted `http://…` address
    /// silently connects over plain HTTP anyway. Call this from the
    /// address field's `.onChange`, not `didSet` on `address` itself — this
    /// codebase doesn't use property observers on `@Observable` state
    /// elsewhere, and `.onChange` keeps the sync visible at the view/call
    /// site instead of buried in the model.
    func syncHTTPSToggle(withAddress address: String) {
        guard let scheme = ServerConfiguration.explicitScheme(in: address),
              scheme == "http" || scheme == "https" else { return }
        useHTTPS = (scheme == "https")
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
            // See `correctingScheme(usingLandedURL:)`'s doc comment — this
            // ping can succeed on the wrong scheme via a transparent
            // redirect, so trust where it actually landed over what was
            // assumed going in.
            configuration = configuration.correctingScheme(usingLandedURL: await client.lastResponseURL)
            return configuration
        } catch {
            errorMessage = String(localized: "Couldn't reach a Jellyfin server at that address. Check it and try again.")
            return nil
        }
    }
}
