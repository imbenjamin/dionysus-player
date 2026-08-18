import XCTest
@testable import Dionysus

@MainActor
final class ConnectivityMonitorTests: XCTestCase {
    override func tearDown() {
        ConnectivityMonitor.shared.reset()
        super.tearDown()
    }

    func test_reportFailureThenSuccess_updatesIsOffline() {
        let monitor = ConnectivityMonitor.shared
        XCTAssertFalse(monitor.isOffline)

        monitor.reportFailure()
        XCTAssertTrue(monitor.isOffline)

        monitor.reportSuccess()
        XCTAssertFalse(monitor.isOffline)
    }

    /// The set of `URLError` codes that mean "couldn't reach the server at
    /// all" — matched against `JellyfinAPIClient.sendRaw`'s catch clause.
    func test_indicatesOffline_transportFailureCodes_areTrue() {
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed
        ]
        for code in offlineCodes {
            XCTAssertTrue(URLError(code).indicatesOffline, "\(code) should indicate offline")
        }
    }

    /// `.cancelled` means the request was abandoned (e.g. the user
    /// navigated away), not an outage — must never route to the offline
    /// screen. Anything implying a response was actually received doesn't
    /// even reach `URLError` at all (it becomes `JellyfinAPIError.http`/
    /// `.decoding` instead), so `.cancelled` is the one code most important
    /// to confirm is excluded here.
    func test_indicatesOffline_cancelled_isFalse() {
        XCTAssertFalse(URLError(.cancelled).indicatesOffline)
    }
}
