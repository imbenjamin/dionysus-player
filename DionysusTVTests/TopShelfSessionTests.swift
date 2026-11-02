import XCTest
@testable import Dionysus

/// The Top Shelf extension can't see the current Apple TV profile's keychain
/// (spike, M6), so the app mirrors the last-used session into the keychain
/// every profile shares.
final class TopShelfSessionTests: XCTestCase {
    private let server = ServerConfiguration(name: "JF", baseURL: URL(string: "http://jf.local")!)

    private func credentials(token: String? = "tok", userID: String? = "u1", serverID: String? = "http://jf.local") -> StoredCredentials {
        StoredCredentials(username: "ben", password: "", accessToken: token, userID: userID, serverID: serverID)
    }

    override func tearDown() {
        TopShelfSessionMirror.write(nil)
        DeviceIdentity.adopt(deviceID: nil, deviceName: nil)
        super.tearDown()
    }

    func test_make_carriesWhatTheExtensionNeeds() throws {
        let session = try XCTUnwrap(TopShelfSession.make(server: server, credentials: credentials(), deviceID: "dev", deviceName: "Bedroom"))
        XCTAssertEqual(session.serverURL, server.baseURL)
        XCTAssertEqual(session.serverID, server.id)
        XCTAssertEqual(session.userID, "u1")
        XCTAssertEqual(session.accessToken, "tok")
        XCTAssertEqual(session.deviceID, "dev")
        XCTAssertEqual(session.deviceName, "Bedroom")
    }

    func test_make_isNil_withoutAServerTokenOrUser() {
        XCTAssertNil(TopShelfSession.make(server: nil, credentials: credentials(), deviceID: "d", deviceName: "n"))
        XCTAssertNil(TopShelfSession.make(server: server, credentials: nil, deviceID: "d", deviceName: "n"))
        XCTAssertNil(TopShelfSession.make(server: server, credentials: credentials(token: nil), deviceID: "d", deviceName: "n"))
        XCTAssertNil(TopShelfSession.make(server: server, credentials: credentials(token: ""), deviceID: "d", deviceName: "n"))
        XCTAssertNil(TopShelfSession.make(server: server, credentials: credentials(userID: nil), deviceID: "d", deviceName: "n"))
    }

    func test_make_isNil_forCredentialsFromAnotherServer() {
        XCTAssertNil(TopShelfSession.make(server: server, credentials: credentials(serverID: "http://elsewhere"), deviceID: "d", deviceName: "n"))
    }

    func test_mirror_roundTrips_andNilDeletes() throws {
        let session = try XCTUnwrap(TopShelfSession.make(server: server, credentials: credentials(), deviceID: "d", deviceName: "n"))
        TopShelfSessionMirror.write(session)
        XCTAssertEqual(TopShelfSessionMirror.read(), session)
        TopShelfSessionMirror.write(nil)
        XCTAssertNil(TopShelfSessionMirror.read())
    }

    func test_adopt_replacesTheIdentityTheHeaderSends() {
        DeviceIdentity.adopt(deviceID: "app-device", deviceName: "Bedroom")
        let header = JellyfinAuthorization.headerValue(token: nil)
        XCTAssertTrue(header.contains("DeviceId=\"app-device\""))
        XCTAssertTrue(header.contains("Device=\"Bedroom\""))
    }
}
