import Foundation
import Observation

@MainActor
@Observable
final class ServerSetupViewModel {
    /// Where a local-network scan (`scanForServers()`) has got to.
    enum ScanState: Equatable {
        case idle
        case scanning
        /// Ran to completion; `discoveredServers` holds whatever answered,
        /// possibly nothing.
        case finished
        case failed(ServerDiscoveryError)
    }

    var address: String = ""
    var useHTTPS = false
    private(set) var isTesting = false
    private(set) var errorMessage: String?

    private(set) var scanState: ScanState = .idle
    /// In the order they answered. Kept across a rescan until it finishes, so
    /// a row the user is reaching for doesn't vanish under their finger.
    private(set) var discoveredServers: [DiscoveredServer] = []
    /// The discovered server a connection is being tested against, so its row
    /// can show progress rather than the Connect button.
    private(set) var connectingServerID: DiscoveredServer.ID?

    private let discovery: any ServerDiscovering
    private var scanTask: Task<Void, Never>?
    private let activity: any AppActivityObserving
    private let isLocalNetworkDenied: @Sendable (URLError) -> Bool

    /// `activity` and `isLocalNetworkDenied` exist to be replaced in tests:
    /// neither the Local Network prompt nor the error it causes can be
    /// produced outside a device.
    init(
        discovery: any ServerDiscovering = ServerSetupViewModel.defaultDiscovery(),
        activity: any AppActivityObserving = AppActivityMonitor(),
        isLocalNetworkDenied: @escaping @Sendable (URLError) -> Bool = { $0.isLocalNetworkDenied }
    ) {
        self.discovery = discovery
        self.activity = activity
        self.isLocalNetworkDenied = isLocalNetworkDenied
    }

    /// The real scanner, or under the UI-test harness one that answers with
    /// the stub server instead of probing whatever network the runner is on.
    static func defaultDiscovery() -> any ServerDiscovering {
        #if DEBUG
        if UITestConfiguration.isActive { return UITestServerDiscovery() }
        #endif
        return LANServerDiscovery()
    }

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

    /// Starts a scan the view doesn't have to hold on to; a no-op while one is
    /// already running. `cancelScan()` stops it.
    func startScan() {
        guard scanState != .scanning else { return }
        scanTask = Task { await scanForServers() }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Scans the local network, publishing servers as they answer.
    ///
    /// A rescan starts from an empty list once the first answer arrives or the
    /// scan ends, not immediately — see `discoveredServers`.
    func scanForServers() async {
        guard scanState != .scanning else { return }
        scanState = .scanning
        var found: [DiscoveredServer] = []
        do {
            for try await server in discovery.discoverServers() {
                found.append(server)
                discoveredServers = found
            }
            discoveredServers = found
            scanState = Task.isCancelled ? .idle : .finished
        } catch let error as ServerDiscoveryError {
            discoveredServers = found
            scanState = .failed(error)
        } catch {
            discoveredServers = found
            scanState = .failed(.noLocalNetwork)
        }
    }

    /// Fills the address in from a discovered server and tests it exactly as
    /// though it had been typed, so the same checks (and the server's own
    /// reported name) apply either way — and a server that answered the probe
    /// but not HTTP leaves its address in the field to be corrected by hand.
    ///
    /// One exception: an `https://` server whose certificate fails validation
    /// gets a second look over plain HTTP. Nothing connects from there without
    /// the user's say-so — see `insecureFallbackOffer` and `httpPortRequest`.
    func connect(to server: DiscoveredServer) async -> ServerConfiguration? {
        guard !isTesting else { return nil }
        cancelScan()
        address = server.address.absoluteString
        syncHTTPSToggle(withAddress: address)
        connectingServerID = server.id
        defer { connectingServerID = nil }

        errorMessage = nil
        guard let configuration = ServerConfiguration.parse(rawAddress: address, preferHTTPS: useHTTPS) else {
            errorMessage = String(localized: "Enter a valid server address, like 192.168.1.50:8096.")
            return nil
        }

        isTesting = true
        defer { isTesting = false }

        do {
            return try await probeAcrossLocalNetworkPrompt(configuration).configuration
        } catch let error as URLError where error.isCertificateFailure && server.address.scheme?.lowercased() == "https" {
            // Stays up behind the alerts, and explains the screen if the user
            // cancels out of them.
            errorMessage = String(localized: "\(server.name)'s security certificate isn't valid for \(server.address.host ?? server.displayAddress).")
            if await offerInsecureFallback(for: server, port: Self.defaultHTTPPort) == false {
                httpPortRequest = HTTPPortRequest(server: server, problem: nil)
            }
            return nil
        } catch is LocalNetworkAccessDenied {
            errorMessage = Self.localNetworkDeniedMessage
            return nil
        } catch {
            errorMessage = String(localized: "Couldn't reach a Jellyfin server at that address. Check it and try again.")
            return nil
        }
    }

    // MARK: Insecure fallback
    //
    // A server with HTTPS on but no published URL advertises
    // `https://<LAN IP>:<HTTPS port>`, while its certificate is issued for a
    // domain name, or is self-signed — so the advertised address can never
    // validate, even though the server usually still serves HTTP too.
    //
    // Nothing a signed-out client can read says which port that is: the
    // discovery reply carries one address, and the ports live only in the
    // server's network configuration, which needs an admin session. Both ports
    // are configurable, so Jellyfin's default HTTP port is tried first as a
    // guess, and the user is asked for the port if nothing answers there.
    // Whichever port is used, the server there must report the `SystemId` the
    // discovery reply did — without that check, anything else answering on
    // that port would be offered as "this server".

    /// A discovered HTTPS server that can't be verified but does answer over
    /// plain HTTP, waiting on the user's say-so.
    struct InsecureFallbackOffer: Equatable {
        let server: DiscoveredServer
        /// Already tested — accepting it needs no further request.
        let configuration: ServerConfiguration

        /// The HTTP address without its scheme, as the alert shows it.
        var httpDisplayAddress: String {
            DiscoveredServer(id: server.id, name: server.name, address: configuration.baseURL).displayAddress
        }
    }

    /// Nothing answered over HTTP on the port tried last, so the view asks the
    /// user which port the server's HTTP is on.
    struct HTTPPortRequest: Equatable {
        let server: DiscoveredServer
        /// Why the previous answer didn't work, if there was one.
        let problem: String?
    }

    private(set) var insecureFallbackOffer: InsecureFallbackOffer?
    private(set) var httpPortRequest: HTTPPortRequest?

    /// Jellyfin's `NetworkConfiguration.DefaultHttpPort` — only ever a first
    /// guess, see above.
    nonisolated static let defaultHTTPPort = 8096

    /// The port as typed, if it is one.
    static func parsePort(_ text: String) -> Int? {
        guard let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65_535).contains(port) else { return nil }
        return port
    }

