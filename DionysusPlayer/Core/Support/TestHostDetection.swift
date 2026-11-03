import Foundation

/// Whether this process is the app hosting an `.xctest` bundle (unit tests).
///
/// The unit-test host is the real app: SwiftUI builds `DionysusPlayerApp` /
/// `DionysusTVApp` and runs its `.task { appState.start() }`, whose requests
/// go out on `URLSession.shared`, where several tests register
/// `MockURLProtocol` process-wide. The host's requests could then reach
/// whichever test was running. Launch code that starts a session or touches
/// the network checks this and stands down.
///
/// UI tests launch the app as a separate process, which never gets
/// `XCTestConfigurationFilePath`, so they are unaffected.
enum TestHostDetection {
    static func isUnitTestHost(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    static var isUnitTestHost: Bool {
        isUnitTestHost(environment: ProcessInfo.processInfo.environment)
    }
}
