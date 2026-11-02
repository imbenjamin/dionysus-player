import XCTest
@testable import Dionysus

/// Keeping the Top Shelf current (M6): the app mirrors its session for the
/// extension whenever it settles signed in or out, and asks tvOS to reload the
/// shelf after what changes it.
@MainActor
final class TopShelfRefreshTests: XCTestCase {
    @MainActor private final class Counter { var value = 0 }
    private let counter = Counter()
    private var calls: Int { counter.value }
    private var saved: (@MainActor () -> Void)!
    private let server = ServerConfiguration(name: "JF", baseURL: URL(string: "http://jf.local")!)
    private let credentials = StoredCredentials(username: "ben", password: "", accessToken: "tok", userID: "u1", serverID: "http://jf.local")
    private let suiteName = "com.dionysusplayer.tests.TopShelfRefreshTests"

    override func setUp() {
        super.setUp()
        saved = TopShelfRefresh.notify
        TopShelfRefresh.notify = { [counter] in counter.value += 1 }
        TopShelfSessionMirror.write(nil)
    }

    override func tearDown() {
        TopShelfRefresh.notify = saved
        TopShelfSessionMirror.write(nil)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_signedIn_mirrorsTheSession_andRefreshes() {
        TopShelfRefresh.appStateChanged(isRestoringSession: false, isSignedIn: true, server: server, credentials: credentials)
        XCTAssertEqual(TopShelfSessionMirror.read()?.userID, "u1")
        XCTAssertEqual(TopShelfSessionMirror.read()?.deviceID, DeviceIdentity.deviceID, "The app's own device id travels with the token")
        XCTAssertEqual(calls, 1)
    }

    func test_signedOut_deletesTheMirror_andRefreshes() {
        TopShelfRefresh.appStateChanged(isRestoringSession: false, isSignedIn: true, server: server, credentials: credentials)
        TopShelfRefresh.appStateChanged(isRestoringSession: false, isSignedIn: false, server: server, credentials: nil)
        XCTAssertNil(TopShelfSessionMirror.read(), "A signed-out app leaves the shelf nothing to fetch with")
        XCTAssertEqual(calls, 2)
    }

    func test_whileRestoring_leavesTheMirrorAlone() {
        TopShelfRefresh.appStateChanged(isRestoringSession: false, isSignedIn: true, server: server, credentials: credentials)
        TopShelfRefresh.appStateChanged(isRestoringSession: true, isSignedIn: false, server: server, credentials: nil)
        XCTAssertNotNil(TopShelfSessionMirror.read(), "Launch doesn't blank the shelf before the session is back")
        XCTAssertEqual(calls, 1)
    }

    /// `end()` reports an outcome the first time only, whether or not
    /// playback started, so the shelf is asked once per session.
    func test_endingASession_refreshesTheShelfOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: FakePlaybackEngine(),
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults)
        )
        let session = TVPlaybackSession(viewModel: viewModel)
        session.end()
        session.end()
        XCTAssertEqual(calls, 1)
    }
}