    /// Tries the port the user gave in answer to `request`: on success the
    /// confirmation is offered, otherwise the port is asked for again with
    /// the reason.
    ///
    /// Takes the request rather than reading `httpPortRequest`, which the
    /// alert's dismissal has already cleared by the time this runs.
    func tryHTTPPort(_ text: String, for request: HTTPPortRequest) async {
        guard !isTesting else { return }
        httpPortRequest = nil
        guard let port = Self.parsePort(text) else {
            httpPortRequest = HTTPPortRequest(server: request.server, problem: String(localized: "Enter a port number between 1 and 65535."))
            return
        }

        connectingServerID = request.server.id
        isTesting = true
        defer {
            isTesting = false
            connectingServerID = nil
        }
        if await offerInsecureFallback(for: request.server, port: port) == false {
            httpPortRequest = HTTPPortRequest(server: request.server, problem: String(localized: "\(request.server.name) didn't answer over HTTP on port \(String(port))."))
        }
    }

    func cancelHTTPPortRequest() {
        httpPortRequest = nil
    }

    /// The user chose to connect unencrypted. Returns the tested HTTP
    /// configuration, and leaves its address in the field to match.
    func acceptInsecureFallback() -> ServerConfiguration? {
        guard let offer = insecureFallbackOffer else { return nil }
        insecureFallbackOffer = nil
        errorMessage = nil
        address = offer.configuration.baseURL.absoluteString
        syncHTTPSToggle(withAddress: address)
        return offer.configuration
    }

    /// Cancelled — the certificate error stays on screen, so the user can pick
    /// another server or type an address.
    func declineInsecureFallback() {
        insecureFallbackOffer = nil
    }

    /// Sets `insecureFallbackOffer` if `server` answers over HTTP on `port`.
    private func offerInsecureFallback(for server: DiscoveredServer, port: Int) async -> Bool {
        guard let configuration = await Self.insecureFallback(for: server, port: port) else { return false }
        insecureFallbackOffer = InsecureFallbackOffer(server: server, configuration: configuration)
        return true
    }

