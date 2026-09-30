import XCTest

/// The Apple TV app's icon and Top Shelf images. tvOS can't use the iOS
/// app's Icon Composer `dionysus.icon` (actool compiles no tvOS icon from
/// it), so they're a brand-assets set of their own; the test host is the app,
/// so its Info.plist shows whether actool found them.
final class TVAppIconTests: XCTestCase {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    func test_appHasAnIcon() {
        let icons = info["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"]
        XCTAssertNotNil(primary, "No app icon: the Apple TV home screen shows a blank tile")
    }

    /// Required for App Store submission even without a Top Shelf extension.
    func test_appHasTopShelfImages() {
        let topShelf = info["TVTopShelfImage"] as? [String: Any]
        XCTAssertNotNil(topShelf?["TVTopShelfPrimaryImage"])
        XCTAssertNotNil(topShelf?["TVTopShelfPrimaryImageWide"])
    }
}
