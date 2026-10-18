import XCTest
@testable import Dionysus

@MainActor
final class ManualAudioOffsetScheduler: AudioOffsetScheduling {
    private(set) var pending: (@MainActor () -> Void)?
    private(set) var scheduleCount = 0
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        scheduleCount += 1
        pending = action
    }
    func cancel() { pending = nil }
    func fire() { let action = pending; pending = nil; action?() }
}

@MainActor
final class AudioOffsetControllerTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.AudioOffsetControllerTests"
    private var defaults: UserDefaults!
    private var store: AudioOffsetStore!
    private var scheduler: ManualAudioOffsetScheduler!
    private var applied: [Int] = []

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = AudioOffsetStore(defaults: defaults)
        scheduler = ManualAudioOffsetScheduler()
        applied = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func make(itemID: String = "item-1") -> AudioOffsetController {
        let controller = AudioOffsetController(itemID: itemID, store: store, scheduler: scheduler) { [unowned self] in
            applied.append($0)
        }
        controller.isAvailable = true
        return controller
    }

    func test_untouched_followsTheGlobal() {
        store.globalOffsetMilliseconds = 60
        let controller = make()
        XCTAssertEqual(controller.milliseconds, 60)
        XCTAssertFalse(controller.hasTitleOffset)
        XCTAssertEqual(controller.loadSeconds, 0.06, accuracy: 0.0001)
    }

    func test_titleOffset_winsOverTheGlobal() {
        store.globalOffsetMilliseconds = 60
        store.setOffset(-20, forItem: "item-1")
        XCTAssertEqual(make().milliseconds, -20)
    }

    func test_stepThisTitle_startsFromTheGlobal_andSavesTheTitle() {
        store.globalOffsetMilliseconds = 60
        let controller = make()
        controller.step(by: 1)
        XCTAssertEqual(controller.milliseconds, 70)
        XCTAssertEqual(store.offset(forItem: "item-1"), 70)
        XCTAssertEqual(store.globalOffsetMilliseconds, 60, "The global is untouched")
        XCTAssertTrue(controller.hasTitleOffset)
    }

    func test_stepAllTitles_changesTheGlobal() {
        let controller = make()
        controller.setScope(.allTitles)
        controller.step(by: -2)
        XCTAssertEqual(controller.milliseconds, -20)
        XCTAssertEqual(store.globalOffsetMilliseconds, -20)
        XCTAssertNil(store.offset(forItem: "item-1"))
    }

    func test_switchingToAllTitles_clearsTheTitleOffset() {
        store.globalOffsetMilliseconds = 30
        store.setOffset(90, forItem: "item-1")
        let controller = make()
        controller.setScope(.allTitles)
        XCTAssertNil(store.offset(forItem: "item-1"))
        XCTAssertEqual(controller.milliseconds, 30)
        scheduler.fire()
        XCTAssertEqual(applied, [30], "The value in effect changed, so it is applied")
    }

    func test_switchingToThisTitle_writesNothing() {
        let controller = make()
        controller.setScope(.allTitles)
        controller.setScope(.thisTitle)
        XCTAssertNil(store.offset(forItem: "item-1"))
        XCTAssertNil(scheduler.pending, "Nothing changed, nothing to apply")
    }

    func test_reset_removesTheTitleOffset() {
        store.globalOffsetMilliseconds = 30
        store.setOffset(90, forItem: "item-1")
        let controller = make()
        controller.resetToGlobal()
        XCTAssertNil(store.offset(forItem: "item-1"))
        XCTAssertEqual(controller.milliseconds, 30)
        XCTAssertEqual(controller.scope, .thisTitle)
    }

    func test_aBurstOfSteps_appliesOnce_afterTheSettle() {
        let controller = make()
        controller.step(by: 1)
        controller.step(by: 1)
        controller.step(by: 1)
        XCTAssertEqual(applied, [], "Nothing until the settle")
        scheduler.fire()
        XCTAssertEqual(applied, [30])
    }

    /// Review Focus 1.
    func test_flush_appliesTheLatestValue() {
        let controller = make()
        controller.step(by: 1)
        controller.step(by: 1)
        controller.flush()
        XCTAssertEqual(applied, [20])
        XCTAssertNil(scheduler.pending)
        controller.flush()
        XCTAssertEqual(applied, [20], "A second flush has nothing to apply")
    }

    /// Review Focus 3.
    func test_stepAtTheLimit_isIgnored() {
        store.setOffset(500, forItem: "item-1")
        let controller = make()
        XCTAssertFalse(controller.canIncrease)
        XCTAssertTrue(controller.canDecrease)
        controller.step(by: 1)
        XCTAssertEqual(controller.milliseconds, 500)
        XCTAssertNil(scheduler.pending)
    }

    func test_unavailable_savesButNeverApplies() {
        let controller = make()
        controller.isAvailable = false
        controller.step(by: 1)
        XCTAssertEqual(store.offset(forItem: "item-1"), 10)
        controller.flush()
        XCTAssertEqual(applied, [])
    }

    func test_panelDidOpen_resetsTheScope() {
        let controller = make()
        controller.setScope(.allTitles)
        controller.panelDidOpen()
        XCTAssertEqual(controller.scope, .thisTitle)
    }

    func test_cancelPending_dropsTheEngineCall_butKeepsTheSavedValue() {
        let controller = make()
        controller.step(by: 1)
        controller.cancelPending()
        controller.flush()
        XCTAssertEqual(applied, [])
        XCTAssertEqual(store.offset(forItem: "item-1"), 10)
    }

    func test_settleDelay_is750ms() {
        XCTAssertEqual(AudioOffsetController.settleDelay, .milliseconds(750))
    }
}
