import XCTest
@testable import Dionysus

@MainActor
final class LibraryAvailabilityTests: XCTestCase {
    override func tearDown() async throws {
        LibraryAvailability.shared.reset()
        try await super.tearDown()
    }

    func test_update_changesState() {
        let availability = LibraryAvailability.shared
        XCTAssertEqual(availability.state, .loading, "Nothing has loaded yet")

        availability.update(.available)
        XCTAssertEqual(availability.state, .available)

        availability.update(.unavailable)
        XCTAssertEqual(availability.state, .unavailable)
    }

    /// `SearchView`'s "Try Again" button calls this without needing a
    /// reference to `HomeViewModel` itself — see the type's own doc
    /// comment.
    func test_retryAction_invokesWhateverWasSet() {
        let availability = LibraryAvailability.shared
        var retried = false
        availability.retryAction = { retried = true }

        availability.retryAction?()

        XCTAssertTrue(retried)
    }

    func test_reset_restoresDefaults() {
        let availability = LibraryAvailability.shared
        availability.update(.available)
        availability.retryAction = {}

        availability.reset()

        XCTAssertEqual(availability.state, .loading)
        XCTAssertNil(availability.retryAction)
    }
}
