import XCTest
@testable import Dionysus

/// The shared driver for the input model's test files: `state`, `context`
/// and `now`, plus press and tick helpers. `now` advances 0.1s per input
/// unless a test says otherwise, the way the host's 10 Hz tick does.
protocol TVPlayerInputModelHarness: AnyObject {
    var state: TVPlayerInputState { get set }
    var context: TVPlayerContext { get set }
    var now: TimeInterval { get set }
}

extension TVPlayerInputModelHarness {
    /// A 90-minute title playing at 1:40, four chapters, two audio tracks and
    /// three subtitle tracks: the shape of the UI-test fixture movie.
    static var standardContext: TVPlayerContext {
        TVPlayerContext(
            playback: .playing, currentTime: 100, duration: 5400,
            chapterStarts: [0, 1350, 2700, 4050],
            audioTrackIDs: [0, 1], selectedAudioIndex: 0,
            subtitleTrackIDs: [0, 1, 2]
        )
    }

    @discardableResult
    func send(_ input: TVRemoteInput, after seconds: TimeInterval = 0.1) -> [TVPlayerCommand] {
        now += seconds
        return TVPlayerInputModel.reduce(&state, input, context: context, now: now)
    }

    /// Down and up within the hold threshold: a press.
    @discardableResult
    func press(_ direction: TVDirection) -> [TVPlayerCommand] {
        send(.arrowDown(direction))
        return send(.arrowUp(direction))
    }

    /// Ticks at 10 Hz for `seconds`, returning every command they produced.
    @discardableResult
    func tick(for seconds: TimeInterval) -> [TVPlayerCommand] {
        var commands: [TVPlayerCommand] = []
        let end = now + seconds
        while now < end - 0.0001 { commands += send(.tick) }
        return commands
    }
}