    /// The same server over HTTP on `port` — same host and base path — if it
    /// answers there *and* reports the `SystemId` the discovery reply did.
    static func insecureFallback(for server: DiscoveredServer, port: Int) async -> ServerConfiguration? {
        guard var components = URLComponents(url: server.address, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "http"
        components.port = port
        guard let url = components.url, let host = url.host else { return nil }

        guard let result = try? await probe(ServerConfiguration(name: host, baseURL: url)),
              result.info.id == server.id,
              result.configuration.baseURL.scheme == "http"
        else { return nil }
        return result.configuration
    }

    /// Parses the entered address and pings `/System/Info/Public` to
    /// confirm a Jellyfin server actually answers there.
    func testConnection() async -> ServerConfiguration? {
        errorMessage = nil
        guard let configuration = ServerConfiguration.parse(rawAddress: address, preferHTTPS: useHTTPS) else {
            errorMessage = String(localized: "Enter a valid server address, like 192.168.1.50:8096.")
            return nil
        }

        isTesting = true
        defer { isTesting = false }

        do {
            return try await probeAcrossLocalNetworkPrompt(configuration).configuration
        } catch is LocalNetworkAccessDenied {
            errorMessage = Self.localNetworkDeniedMessage
            return nil
        } catch {
            errorMessage = String(localized: "Couldn't reach a Jellyfin server at that address. Check it and try again.")
            return nil
        }
    }

    // MARK: Local Network prompt
    //
    // The first request to a LAN address is what makes iOS ask for Local
    // Network access, and that request fails at once, behind the prompt, while
    // the user is still reading it — so without this, connecting to a typed
    // LAN address the first time reported "Couldn't reach a Jellyfin server"
    // over a prompt the user hadn't answered yet (seen on device). A scan
    // normally raises the prompt first, but typing an address skips the scan.

    /// Local Network access is off, and no prompt came up to change that.
    struct LocalNetworkAccessDenied: Error {}

    static var localNetworkDeniedMessage: String {
        String(localized: "Dionysus doesn't have access to your local network. Turn on Local Network for Dionysus in Settings, then try again.")
    }

    /// `probe`, but a failure caused by the Local Network prompt waits for the
    /// user to answer it and tries once more.
    ///
    /// Two signals, since neither is guaranteed: the error's own
    /// local-network-denied reason (`URLError.isLocalNetworkDenied`), and the
    /// app going inactive during the attempt, which a system prompt causes.
    /// The error can arrive a moment before the app resigns, so a
    /// denied-looking error with no prompt yet gets a second to see one.
    private func probeAcrossLocalNetworkPrompt(_ configuration: ServerConfiguration) async throws -> (configuration: ServerConfiguration, info: PublicSystemInfo) {
        let deactivationsBefore = activity.state.deactivations
        let promptAppeared = { [activity] in activity.state.deactivations != deactivationsBefore }
        do {
            return try await Self.probe(configuration)
        } catch let error as URLError where isLocalNetworkDenied(error) || promptAppeared() {
            if !promptAppeared() {
                _ = await activity.wait(until: { $0.deactivations != deactivationsBefore }, timeout: .seconds(1))
            }
            // Denied with no prompt: the user turned it off earlier.
            guard promptAppeared() else { throw LocalNetworkAccessDenied() }

            _ = await activity.wait(until: { $0.isActive }, timeout: .seconds(60))
            do {
                return try await Self.probe(configuration)
            } catch let retryError as URLError where isLocalNetworkDenied(retryError) {
                // "Don't Allow".
                throw LocalNetworkAccessDenied()
            }
        }
    }

    /// Pings `/System/Info/Public` at `configuration`, returning it named after
    /// the server and with its scheme corrected to wherever the ping landed.
    private static func probe(_ configuration: ServerConfiguration) async throws -> (configuration: ServerConfiguration, info: PublicSystemInfo) {
        var configuration = configuration
        let client = JellyfinAPIClient(baseURL: configuration.baseURL)
        let info = try await client.publicSystemInfo()
        if let serverName = info.serverName, !serverName.isEmpty {
            configuration.name = serverName
        }
        // See `correctingScheme(usingLandedURL:)`'s doc comment — this
        // ping can succeed on the wrong scheme via a transparent
        // redirect, so trust where it actually landed over what was
        // assumed going in.
        configuration = configuration.correctingScheme(usingLandedURL: await client.lastResponseURL)
        return (configuration, info)
    }
}

private extension URLError {
    /// TLS failures a certificate issued for a different name, or a
    /// self-signed one, produce — not the transport failures
    /// (`cannotConnectToHost`, `timedOut`) that mean nothing answered at all.
    var isCertificateFailure: Bool {
        switch code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            true
        default:
            false
        }
    }
}
