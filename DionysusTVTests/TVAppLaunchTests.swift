import XCTest
@testable import Dionysus

/// Checks on what the tvOS app sets up at launch. The test host runs
/// `DionysusTVApp.init`, so these see exactly what a real launch leaves behind.
final class TVAppLaunchTests: XCTestCase {
    /// Jellyfin lists this Apple TV (Dashboard › Devices, and each session)
    /// under the name sent with every request. Unprimed, that name is the
    /// "Unknown Device" placeholder: the iOS app primes it from its
    /// `AppDelegate`, which the tvOS app doesn't have.
    @MainActor
    func test_launch_primesTheDeviceName() {
        XCTAssertNotEqual(DeviceIdentity.deviceName, "Unknown Device")
        XCTAssertEqual(DeviceIdentity.deviceName, UIDevice.current.name)
    }

    /// The household's server is shared by every Apple TV user; see
    /// `ServerSessionStore.ServerLocation`.
    func test_serverConfiguration_isSharedAcrossAppleTVUsers() {
        XCTAssertEqual(ServerSessionStore.ServerLocation.platformDefault, .sharedKeychain)
    }

    /// The audio offset corrects the Apple TV's audio chain, so every Apple TV
    /// user shares it (spec: "per device, shared by every user on it"), and
    /// tvOS's `UserDefaults` is per user; see `AudioOffsetStore`.
    func test_audioOffset_isSharedAcrossAppleTVUsers() {
        XCTAssertTrue(AudioOffsetStore.platformStorage is SharedKeychainAudioOffsetStorage)
    }

    /// tvOS's user switching can launch the app as another Apple TV user, so
    /// accounts are remembered here; see `ServerSessionStore.RememberedAccounts`.
    func test_accounts_areRememberedOnAppleTV() {
        XCTAssertTrue(ServerSessionStore.RememberedAccounts.platformDefault)
    }
}
