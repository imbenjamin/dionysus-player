import XCTest
@testable import Dionysus

/// `ToastCenter` is a process-wide singleton, so every test here resets it
/// afterwards — a leaked toast would otherwise show up in whatever runs next.
@MainActor
final class ToastCenterTests: XCTestCase {
    override func tearDown() async throws {
        ToastCenter.shared.reset()
        try await super.tearDown()
    }

    func test_post_makesTheToastCurrent() {
        ToastCenter.shared.post(Toast(message: "Added to \"Weeknights\""))

        XCTAssertEqual(ToastCenter.shared.current?.message, "Added to \"Weeknights\"")
    }

    /// Replaces rather than queues. Two confirmations in quick succession
    /// means the second is the one that matters, and a queue would make the
    /// user wait out a message about something they've already moved on
    /// from.
    func test_post_replacesAnEarlierToastRatherThanQueueingBehindIt() {
        ToastCenter.shared.post(Toast(message: "First"))
        ToastCenter.shared.post(Toast(message: "Second"))

        XCTAssertEqual(ToastCenter.shared.current?.message, "Second")
    }

    func test_dismiss_clearsImmediately() {
        ToastCenter.shared.post(Toast(message: "Added"))
        ToastCenter.shared.dismiss()

        XCTAssertNil(ToastCenter.shared.current)
    }

    /// The auto-dismiss actually fires. Deliberately waits the real
    /// `visibleDuration` rather than injecting a clock: this is a two-line
    /// `Task.sleep`, and a fake clock would be more machinery than the
    /// behaviour it verifies.
    func test_aToastClearsItselfAfterItsVisibleDuration() async throws {
        ToastCenter.shared.post(Toast(message: "Added"))
        XCTAssertNotNil(ToastCenter.shared.current)

        try await Task.sleep(for: ToastCenter.visibleDuration + .milliseconds(500))

        XCTAssertNil(ToastCenter.shared.current, "A toast must not linger past its own duration.")
    }

    /// The replacement's timer is the one that counts — a second post must
    /// not inherit the first's already-elapsed countdown and vanish early.
    func test_replacingAToastRestartsTheCountdown() async throws {
        ToastCenter.shared.post(Toast(message: "First"))
        try await Task.sleep(for: ToastCenter.visibleDuration - .milliseconds(500))
        ToastCenter.shared.post(Toast(message: "Second"))

        // Past the *first* toast's deadline, comfortably short of the
        // second's.
        try await Task.sleep(for: .milliseconds(1000))

        XCTAssertEqual(ToastCenter.shared.current?.message, "Second")
    }
}
