import XCTest
@testable import Dionysus

@MainActor
final class TVTransportChromeTests: XCTestCase {
    /// The fade starts when playback does. A load longer than the visible
    /// duration must not use up the title's time on screen before a frame shows.
    func test_staysVisible_whileLoading() async throws {
        let chrome = TVTransportChrome(visibleDuration: .milliseconds(50))
        chrome.playbackStateChanged(from: .idle, to: .loading)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(chrome.isVisible)
    }

    func test_fades_afterPlaybackStarts() async throws {
        let chrome = TVTransportChrome(visibleDuration: .milliseconds(50))
        chrome.playbackStateChanged(from: .idle, to: .loading)
        chrome.playbackStateChanged(from: .loading, to: .playing)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(chrome.isVisible)
    }

    /// Only leaving `.loading` starts the fade; a pause keeps the transport up
    /// through the overlay, not by resetting the timer here.
    func test_otherTransitions_leaveTheTimerAlone() async throws {
        let chrome = TVTransportChrome(visibleDuration: .milliseconds(50))
        chrome.playbackStateChanged(from: .playing, to: .paused)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(chrome.isVisible)
    }
}
