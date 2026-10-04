#if DEBUG
import Foundation

/// Stands in for `LANServerDiscovery` under the UI-test harness, answering with
/// the stub server so a journey can scan, pick the result, and land on Login
/// through `UITestStubURLProtocol` — never probing the real network the runner
/// happens to be on.
///
/// Answers twice: over plain HTTP, and over an HTTPS address whose certificate
/// the stub always rejects, for the insecure-fallback journey.
struct UITestServerDiscovery: ServerDiscovering {
    func discoverServers() -> AsyncThrowingStream<DiscoveredServer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(DiscoveredServer(
                    id: UITestFixtureIdentity.discoveredServerID,
                    name: UITestFixtureIdentity.serverName,
                    address: UITestConfiguration.stubServerURL
                ))
                // `.slowScan`: one server found, the scan still running long
                // past any assertion — what the "Still searching…" indicator
                // is for.
                if UITestConfiguration.scenario == .slowScan {
                    try? await Task.sleep(for: .seconds(120))
                }
                continuation.yield(DiscoveredServer(
                    id: UITestFixtureIdentity.serverSystemID,
                    name: UITestFixtureIdentity.discoveredHTTPSServerName,
                    address: URL(string: UITestFixtureIdentity.discoveredHTTPSServerAddress)!
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
