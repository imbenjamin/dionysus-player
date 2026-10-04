import XCTest
@testable import Dionysus

final class ServerDiscoveryTests: XCTestCase {
    // MARK: parseReply

    /// Verbatim from a Jellyfin 10.11 server answering a unicast probe.
    func test_parseReply_realServerReply_keepsIDNameAndFullAddressWithBasePath() throws {
        let reply = Data(#"{"Address":"http://192.168.0.222:8096/flix","Id":"98cad501f802442388eb7e59009021f8","Name":"SavareseHillFlix","EndpointAddress":null}"#.utf8)

        let server = try XCTUnwrap(JellyfinDiscoveryProtocol.parseReply(reply))

        XCTAssertEqual(server.id, "98cad501f802442388eb7e59009021f8")
        XCTAssertEqual(server.name, "SavareseHillFlix")
        XCTAssertEqual(server.address.absoluteString, "http://192.168.0.222:8096/flix")
        XCTAssertEqual(server.displayAddress, "192.168.0.222:8096/flix")
    }

    func test_parseReply_blankName_fallsBackToHost() throws {
        let reply = Data(#"{"Address":"https://media.local:8920/","Id":"abc","Name":"  "}"#.utf8)

        let server = try XCTUnwrap(JellyfinDiscoveryProtocol.parseReply(reply))

        XCTAssertEqual(server.name, "media.local")
        XCTAssertEqual(server.displayAddress, "media.local:8920")
    }

    func test_parseReply_rejectsAnythingThatIsNotAUsableReply() {
        let rejected = [
            "who is JellyfinServer?",
            #"{"Address":"http://10.0.0.2:8096","Name":"No Id"}"#,
            #"{"Address":"http://10.0.0.2:8096","Id":"","Name":"Empty Id"}"#,
            #"{"Address":"smb://10.0.0.2","Id":"x","Name":"Wrong scheme"}"#,
            #"{"Address":"not a url","Id":"x","Name":"No host"}"#,
        ]
        for text in rejected {
            XCTAssertNil(JellyfinDiscoveryProtocol.parseReply(Data(text.utf8)), text)
        }
    }

    // MARK: LocalSubnet

    private func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

    /// Keeps the device's own address — see `hostAddresses`' doc comment.
    func test_hostAddresses_slash24_excludesNetworkAndBroadcastButNotSelf() {
        let subnet = LocalSubnet(address: ip(192, 168, 0, 20), netmask: ip(255, 255, 255, 0))

        let hosts = subnet.hostAddresses

        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(hosts.first, ip(192, 168, 0, 1))
        XCTAssertEqual(hosts.last, ip(192, 168, 0, 254))
        XCTAssertTrue(hosts.contains(ip(192, 168, 0, 20)))
    }

    func test_hostAddresses_slash22_isScannedWhole() {
        let subnet = LocalSubnet(address: ip(10, 0, 5, 9), netmask: ip(255, 255, 252, 0))

        let hosts = subnet.hostAddresses

        XCTAssertEqual(hosts.count, 1022)
        XCTAssertEqual(hosts.first, ip(10, 0, 4, 1))
        XCTAssertEqual(hosts.last, ip(10, 0, 7, 254))
    }

    /// A /16 would be 65,534 probes; it's narrowed to the device's own /24.
    func test_hostAddresses_widerThanSlash22_narrowsToOwnSlash24() {
        let subnet = LocalSubnet(address: ip(172, 16, 42, 7), netmask: ip(255, 255, 0, 0))

        let hosts = subnet.hostAddresses

        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(hosts.first, ip(172, 16, 42, 1))
        XCTAssertEqual(hosts.last, ip(172, 16, 42, 254))
    }

    func test_hostAddresses_pointToPoint_isEmpty() {
        XCTAssertTrue(LocalSubnet(address: ip(10, 0, 0, 1), netmask: ip(255, 255, 255, 254)).hostAddresses.isEmpty)
        XCTAssertTrue(LocalSubnet(address: ip(10, 0, 0, 1), netmask: ip(255, 255, 255, 255)).hostAddresses.isEmpty)
    }

    // MARK: ScanSchedule

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func test_schedule_acceptedProbe_listensForTheWindowThenFinishes() {
        var schedule = ScanSchedule(start: t0, timing: .init())
        XCTAssertTrue(schedule.isRoundDue(at: t0))

        schedule.roundSent(accepted: true, at: t0)

        XCTAssertFalse(schedule.isRoundDue(at: at(0.5)))
        XCTAssertTrue(schedule.isRoundDue(at: at(1)))
        XCTAssertFalse(schedule.isFinished(at: at(2.9), appIsActive: true))
        XCTAssertTrue(schedule.isFinished(at: at(3), appIsActive: true))
        XCTAssertFalse(schedule.accessLooksDenied)
    }

    func test_schedule_everyProbeRefused_givesUpAfterTheGraceAsDenied() {
        var schedule = ScanSchedule(start: t0, timing: .init())
        for second in 0..<8 {
            schedule.roundSent(accepted: false, at: at(TimeInterval(second)))
        }

        XCTAssertFalse(schedule.isFinished(at: at(7.9), appIsActive: true))
        XCTAssertTrue(schedule.isFinished(at: at(8), appIsActive: true))
        XCTAssertTrue(schedule.accessLooksDenied)
    }

    /// Seen on device: under the Local Network prompt, probes are accepted and
    /// silently dropped, so the listen window used to run out behind the
    /// prompt and the scan ended empty. The app is inactive while it's up.
    func test_schedule_neverFinishesWhileTheAppIsInactive() {
        var schedule = ScanSchedule(start: t0, timing: .init())
        schedule.roundSent(accepted: true, at: t0)

        XCTAssertFalse(schedule.isFinished(at: at(30), appIsActive: false))
    }

    /// Answering the prompt reactivates the app; the scan starts over — probe
    /// now, and a full grace period — rather than inheriting a window that
    /// expired behind the prompt.
    func test_schedule_reactivation_startsOver() {
        var schedule = ScanSchedule(start: t0, timing: .init())
        schedule.roundSent(accepted: true, at: t0)

        schedule.appBecameActive(at: at(20))

        XCTAssertTrue(schedule.isRoundDue(at: at(20)))
        XCTAssertTrue(schedule.accessLooksDenied, "Nothing accepted since reactivating yet.")
        XCTAssertFalse(schedule.isFinished(at: at(27.9), appIsActive: true))

        schedule.roundSent(accepted: true, at: at(20))
        XCTAssertFalse(schedule.isFinished(at: at(22.9), appIsActive: true))
        XCTAssertTrue(schedule.isFinished(at: at(23), appIsActive: true))
    }

    /// "Don't Allow": every probe after reactivation is refused.
    func test_schedule_reactivationThenRefused_endsDenied() {
        var schedule = ScanSchedule(start: t0, timing: .init())
        schedule.roundSent(accepted: true, at: t0)
        schedule.appBecameActive(at: at(10))
        schedule.roundSent(accepted: false, at: at(10))

        XCTAssertTrue(schedule.isFinished(at: at(18), appIsActive: true))
        XCTAssertTrue(schedule.accessLooksDenied)
    }

    func test_schedule_hardStopAppliesEvenWhileInactive() {
        let schedule = ScanSchedule(start: t0, timing: .init())

        XCTAssertFalse(schedule.isFinished(at: at(59.9), appIsActive: false))
        XCTAssertTrue(schedule.isFinished(at: at(60), appIsActive: false))
    }
}
