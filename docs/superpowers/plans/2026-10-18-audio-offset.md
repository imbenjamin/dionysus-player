# Audio Offset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A global audio offset (Profile → Playback) and a per-title override (the player's Audio panel), on iOS and Apple TV, applied through AetherEngine and hidden where it can't apply.

**Architecture:** A device-wide `AudioOffsetStore` holds the global value and a per-item map. An `AudioOffsetController` (owned by `PlayerViewModel` as `viewModel.audioOffset`) resolves the value in effect, handles the This Title / All Titles scope, Reset and a 0.75 s settle, and hands values to the engine. `PlaybackEngine` passes the offset at load (`LoadOptions.audioDelaySeconds`), applies live changes (`setAudioDelay`) and reports availability from AetherEngine's `videoRoute`. Both players' Audio panels and both Profile screens draw from these.

**Tech Stack:** Swift 6, SwiftUI, AetherEngine 7.x (`setAudioDelay`, `LoadOptions.audioDelaySeconds`, `$videoRoute`), XCTest, XCUITest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-18-audio-offset-design.md`

## Global Constraints

- Range −500…+500 ms, step 10 ms; every stored or applied value is clamped and rounded to a 10 ms step.
- Global default 0 ms. Positive = audio later.
- Storage: device-local `UserDefaults`, **not keyed by user**; per-title keyed by item id only (live and downloaded share).
- In-player scope defaults to This Title each time the panel opens; switching to All Titles removes the title's own offset.
- Hidden wherever `isAudioOffsetAvailable` is false (server transcode `.remoteBypass`, `.audio`, `.none`).
- Live changes reach the engine 0.75 s after the last step; pending changes are applied when the panel closes.
- Shared code compiles for tvOS (`Core/` is compiled whole; downloads code stays behind `#if DOWNLOADS`).
- User-facing strings via `Text("…")` literals in views, `String(localized:)` elsewhere; sync `Localizable.xcstrings` in the same PR (Cmd+B in Xcode, or hand-insert in sort order).
- VoiceOver: "a change announces the new value" is met by the adjustable elements' `accessibilityValue` (VoiceOver speaks an adjustable element's new value after each step), not a separate announcement, which would read twice.
- Accessibility: never select by label in UI tests; no identifier on a screen-root container; decorative SF Symbols `.accessibilityHidden(true)`.
- **Benjamin's workflow:** no `git commit` until he has seen the diff and said so; show screenshots of each visual change before running tests; during review rounds run only new/changed tests; the four full suites run after sign-off, before the commit. Regenerate the project (`xcodegen generate`) whenever files are added.

## Review Focus

1. **A step pressed during the 0.75 s settle, then the panel closed at once:** the latest value must reach the engine on close, not the one before it. Pinned in Task 3 (`test_flush_appliesTheLatestValue`).
2. **The route changing mid-session** (AetherEngine reroutes `.remoteBypass` → `.loopback`): the controls must appear without reopening the player. Pinned in Task 5 (`test_availabilityFollowsTheEngine`).
3. **Steps at the limits:** a step past ±500 must change nothing and save nothing. Pinned in Task 3 (`test_stepAtTheLimit_isIgnored`).
4. **A stored value from a future or corrupted build** (e.g. 723 or 9999): it must read back clamped and rounded. Pinned in Task 2 (`test_readsClampAndRoundWhatIsStored`).
5. **Down in the Apple TV Audio tab with one audio track and the offset unavailable:** focus must stay on the single track (no phantom rows). Pinned in Task 6 (`test_offsetRows_absentWhenUnavailable`).

---

### Task 1: Shared offset model and formatting

**Files:**
- Create: `DionysusPlayer/Core/Playback/AudioOffset.swift`
- Test: `DionysusPlayerTests/Core/Playback/AudioOffsetTests.swift`

**Interfaces:**
- Produces: `enum AudioOffset { static let range: ClosedRange<Int>; static let step: Int; static func normalized(_ ms: Int) -> Int; static func seconds(_ ms: Int) -> TimeInterval }`, `enum AudioOffsetScope: Equatable { case thisTitle, allTitles }`, `enum AudioOffsetFormat { static func value(_ ms: Int) -> String; static func hint(_ ms: Int) -> String; static func spoken(_ ms: Int) -> String }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Dionysus

final class AudioOffsetTests: XCTestCase {
    func test_normalized_clampsToTheRange() {
        XCTAssertEqual(AudioOffset.normalized(900), 500)
        XCTAssertEqual(AudioOffset.normalized(-9999), -500)
    }

    func test_normalized_roundsToTheNearestStep() {
        XCTAssertEqual(AudioOffset.normalized(44), 40)
        XCTAssertEqual(AudioOffset.normalized(45), 50)
        XCTAssertEqual(AudioOffset.normalized(-44), -40)
        XCTAssertEqual(AudioOffset.normalized(-45), -50)
    }

    func test_seconds() {
        XCTAssertEqual(AudioOffset.seconds(40), 0.04, accuracy: 0.0001)
        XCTAssertEqual(AudioOffset.seconds(-500), -0.5, accuracy: 0.0001)
    }

    func test_format_zero() {
        XCTAssertEqual(AudioOffsetFormat.value(0), "0 ms")
        XCTAssertEqual(AudioOffsetFormat.hint(0), "In sync")
        XCTAssertEqual(AudioOffsetFormat.spoken(0), "0 milliseconds, in sync")
    }

    func test_format_positiveIsAudioLater() {
        XCTAssertEqual(AudioOffsetFormat.value(40), "+40 ms")
        XCTAssertEqual(AudioOffsetFormat.hint(40), "Audio later")
        XCTAssertEqual(AudioOffsetFormat.spoken(40), "40 milliseconds, audio later")
    }

    func test_format_negativeIsAudioEarlier_withATrueMinusSign() {
        XCTAssertEqual(AudioOffsetFormat.value(-30), "\u{2212}30 ms")
        XCTAssertEqual(AudioOffsetFormat.hint(-30), "Audio earlier")
        XCTAssertEqual(AudioOffsetFormat.spoken(-30), "30 milliseconds, audio earlier")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/AudioOffsetTests`
Expected: build failure, `AudioOffset` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The audio offset's one range and step, read by the store, the controller
/// and both UIs. Positive delays audio (AetherEngine's `audioDelaySeconds`).
enum AudioOffset {
    static let range: ClosedRange<Int> = -500...500
    static let step = 10

    /// Clamped to `range` and rounded to the nearest `step`, half away from zero.
    static func normalized(_ milliseconds: Int) -> Int {
        let clamped = min(max(milliseconds, range.lowerBound), range.upperBound)
        let steps = (Double(clamped) / Double(step)).rounded(.toNearestOrAwayFromZero)
        return Int(steps) * step
    }

    static func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / 1000
    }
}

/// Where the player's Audio panel writes: the playing title's own offset, or
/// the global one (spec, "Decisions").
enum AudioOffsetScope: Equatable {
    case thisTitle, allTitles
}

/// The offset as shown and as spoken, on both platforms.
enum AudioOffsetFormat {
    /// "+40 ms", "−30 ms" (U+2212), "0 ms".
    static func value(_ milliseconds: Int) -> String {
        let magnitude = abs(milliseconds).formatted()
        let sign = milliseconds > 0 ? "+" : milliseconds < 0 ? "\u{2212}" : ""
        return String(localized: "\(sign)\(magnitude) ms", comment: "Audio offset value, e.g. +40 ms")
    }

    static func hint(_ milliseconds: Int) -> String {
        if milliseconds > 0 { return String(localized: "Audio later") }
        if milliseconds < 0 { return String(localized: "Audio earlier") }
        return String(localized: "In sync")
    }

    static func spoken(_ milliseconds: Int) -> String {
        let magnitude = abs(milliseconds).formatted()
        return String(localized: "\(magnitude) milliseconds, \(hint(milliseconds).lowercased())")
    }
}
```

Note: `hint(_:).lowercased()` yields "audio later" for the spoken string; English only today, and a vendor translating can reorder the format.

- [ ] **Step 4: Run to verify they pass** (same command). Expected: PASS.

- [ ] **Step 5: Stop for Benjamin's review.** Commit only after his sign-off:

```bash
git add DionysusPlayer/Core/Playback/AudioOffset.swift DionysusPlayerTests/Core/Playback/AudioOffsetTests.swift
git commit -m "Add the audio offset range, scope and formatting"
```

---

### Task 2: `AudioOffsetStore`

**Files:**
- Create: `DionysusPlayer/Core/Persistence/AudioOffsetStore.swift`
- Test: `DionysusPlayerTests/Core/Persistence/AudioOffsetStoreTests.swift`

**Interfaces:**
- Consumes: `AudioOffset.normalized(_:)` (Task 1).
- Produces: `final class AudioOffsetStore { init(defaults: UserDefaults = .standard); var globalOffsetMilliseconds: Int { get set }; func offset(forItem itemID: String) -> Int?; func setOffset(_ ms: Int, forItem itemID: String); func removeOffset(forItem itemID: String) }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Dionysus

final class AudioOffsetStoreTests: XCTestCase {
    private let suiteName = "com.dionysusplayer.tests.AudioOffsetStoreTests"
    private var defaults: UserDefaults!
    private var store: AudioOffsetStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = AudioOffsetStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_global_defaultsToZero() {
        XCTAssertEqual(store.globalOffsetMilliseconds, 0)
    }

    func test_global_persists_normalized() {
        store.globalOffsetMilliseconds = 44
        XCTAssertEqual(AudioOffsetStore(defaults: defaults).globalOffsetMilliseconds, 40)
        store.globalOffsetMilliseconds = 9000
        XCTAssertEqual(store.globalOffsetMilliseconds, 500)
    }

    func test_titleOffset_setReadRemove() {
        XCTAssertNil(store.offset(forItem: "item-1"))
        store.setOffset(-120, forItem: "item-1")
        XCTAssertEqual(AudioOffsetStore(defaults: defaults).offset(forItem: "item-1"), -120)
        XCTAssertNil(store.offset(forItem: "item-2"), "Another item is untouched")
        store.removeOffset(forItem: "item-1")
        XCTAssertNil(store.offset(forItem: "item-1"))
    }

    func test_titleOffset_normalizedOnWrite() {
        store.setOffset(-777, forItem: "item-1")
        XCTAssertEqual(store.offset(forItem: "item-1"), -500)
    }

    /// Review Focus 4: a value written by another build, out of range or off-step.
    func test_readsClampAndRoundWhatIsStored() {
        defaults.set(723, forKey: AudioOffsetStore.globalKey)
        defaults.set(["item-1": 9999, "item-2": -33], forKey: AudioOffsetStore.titlesKey)
        XCTAssertEqual(store.globalOffsetMilliseconds, 500)
        XCTAssertEqual(store.offset(forItem: "item-1"), 500)
        XCTAssertEqual(store.offset(forItem: "item-2"), -30)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/AudioOffsetStoreTests`
Expected: build failure, `AudioOffsetStore` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The audio offset: one global value and per-title overrides, in whole
/// milliseconds.
///
/// Device-local `UserDefaults`, never sent to the server. **Not keyed by user**,
/// unlike `TrackPreferenceStore`: an offset corrects this device's audio chain
/// (a soundbar, an AVR, a TV's processing), which is the same whoever is
/// signed in (Benjamin, 2026-10-18). Per-title entries are keyed by item id
/// alone, so streaming and a download share one, as track choices do.
///
/// Every read and write goes through `AudioOffset.normalized(_:)`, so nothing
/// out of range or off-step can reach the engine from here.
final class AudioOffsetStore {
    static let globalKey = "audioOffset.global"
    static let titlesKey = "audioOffset.titles"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var globalOffsetMilliseconds: Int {
        get { AudioOffset.normalized(defaults.integer(forKey: Self.globalKey)) }
        set { defaults.set(AudioOffset.normalized(newValue), forKey: Self.globalKey) }
    }

    func offset(forItem itemID: String) -> Int? {
        titles[itemID].map(AudioOffset.normalized)
    }

    func setOffset(_ milliseconds: Int, forItem itemID: String) {
        var map = titles
        map[itemID] = AudioOffset.normalized(milliseconds)
        defaults.set(map, forKey: Self.titlesKey)
    }

    func removeOffset(forItem itemID: String) {
        var map = titles
        guard map.removeValue(forKey: itemID) != nil else { return }
        defaults.set(map, forKey: Self.titlesKey)
    }

    private var titles: [String: Int] {
        defaults.dictionary(forKey: Self.titlesKey) as? [String: Int] ?? [:]
    }
}
```

- [ ] **Step 4: Run to verify they pass** (same command). Expected: PASS.

- [ ] **Step 5: Confirm the privacy manifests already declare UserDefaults**

Run: `grep -c "NSPrivacyAccessedAPICategoryUserDefaults" DionysusPlayer/Resources/PrivacyInfo.xcprivacy DionysusTV/Resources/PrivacyInfo.xcprivacy`
Expected: `1` for each. If either is `0`, add the `CA92.1` entry to that manifest in this task.

- [ ] **Step 6: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusPlayer/Core/Persistence/AudioOffsetStore.swift DionysusPlayerTests/Core/Persistence/AudioOffsetStoreTests.swift
git commit -m "Add AudioOffsetStore: a device-wide global offset and per-title overrides"
```

---

### Task 3: `AudioOffsetController`

**Files:**
- Create: `DionysusPlayer/Core/Playback/AudioOffsetController.swift`
- Test: `DionysusPlayerTests/Core/Playback/AudioOffsetControllerTests.swift`

**Interfaces:**
- Consumes: `AudioOffset`, `AudioOffsetScope` (Task 1); `AudioOffsetStore` (Task 2).
- Produces:
  - `@MainActor protocol AudioOffsetScheduling: AnyObject { func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void); func cancel() }`
  - `@MainActor final class TaskAudioOffsetScheduler: AudioOffsetScheduling`
  - `@MainActor @Observable final class AudioOffsetController` with `init(itemID: String, store: AudioOffsetStore, scheduler: AudioOffsetScheduling = TaskAudioOffsetScheduler(), apply: @escaping @MainActor (Int) -> Void)`, `private(set) var milliseconds: Int`, `private(set) var scope: AudioOffsetScope`, `var isAvailable: Bool`, `var hasTitleOffset: Bool { get }`, `var canDecrease: Bool { get }`, `var canIncrease: Bool { get }`, `var loadSeconds: TimeInterval { get }`, `func step(by steps: Int)`, `func setScope(_ scope: AudioOffsetScope)`, `func resetToGlobal()`, `func panelDidOpen()`, `func flush()`, `func cancelPending()`, `static let settleDelay: Duration`.

Spec note: the spec also flushes on "the player stops" and "the item changes". Every step already saves immediately, and each item is a new `PlayerViewModel` (Next Up and playlists build a fresh one), whose load reads the saved value. So a stop only needs `cancelPending()`, and an item change needs nothing. The outcome the spec asks for (nothing set is lost) holds.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/AudioOffsetControllerTests`
Expected: build failure, `AudioOffsetController` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// Runs one delayed action, replacing any still waiting. Injected so tests
/// fire the settle themselves instead of sleeping.
@MainActor
protocol AudioOffsetScheduling: AnyObject {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class TaskAudioOffsetScheduler: AudioOffsetScheduling {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// The player's audio offset for one title: the value in effect, the Audio
/// panel's scope, Reset, and when a change reaches the engine
/// (spec section 3). Both players' Audio panels draw from it.
///
/// A step saves at once and shows at once, but reaches the engine only after
/// `settleDelay` without another: on AetherEngine's native route each change
/// is a session-preserving reload (about 0.3 s of held picture), so applying
/// every 10 ms press would stutter.
@MainActor
@Observable
final class AudioOffsetController {
    static let settleDelay: Duration = .milliseconds(750)

    private(set) var milliseconds: Int
    private(set) var scope: AudioOffsetScope = .thisTitle
    /// From the engine's route; false hides every control.
    var isAvailable = false
    private(set) var hasTitleOffset: Bool

    var canDecrease: Bool { milliseconds > AudioOffset.range.lowerBound }
    var canIncrease: Bool { milliseconds < AudioOffset.range.upperBound }
    /// What `PlaybackEngine.load(...)` is given, so the first frame is in sync.
    var loadSeconds: TimeInterval { AudioOffset.seconds(milliseconds) }

    private let itemID: String
    private let store: AudioOffsetStore
    private let scheduler: AudioOffsetScheduling
    private let apply: @MainActor (Int) -> Void
    /// The value the engine has, so an unchanged value isn't re-applied.
    private var appliedMilliseconds: Int
    private var hasPending = false

    init(
        itemID: String, store: AudioOffsetStore,
        scheduler: AudioOffsetScheduling = TaskAudioOffsetScheduler(),
        apply: @escaping @MainActor (Int) -> Void
    ) {
        self.itemID = itemID
        self.store = store
        self.scheduler = scheduler
        self.apply = apply
        let own = store.offset(forItem: itemID)
        hasTitleOffset = own != nil
        milliseconds = own ?? store.globalOffsetMilliseconds
        appliedMilliseconds = milliseconds
    }

    func step(by steps: Int) {
        let next = AudioOffset.normalized(milliseconds + steps * AudioOffset.step)
        guard next != milliseconds else { return }
        switch scope {
        case .thisTitle:
            store.setOffset(next, forItem: itemID)
            hasTitleOffset = true
        case .allTitles:
            store.globalOffsetMilliseconds = next
        }
        milliseconds = next
        scheduleApply()
    }

    func setScope(_ newScope: AudioOffsetScope) {
        guard newScope != scope else { return }
        scope = newScope
        guard newScope == .allTitles, hasTitleOffset else { return }
        followGlobal()
    }

    func resetToGlobal() {
        guard hasTitleOffset else { return }
        followGlobal()
    }

    func panelDidOpen() {
        scope = .thisTitle
    }

    /// Applies a waiting change now: the panel closed.
    func flush() {
        guard hasPending else { return }
        scheduler.cancel()
        applyNow()
    }

    /// Drops a waiting engine call; the value is already saved.
    func cancelPending() {
        scheduler.cancel()
        hasPending = false
    }

    private func followGlobal() {
        store.removeOffset(forItem: itemID)
        hasTitleOffset = false
        let global = store.globalOffsetMilliseconds
        guard global != milliseconds else { return }
        milliseconds = global
        scheduleApply()
    }

    private func scheduleApply() {
        hasPending = true
        scheduler.schedule(after: Self.settleDelay) { [weak self] in self?.applyNow() }
    }

    private func applyNow() {
        hasPending = false
        guard isAvailable, milliseconds != appliedMilliseconds else { return }
        appliedMilliseconds = milliseconds
        apply(milliseconds)
    }
}
```

- [ ] **Step 4: Run to verify they pass** (same command). Expected: PASS.

- [ ] **Step 5: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusPlayer/Core/Playback/AudioOffsetController.swift DionysusPlayerTests/Core/Playback/AudioOffsetControllerTests.swift
git commit -m "Add AudioOffsetController: scope, reset and the settle before applying"
```

---

### Task 4: Engine protocol, AetherEngine adapter and fakes

**Files:**
- Modify: `DionysusPlayer/Core/Playback/PlaybackEngine.swift` (protocol and the `load` overloads)
- Modify: `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift` (`makeLoadOptions` ~line 480, `load` ~512, route sink beside the others ~line 237–340)
- Modify: `DionysusPlayer/Core/Playback/PreviewPlaybackEngine.swift`
- Modify: `DionysusPlayerTests/Support/FakePlaybackEngine.swift`
- Modify: `DionysusPlayer/Core/UITestSupport/UITestConfiguration.swift` (new scenario)
- Test: `DionysusPlayerTests/Core/Playback/AetherPlaybackEngineLoadOptionsTests.swift`

**Interfaces:**
- Produces on `PlaybackEngine`:
  - `func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>, isRemoteHLS: Bool, audioOffset: TimeInterval) async throws`
  - `func setAudioOffset(_ seconds: TimeInterval)`
  - `var isAudioOffsetAvailable: Bool { get }`
  - `var onAudioOffsetAvailabilityChange: ((Bool) -> Void)? { get set }`
- Produces: `AetherPlaybackEngine.makeLoadOptions(isRemoteHLS:externalSubtitles:display:audioOffset:)`, `nonisolated static func isAudioOffsetAvailable(on route: VideoRoute) -> Bool`.
- Produces: `UITestScenario.audioOffsetUnavailable`.
- `FakePlaybackEngine` records `loadedAudioOffsets: [TimeInterval]`, `audioOffsetRequests: [TimeInterval]`, and has a settable `isAudioOffsetAvailable` that calls the callback.

- [ ] **Step 1: Write the failing tests** (append to `AetherPlaybackEngineLoadOptionsTests`)

```swift
    func test_audioOffset_isPassedAsAudioDelaySeconds() {
        let options = AetherPlaybackEngine.makeLoadOptions(
            isRemoteHLS: false, externalSubtitles: [], display: .unknown, audioOffset: 0.04
        )
        XCTAssertEqual(options.audioDelaySeconds, 0.04, accuracy: 0.0001)
    }

    func test_audioOffset_defaultsToZero() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: false, externalSubtitles: [], display: .unknown)
        XCTAssertEqual(options.audioDelaySeconds, 0)
    }

    /// The offset applies where AetherEngine holds the timestamps.
    func test_audioOffsetAvailability_perRoute() {
        XCTAssertTrue(AetherPlaybackEngine.isAudioOffsetAvailable(on: .loopback))
        XCTAssertTrue(AetherPlaybackEngine.isAudioOffsetAvailable(on: .software))
        XCTAssertFalse(AetherPlaybackEngine.isAudioOffsetAvailable(on: .remoteBypass))
        XCTAssertFalse(AetherPlaybackEngine.isAudioOffsetAvailable(on: .audio))
        XCTAssertFalse(AetherPlaybackEngine.isAudioOffsetAvailable(on: .none))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/AetherPlaybackEngineLoadOptionsTests`
Expected: build failure, extra argument `audioOffset` / missing `isAudioOffsetAvailable(on:)`.

- [ ] **Step 3: Change the protocol**

In `PlaybackEngine.swift`, replace the `load` requirement and add the three members after `selectSubtitleTrack(id:)`:

```swift
    /// `audioOffset` is the lip-sync offset in seconds, positive delaying
    /// audio, passed as AetherEngine's `LoadOptions.audioDelaySeconds` so the
    /// first frame plays in sync (`AudioOffsetController.loadSeconds`).
    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>, isRemoteHLS: Bool, audioOffset: TimeInterval) async throws
```

```swift
    /// Changes the offset while playing (`AetherEngine.setAudioDelay`). A
    /// no-op where `isAudioOffsetAvailable` is false.
    func setAudioOffset(_ seconds: TimeInterval)
    /// Whether the offset can be applied on the current route: AetherEngine's
    /// loopback and software routes, not a server transcode's AVPlayer bypass.
    var isAudioOffsetAvailable: Bool { get }
    /// Every change of `isAudioOffsetAvailable`, including AetherEngine's own
    /// reroutes mid-session.
    var onAudioOffsetAvailabilityChange: ((Bool) -> Void)? { get set }
```

Update the extension so existing callers keep compiling:

```swift
extension PlaybackEngine {
    func load(url: URL) async throws {
        try await load(url: url, externalSubtitles: [], knownAtmosAudioTrackIndices: [], isRemoteHLS: false, audioOffset: 0)
    }

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource]) async throws {
        try await load(url: url, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: [], isRemoteHLS: false, audioOffset: 0)
    }

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>) async throws {
        try await load(url: url, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: knownAtmosAudioTrackIndices, isRemoteHLS: false, audioOffset: 0)
    }

    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>, isRemoteHLS: Bool) async throws {
        try await load(url: url, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: knownAtmosAudioTrackIndices, isRemoteHLS: isRemoteHLS, audioOffset: 0)
    }
}
```

(Keep each overload's existing doc comment.)

- [ ] **Step 4: Implement in `AetherPlaybackEngine`**

`makeLoadOptions` gains `audioOffset: TimeInterval = 0` and passes it last (it follows `externalSubtitles` in `LoadOptions`' declared order):

```swift
    nonisolated static func makeLoadOptions(
        isRemoteHLS: Bool, externalSubtitles: [ExternalSubtitleTrack], display: DisplayContext, audioOffset: TimeInterval = 0
    ) -> LoadOptions {
        LoadOptions(
            // …existing arguments unchanged…
            externalSubtitles: externalSubtitles,
            // AE#464. Positive delays audio. `AudioOffsetController` has
            // already clamped it to ±0.5 s, inside the engine's ±2 s.
            audioDelaySeconds: audioOffset
        )
    }

    /// AetherEngine applies an offset where it holds the timestamps:
    /// `.loopback` and `.software`. On `.remoteBypass` AVPlayer owns the
    /// whole stream (a server transcode), and `.audio`/`.none` have no
    /// picture to sync against (`AudioDelayPolicy`, spec "What AetherEngine
    /// supports").
    nonisolated static func isAudioOffsetAvailable(on route: VideoRoute) -> Bool {
        route == .loopback || route == .software
    }
```

`load(...)` takes the new parameter and passes it through:

```swift
    func load(url: URL, externalSubtitles: [ExternalSubtitleSource], knownAtmosAudioTrackIndices: Set<Int>, isRemoteHLS: Bool, audioOffset: TimeInterval) async throws {
        // …unchanged prologue…
        let options = Self.makeLoadOptions(
            isRemoteHLS: isRemoteHLS,
            externalSubtitles: externalSubtitles.map(Self.makeExternalSubtitleTrack),
            display: DisplayContext.current(),
            audioOffset: audioOffset
        )
        // …unchanged…
    }
```

Members, beside the other callbacks:

```swift
    var onAudioOffsetAvailabilityChange: ((Bool) -> Void)?
    private(set) var isAudioOffsetAvailable = false

    func setAudioOffset(_ seconds: TimeInterval) {
        guard isAudioOffsetAvailable else { return }
        engine.setAudioDelay(seconds)
    }
```

In the method that wires the other `engine.$…` sinks, add:

```swift
        engine.$videoRoute
            .map(Self.isAudioOffsetAvailable(on:))
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                guard let self else { return }
                self.isAudioOffsetAvailable = available
                self.onAudioOffsetAvailabilityChange?(available)
            }
            .store(in: &cancellables)
```

(Match the neighbouring sinks' scheduling: if they use `MainActor.assumeIsolated` instead of `receive(on:)`, do the same.)

- [ ] **Step 5: Implement in the fakes**

`UITestConfiguration.swift`, at the end of `UITestScenario`:

```swift
    /// `.standard`, but the fake engine reports the audio offset unavailable,
    /// standing in for a server transcode (AetherEngine's `.remoteBypass`),
    /// so the player's offset controls are hidden.
    case audioOffsetUnavailable
```

`PreviewPlaybackEngine.swift`:

```swift
    var onAudioOffsetAvailabilityChange: ((Bool) -> Void)?
    private(set) var isAudioOffsetAvailable = false
    /// The last offset `load` or `setAudioOffset` was given, for previews.
    private(set) var audioOffsetSeconds: TimeInterval = 0

    func setAudioOffset(_ seconds: TimeInterval) {
        guard isAudioOffsetAvailable else { return }
        audioOffsetSeconds = seconds
    }
```

and in its `load`, take `audioOffset: TimeInterval`, then before `onStateChange?(.playing)`:

```swift
        audioOffsetSeconds = audioOffset
        isAudioOffsetAvailable = UITestConfiguration.scenario != .audioOffsetUnavailable
        onAudioOffsetAvailabilityChange?(isAudioOffsetAvailable)
```

(`UITestConfiguration` is `#if DEBUG`, as `PreviewPlaybackEngine` is.)

`FakePlaybackEngine.swift`:

```swift
    var onAudioOffsetAvailabilityChange: ((Bool) -> Void)?
    /// Settable so a test can flip the route; reports through the callback.
    var isAudioOffsetAvailable = false {
        didSet { onAudioOffsetAvailabilityChange?(isAudioOffsetAvailable) }
    }
    /// Recorded alongside each `loadedURLs` entry, same index.
    private(set) var loadedAudioOffsets: [TimeInterval] = []
    private(set) var audioOffsetRequests: [TimeInterval] = []

    func setAudioOffset(_ seconds: TimeInterval) { audioOffsetRequests.append(seconds) }
```

and its `load` takes `audioOffset: TimeInterval` and appends it to `loadedAudioOffsets` after `loadedIsRemoteHLS.append(isRemoteHLS)`.

- [ ] **Step 6: Run to verify they pass**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/AetherPlaybackEngineLoadOptionsTests`
Expected: PASS. Then build tvOS: `xcodebuild build -project DionysusPlayer.xcodeproj -scheme DionysusTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'`. Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusPlayer/Core/Playback/PlaybackEngine.swift DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift DionysusPlayer/Core/Playback/PreviewPlaybackEngine.swift DionysusPlayer/Core/UITestSupport/UITestConfiguration.swift DionysusPlayerTests/Support/FakePlaybackEngine.swift DionysusPlayerTests/Core/Playback/AetherPlaybackEngineLoadOptionsTests.swift
git commit -m "Pass the audio offset through PlaybackEngine to AetherEngine"
```

---

### Task 5: Wire the controller into `PlayerViewModel`

**Files:**
- Modify: `DionysusPlayer/Features/Player/PlayerViewModel.swift` (properties ~line 150–200, both `init`s ~406–500, `start()` load ~608, `startOffline` load ~710, `stop` ~1497)
- Test: `DionysusPlayerTests/Features/Player/PlayerViewModelTests.swift`

**Interfaces:**
- Consumes: `AudioOffsetController`, `AudioOffsetStore`, `PlaybackEngine.setAudioOffset`, `onAudioOffsetAvailabilityChange`, `load(…audioOffset:)`.
- Produces: `let audioOffset: AudioOffsetController` on `PlayerViewModel`; `init(…, audioOffsetStore: AudioOffsetStore = AudioOffsetStore(), …)` on both initializers.

- [ ] **Step 1: Write the failing tests**

Add `audioOffsetStore: AudioOffsetStore? = nil` to the test file's `makeViewModel` and pass `audioOffsetStore: audioOffsetStore ?? AudioOffsetStore(defaults: defaults)`. Then add (`stubStart(itemDto:mediaSources:)` is the file's existing helper for a successful direct-play `start()`):

```swift
    func test_start_loadsWithTheTitlesOffset() async {
        let store = AudioOffsetStore(defaults: defaults)
        store.globalOffsetMilliseconds = 30
        store.setOffset(-60, forItem: "item-1")
        let (viewModel, engine) = makeViewModel(audioOffsetStore: store)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie), mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")])
        await viewModel.start()
        XCTAssertEqual(engine.loadedAudioOffsets.last ?? 99, -0.06, accuracy: 0.0001)
    }

    func test_start_loadsWithTheGlobal_whenTheTitleHasNone() async {
        let store = AudioOffsetStore(defaults: defaults)
        store.globalOffsetMilliseconds = 30
        let (viewModel, engine) = makeViewModel(audioOffsetStore: store)
        stubStart(itemDto: BaseItemDto(id: "item-1", name: "Arrival", type: .movie), mediaSources: [MediaSourceInfo(id: "src-1", container: "mp4")])
        await viewModel.start()
        XCTAssertEqual(engine.loadedAudioOffsets.last ?? 99, 0.03, accuracy: 0.0001)
    }

    /// Review Focus 2.
    func test_availabilityFollowsTheEngine() {
        let (viewModel, engine) = makeViewModel()
        XCTAssertFalse(viewModel.audioOffset.isAvailable)
        engine.isAudioOffsetAvailable = true
        XCTAssertTrue(viewModel.audioOffset.isAvailable)
        engine.isAudioOffsetAvailable = false
        XCTAssertFalse(viewModel.audioOffset.isAvailable)
    }

    func test_aFlushedChange_reachesTheEngineInSeconds() {
        let (viewModel, engine) = makeViewModel()
        engine.isAudioOffsetAvailable = true
        viewModel.audioOffset.step(by: 2)
        viewModel.audioOffset.flush()
        XCTAssertEqual(engine.audioOffsetRequests, [0.02])
    }

    func test_stop_dropsAPendingChange() async {
        let (viewModel, engine) = makeViewModel()
        engine.isAudioOffsetAvailable = true
        viewModel.audioOffset.step(by: 1)
        await viewModel.stop()
        viewModel.audioOffset.flush()
        XCTAssertEqual(engine.audioOffsetRequests, [])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/PlayerViewModelTests`
Expected: build failure, no `audioOffsetStore` parameter / `audioOffset` member.

- [ ] **Step 3: Implement**

Property, beside `engine`:

```swift
    /// The lip-sync offset for this title: the Audio panel's value, scope and
    /// Reset, and when a change reaches the engine (`AudioOffsetController`).
    let audioOffset: AudioOffsetController
```

Both initializers gain `audioOffsetStore: AudioOffsetStore = AudioOffsetStore()` (after `streamPreferenceStore:`); the convenience one forwards it. In the designated `init`, after `self.playbackQueue = playbackQueue`:

```swift
        self.audioOffset = AudioOffsetController(itemID: itemID, store: audioOffsetStore) { [weak engine] milliseconds in
            engine?.setAudioOffset(AudioOffset.seconds(milliseconds))
        }
```

and after the other `engine.on…` assignments:

```swift
        engine.onAudioOffsetAvailabilityChange = { [weak self] available in self?.audioOffset.isAvailable = available }
        audioOffset.isAvailable = engine.isAudioOffsetAvailable
```

`start()`'s load:

```swift
            try await engine.load(
                url: url, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: atmosAudioTrackIndices,
                isRemoteHLS: isRemoteHLS, audioOffset: audioOffset.loadSeconds
            )
```

`startOffline`'s load:

```swift
            try await engine.load(
                url: videoURL, externalSubtitles: externalSubtitles, knownAtmosAudioTrackIndices: [],
                isRemoteHLS: false, audioOffset: audioOffset.loadSeconds
            )
```

First line of `stop(handingOff:)`, before `progressReportTask?.cancel()`:

```swift
        // Already saved; the next load reads it, so only the engine call goes.
        audioOffset.cancelPending()
```

- [ ] **Step 4: Run to verify they pass** (same command, then the tvOS build from Task 4 Step 6). Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 5: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusPlayer/Features/Player/PlayerViewModel.swift DionysusPlayerTests/Features/Player/PlayerViewModelTests.swift
git commit -m "Give PlayerViewModel the title's audio offset"
```

---

### Task 6: Apple TV panel input for the offset rows

**Files:**
- Modify: `DionysusTV/Player/TVPlayerInputModel.swift` (`TVPlayerCommand`, `TVPlayerControl`, `TVPlayerContext`, `HeldArrow`, `tick`)
- Modify: `DionysusTV/Player/TVPlayerInputModel+Panel.swift`
- Modify: `DionysusTV/Player/TVPlayerInputModel+Accessible.swift`
- Modify: `DionysusTV/Player/TVPlayerContext+ViewModel.swift`
- Modify: `DionysusTV/Player/TVPlayerCommandRunner.swift`
- Test: `DionysusTVTests/TVPlayerPanelTests.swift`, `DionysusTVTests/TVPlayerCommandRunnerTests.swift`, `DionysusTVTests/TVPlayerContextTests.swift`

**Interfaces:**
- Consumes: `viewModel.audioOffset` (Task 5).
- Produces:
  - `TVPlayerContext.AudioOffset: Equatable { var canDecrease: Bool; var canIncrease: Bool; var hasTitleOffset: Bool; var scope: AudioOffsetScope }` and `var audioOffset: AudioOffset?` on the context (`nil` = unavailable).
  - `TVPlayerCommand` cases `stepAudioOffset(Int)`, `setAudioOffsetScope(AudioOffsetScope)`, `resetAudioOffset`.
  - `TVPlayerControl.adjustPanelRow(Int, TVDirection)` (accessible transport's adjustable row).
  - `enum TVAudioPanelRow: Equatable { case track(Int), offset, scope, reset }` and `static func audioRow(at index: Int, _ context: TVPlayerContext) -> TVAudioPanelRow?` on `TVPlayerInputModel`.

Row layout in the Audio tab: indices `0..<audioTrackIDs.count` are tracks; when `audioOffset != nil`, the next three are offset, scope, reset.

- [ ] **Step 1: Write the failing tests** (append to `TVPlayerPanelTests`)

```swift
    private func openAudio() {
        send(.down)
        press(.right)
        press(.right)
        XCTAssertEqual(state.panel?.tab, .audio)
        send(.down)
    }

    private var offsetContext: TVPlayerContext.AudioOffset {
        .init(canDecrease: true, canIncrease: true, hasTitleOffset: false, scope: .thisTitle)
    }

    func test_offsetRows_followTheTracks() {
        context.audioOffset = offsetContext
        openAudio()
        XCTAssertEqual(state.panel?.focus, .content(0))
        send(.down)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(2), "The offset row follows the two tracks")
        XCTAssertEqual(TVPlayerInputModel.audioRow(at: 2, context), .offset)
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(3), "Scope")
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(3), "Reset is skipped while there is nothing to reset")
    }

    func test_offsetRow_leftRightStep() {
        context.audioOffset = offsetContext
        openAudio()
        send(.down); send(.down)
        XCTAssertEqual(press(.right), [.stepAudioOffset(1)])
        XCTAssertEqual(press(.left), [.stepAudioOffset(-1)])
        XCTAssertEqual(state.panel?.tab, .audio, "Arrows on the offset row never switch tabs")
    }

    func test_offsetRow_stepRefusedAtTheEnd() {
        context.audioOffset = .init(canDecrease: true, canIncrease: false, hasTitleOffset: true, scope: .thisTitle)
        openAudio()
        send(.down); send(.down)
        XCTAssertEqual(press(.right), [])
    }

    func test_offsetRow_holdRepeats() {
        context.audioOffset = offsetContext
        openAudio()
        send(.down); send(.down)
        send(.arrowDown(.right))
        let commands = tick(for: 1.0)
        XCTAssertGreaterThanOrEqual(commands.filter { $0 == .stepAudioOffset(1) }.count, 5, "About ten a second after the hold threshold")
        XCTAssertEqual(send(.arrowUp(.right)), [], "The release of a repeating hold adds no extra step")
    }

    func test_scopeRow_switches() {
        context.audioOffset = offsetContext
        openAudio()
        send(.down); send(.down); send(.down)
        XCTAssertEqual(press(.right), [.setAudioOffsetScope(.allTitles)])
        context.audioOffset?.scope = .allTitles
        XCTAssertEqual(send(.select), [.setAudioOffsetScope(.thisTitle)])
    }

    func test_resetRow_whenTheTitleHasItsOwn() {
        context.audioOffset = .init(canDecrease: true, canIncrease: true, hasTitleOffset: true, scope: .thisTitle)
        openAudio()
        send(.down); send(.down); send(.down); send(.down)
        XCTAssertEqual(state.panel?.focus, .content(4))
        XCTAssertEqual(send(.select), [.resetAudioOffset])
        XCTAssertNotNil(state.panel, "Reset leaves the panel open")
    }

    /// Review Focus 5.
    func test_offsetRows_absentWhenUnavailable() {
        context.audioTrackIDs = [0]
        context.selectedAudioIndex = 0
        context.audioOffset = nil
        openAudio()
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(0))
        XCTAssertNil(TVPlayerInputModel.audioRow(at: 1, context))
    }

    func test_offsetOnly_oneTrack_downReachesTheOffsetRow() {
        context.audioTrackIDs = [0]
        context.selectedAudioIndex = 0
        context.audioOffset = offsetContext
        openAudio()
        send(.down)
        XCTAssertEqual(state.panel?.focus, .content(1))
        XCTAssertEqual(TVPlayerInputModel.audioRow(at: 1, context), .offset)
    }

    func test_accessible_adjustableRow_steps() {
        context.accessibleTransport = true
        context.audioOffset = offsetContext
        state.panel = .init(tab: .audio, focus: .content(2), lastInputAt: now)
        XCTAssertEqual(send(.control(.adjustPanelRow(2, .right))), [.stepAudioOffset(1)])
        XCTAssertEqual(send(.control(.adjustPanelRow(2, .left))), [.stepAudioOffset(-1)])
        XCTAssertEqual(send(.control(.panelRow(3))), [.setAudioOffsetScope(.allTitles)])
    }
```

In `TVPlayerCommandRunnerTests`:

```swift
    func test_audioOffsetCommands_reachTheController() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let engine = FakePlaybackEngine()
        engine.isAudioOffsetAvailable = true
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults),
            audioOffsetStore: AudioOffsetStore(defaults: defaults)
        )
        let runner = TVPlayerCommandRunner(viewModel: viewModel, close: {}, playNext: {})

        runner.run([.stepAudioOffset(2)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.audioOffset.milliseconds, 20)
        XCTAssertTrue(viewModel.audioOffset.hasTitleOffset)

        runner.run([.resetAudioOffset])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(viewModel.audioOffset.hasTitleOffset)

        runner.run([.setAudioOffsetScope(.allTitles)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.audioOffset.scope, .allTitles)
    }
```

In `TVPlayerContextTests`, beside `test_tracksAndSettings_comeFromTheViewModelAndDefaults` (same setup, `defaults` as that file has it):

```swift
    func test_audioOffset_snapshot_nilWhenUnavailable() {
        let engine = FakePlaybackEngine()
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: engine,
            trackPreferenceStore: TrackPreferenceStore(defaults: defaults),
            nextUpPreferenceStore: NextUpPreferenceStore(defaults: defaults),
            streamPreferenceStore: StreamPreferenceStore(defaults: defaults),
            audioOffsetStore: AudioOffsetStore(defaults: defaults)
        )
        XCTAssertNil(TVPlayerContext(viewModel: viewModel, defaults: defaults).audioOffset)

        engine.isAudioOffsetAvailable = true
        let context = TVPlayerContext(viewModel: viewModel, defaults: defaults)
        XCTAssertEqual(context.audioOffset, .init(canDecrease: true, canIncrease: true, hasTitleOffset: false, scope: .thisTitle))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUnitTests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -only-testing:DionysusTVTests/TVPlayerPanelTests -only-testing:DionysusTVTests/TVPlayerCommandRunnerTests -only-testing:DionysusTVTests/TVPlayerContextTests`
Expected: build failure.

- [ ] **Step 3: Implement the types** (`TVPlayerInputModel.swift`)

```swift
enum TVPlayerCommand: Equatable {
    // …existing cases…
    /// The Audio tab's offset rows (`AudioOffsetController`).
    case stepAudioOffset(Int), setAudioOffsetScope(AudioOffsetScope), resetAudioOffset
}
```

```swift
enum TVPlayerControl: Equatable {
    // …existing cases…
    /// The accessible transport's adjustable panel row (the audio offset):
    /// swipe up is `.right`, swipe down `.left`.
    case adjustPanelRow(Int, TVDirection)
}
```

In `TVPlayerContext`:

```swift
    struct AudioOffset: Equatable {
        var canDecrease: Bool
        var canIncrease: Bool
        var hasTitleOffset: Bool
        var scope: AudioOffsetScope
    }

    /// The Audio tab's offset rows; `nil` where the offset can't apply.
    var audioOffset: AudioOffset?
```

In `HeldArrow`, add `var lastRepeatAt: TimeInterval?`.

```swift
/// A row of the Audio tab: a track, or one of the offset rows after them.
enum TVAudioPanelRow: Equatable {
    case track(Int), offset, scope, reset
}
```

- [ ] **Step 4: Implement the panel rules** (`TVPlayerInputModel+Panel.swift`)

```swift
    static func audioRow(at index: Int, _ context: TVPlayerContext) -> TVAudioPanelRow? {
        let tracks = context.audioTrackIDs.count
        if index >= 0, index < tracks { return .track(index) }
        guard context.audioOffset != nil else { return nil }
        switch index - tracks {
        case 0: return .offset
        case 1: return .scope
        case 2: return .reset
        default: return nil
        }
    }

    /// Reset can take focus only while the title has its own offset.
    static func isFocusable(_ tab: TVPanelTab, _ index: Int, _ context: TVPlayerContext) -> Bool {
        guard tab == .audio, audioRow(at: index, context) == .reset else { return true }
        return context.audioOffset?.hasTitleOffset == true
    }
```

`contentCount`'s audio case becomes `context.audioTrackIDs.count + (context.audioOffset == nil ? 0 : 3)`.

In `reducePanel`, the Down case only moves to a focusable row:

```swift
        case (.down, .content(let index)):
            if panel.tab.isList, index + 1 < count, isFocusable(panel.tab, index + 1, context) {
                panel.focus = .content(index + 1)
            }
```

and the arrow case handles the audio offset rows before chapters:

```swift
        case (.arrow(let direction), .content(let index)):
            if panel.tab == .audio, let commands = audioArrow(direction, at: index, context) {
                state.panel = panel
                return commands
            }
            if panel.tab == .chapters, count > 0 {
                panel.focus = .content(min(max(index + (direction == .left ? -1 : 1), 0), count - 1))
            }
```

with:

```swift
    /// Left/Right on the offset row step; on the scope row they choose a
    /// side. `nil` for a track row, which ignores arrows.
    static func audioArrow(_ direction: TVDirection, at index: Int, _ context: TVPlayerContext) -> [TVPlayerCommand]? {
        guard let offset = context.audioOffset else { return nil }
        switch audioRow(at: index, context) {
        case .offset:
            let up = direction == .right
            return (up ? offset.canIncrease : offset.canDecrease) ? [.stepAudioOffset(up ? 1 : -1)] : []
        case .scope:
            let target: AudioOffsetScope = direction == .right ? .allTitles : .thisTitle
            return target == offset.scope ? [] : [.setAudioOffsetScope(target)]
        default:
            return nil
        }
    }
```

`activateRow`'s audio case:

```swift
        case .audio:
            switch audioRow(at: index, context) {
            case .track(let track):
                return ([.selectAudio(id: context.audioTrackIDs[track])], false)
            case .scope:
                let scope = context.audioOffset?.scope == .thisTitle ? AudioOffsetScope.allTitles : .thisTitle
                return ([.setAudioOffsetScope(scope)], false)
            case .reset:
                return context.audioOffset?.hasTitleOffset == true ? ([.resetAudioOffset], false) : ([], false)
            case .offset, nil:
                return ([], false)
            }
```

- [ ] **Step 5: Implement hold repeat** (`tick` in `TVPlayerInputModel.swift`), after the existing `holdBegan` block:

```swift
        if var held = state.heldArrow, held.isHold, let panel = state.panel, panel.tab == .audio,
           case .content(let index) = panel.focus, audioRow(at: index, context) == .offset,
           now - (held.lastRepeatAt ?? 0) >= TVPlayerTiming.offsetRepeatInterval {
            held.lastRepeatAt = now
            held.actedAsScan = true
            state.heldArrow = held
            state.panel?.lastInputAt = now
            commands += audioArrow(held.direction, at: index, context) ?? []
        }
```

and in `TVPlayerTiming`: `static let offsetRepeatInterval: TimeInterval = 0.1`. (`actedAsScan` makes the release add nothing, as for a scan.)

- [ ] **Step 6: Implement the accessible control** (`TVPlayerInputModel+Accessible.swift`), beside `.panelRow`:

```swift
        case .adjustPanelRow(let index, let direction):
            guard let panel = state.panel, panel.tab == .audio else { return [] }
            return audioArrow(direction, at: index, context) ?? []
```

- [ ] **Step 7: Snapshot and run** — `TVPlayerContext+ViewModel.swift`, in `init(viewModel:defaults:)`:

```swift
        let offset = viewModel.audioOffset
        audioOffset = offset.isAvailable
            ? AudioOffset(canDecrease: offset.canDecrease, canIncrease: offset.canIncrease, hasTitleOffset: offset.hasTitleOffset, scope: offset.scope)
            : nil
```

`TVPlayerCommandRunner.swift`, beside `.selectAudio`:

```swift
            case .stepAudioOffset(let steps): viewModel.audioOffset.step(by: steps)
            case .setAudioOffsetScope(let scope): viewModel.audioOffset.setScope(scope)
            case .resetAudioOffset: viewModel.audioOffset.resetToGlobal()
```

Fix any exhaustive `switch` over `TVPlayerControl`/`TVPlayerCommand` the compiler flags.

- [ ] **Step 8: Run to verify they pass** (Step 2's command). Expected: PASS. Also re-run the whole `TVPlayerPanelTests` and `TVPlayerAccessibleTransportTests` to confirm nothing existing changed.

- [ ] **Step 9: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusTV/Player DionysusTVTests
git commit -m "Apple TV: drive the Audio tab's offset rows from the remote"
```

---

### Task 7: Apple TV Audio tab rows

**Files:**
- Modify: `DionysusTV/Player/TVPlayerPanelView.swift`
- Modify: the view that hosts `TVPlayerPanelView` (find with `grep -rn "TVPlayerPanelView(" DionysusTV`) to call `panelDidOpen()`/`flush()`
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.TV.Player`)
- Test: `DionysusTVUITests/PlayerPanelJourneyTests.swift`, `DionysusTVUITests/PlayerAccessibleTransportJourneyTests.swift`, `DionysusTVUITests/AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: Task 6's rows, commands and `TVPlayerControl.adjustPanelRow`; `AudioOffsetFormat` (Task 1).
- Produces: `A11yID.TV.Player.audioOffsetRow = "tv.player.audioOffset"`, `audioOffsetScope = "tv.player.audioOffset.scope"`, `audioOffsetReset = "tv.player.audioOffset.reset"`, `audioOffsetHeading = "tv.player.audioOffset.heading"`.

- [ ] **Step 1: Write the failing UI journey** (`PlayerPanelJourneyTests`)

```swift
    func test_audioOffset_stepsScopesAndResets() {
        let app = openPlayer(extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        XCTAssertTrue(waitForPlayerFocus(app, "icon.audio"))
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.0"))
        press(.down)
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.2"), "The offset row follows the two tracks")
        let row = app.descendants(matching: .any)[A11yID.TV.Player.audioOffsetRow]
        XCTAssertEqual(row.value as? String, "0 milliseconds, in sync")
        press(.right)
        press(.right)
        XCTAssertTrue(poll(timeout: 3) { (row.value as? String) == "20 milliseconds, audio later" })
        press(.down)
        press(.down)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.4"), "Reset is reachable once the title has its own offset")
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { (row.value as? String) == "0 milliseconds, in sync" })
    }

    func test_audioOffset_hiddenWhenUnavailable() {
        let app = openPlayer(scenario: "audioOffsetUnavailable", extraArguments: keepTransportUp)
        press(.up)
        press(.right)
        press(.select)
        XCTAssertTrue(waitForPlayerFocus(app, "content.audio.0"))
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Player.audioOffsetRow].exists)
    }
```

In `PlayerAccessibleTransportJourneyTests` (XCUITest reports an adjustable SwiftUI element as Other, so, as with the scrubber, swipe-up/down stepping is checked by hand with VoiceOver; the journey pins focus, the spoken value and the scope button):

```swift
    func test_audioOffset_rowsAreReachable_andScopeIsAButton() {
        let app = openPlayer(extraArguments: accessible)
        XCTAssertTrue(waitForFocus(control(app, "playPause")))
        let audio = app.buttons[A11yID.TV.Player.icon("audio")]
        XCTAssertTrue(moveFocus(to: audio, pressing: .right, limit: 8))
        press(.select)
        let row = app.descendants(matching: .any)[A11yID.TV.Player.audioOffsetRow]
        XCTAssertTrue(moveFocus(to: row, pressing: .down, limit: 6))
        XCTAssertEqual(row.value as? String, "0 milliseconds, in sync")
        let scope = app.buttons[A11yID.TV.Player.audioOffsetScope]
        XCTAssertTrue(moveFocus(to: scope, pressing: .down, limit: 2))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { (scope.value as? String) == "All Titles" })
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUITests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -only-testing:DionysusTVUITests/PlayerPanelJourneyTests/test_audioOffset_stepsScopesAndResets -only-testing:DionysusTVUITests/PlayerPanelJourneyTests/test_audioOffset_hiddenWhenUnavailable`
Expected: FAIL (no offset row).

- [ ] **Step 3: Implement the rows** (`TVPlayerPanelView.swift`)

`content`'s audio case becomes `audioContent`:

```swift
        case .audio: audioContent
```

```swift
    // MARK: Audio

    /// The track list, then the offset rows while the offset can apply
    /// (`TVPlayerInputModel.audioRow(at:_:)` numbers them after the tracks).
    private var audioContent: some View {
        let tracks = viewModel.audioTracks.map { ($0.title, $0.metadata, $0.isSelected) }
        let offset = viewModel.audioOffset
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    trackRows(tracks)
                    if offset.isAvailable {
                        Text("Audio Offset")
                            .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 18)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(A11yID.TV.Player.audioOffsetHeading)
                        offsetRow(offset, index: tracks.count)
                        scopeRow(offset, index: tracks.count + 1)
                        resetRow(offset, index: tracks.count + 2)
                    }
                }
            }
            .onChange(of: panel.focus) { _, focus in
                if case .content(let index) = focus { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }
```

Split the existing `trackList(rows:)` so its row-building part is reusable as `trackRows(_:)` (the existing `trackList` becomes `ScrollView { VStack { trackRows(rows) } }` with its current scrolling, still used by Subtitles), keeping each row's `.id(index)` so `scrollTo` works.

```swift
    private func offsetRow(_ offset: AudioOffsetController, index: Int) -> some View {
        control(.panelRow(index), modelFocused: isFocused(index)) { focused in
            HStack(spacing: 24) {
                Text("Audio Offset").font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.left").opacity(offset.canDecrease ? 1 : 0.3).accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(verbatim: AudioOffsetFormat.value(offset.milliseconds)).font(.callout.monospacedDigit().weight(.semibold))
                    Text(verbatim: AudioOffsetFormat.hint(offset.milliseconds)).font(.caption).foregroundStyle(focused ? Color.black.opacity(0.6) : .secondary)
                }
                .frame(minWidth: 160)
                Image(systemName: "chevron.right").opacity(offset.canIncrease ? 1 : 0.3).accessibilityHidden(true)
            }
            .foregroundStyle(focused ? Color.black : Color.white)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(focused ? Color.white : Color.white.opacity(0.08)))
        }
        .id(index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Audio Offset"))
        .accessibilityValue(Text(verbatim: AudioOffsetFormat.spoken(offset.milliseconds)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: send(.adjustPanelRow(index, .right))
            case .decrement: send(.adjustPanelRow(index, .left))
            @unknown default: break
            }
        }
        .accessibilityIdentifier(A11yID.TV.Player.audioOffsetRow)
    }

    private func scopeRow(_ offset: AudioOffsetController, index: Int) -> some View {
        control(.panelRow(index), modelFocused: isFocused(index)) { focused in
            HStack(spacing: 12) {
                scopeCapsule("This Title", isOn: offset.scope == .thisTitle, focused: focused)
                scopeCapsule("All Titles", isOn: offset.scope == .allTitles, focused: focused)
            }
            .padding(.vertical, 6)
        }
        .id(index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Apply To"))
        .accessibilityValue(offset.scope == .thisTitle ? Text("This Title") : Text("All Titles"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(A11yID.TV.Player.audioOffsetScope)
    }

    private func scopeCapsule(_ title: LocalizedStringKey, isOn: Bool, focused: Bool) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(isOn && focused ? Color.black : Color.white)
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(Capsule().fill(isOn ? (focused ? Color.white : Color.white.opacity(0.3)) : Color.white.opacity(0.08)))
    }

    private func resetRow(_ offset: AudioOffsetController, index: Int) -> some View {
        control(.panelRow(index), modelFocused: isFocused(index)) { focused in
            Label("Reset to Global", systemImage: "arrow.uturn.backward")
                .font(.callout.weight(.semibold))
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(Capsule().fill(focused ? Color.white : Color.white.opacity(0.18)))
                .opacity(offset.hasTitleOffset ? 1 : 0.4)
        }
        .id(index)
        .disabled(!offset.hasTitleOffset)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(A11yID.TV.Player.audioOffsetReset)
    }
```

Add the four identifiers to `A11yID.TV.Player`.

- [ ] **Step 4: Open and close hooks.** In the view hosting `TVPlayerPanelView`, where `panel` (the input state's panel) is read:

```swift
        .onChange(of: input.state.panel?.tab == .audio) { _, showsAudio in
            if showsAudio { viewModel.audioOffset.panelDidOpen() } else { viewModel.audioOffset.flush() }
        }
```

(Use the host's actual names for the input model and view model. Opening any tab and moving to Audio both count as opening it; leaving Audio or closing the panel flushes.)

- [ ] **Step 5: Screenshot for Benjamin.** Run the app on the booted Apple TV 4K Simulator under the harness (`-UITestMode YES -UITestScenario standard -UITestSeedSession YES …`), open a title, open Audio, step the offset once; capture with `xcrun simctl io <udid> screenshot` into the scratchpad, send it, and wait for his OK before running tests. Restore SavareseHillFlix afterwards.

- [ ] **Step 6: Run to verify they pass** (Step 2's command, plus the accessible-transport journey and `AccessibilityAuditTests`). Expected: PASS.

- [ ] **Step 7: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusTV/Player DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusTVUITests
git commit -m "Apple TV: the Audio tab's offset, scope and reset rows"
```

---

### Task 8: Apple TV Profile → Playback → Audio Offset

**Files:**
- Create: `DionysusTV/Shell/Profile/TVAudioOffsetPage.swift`
- Modify: `DionysusTV/Shell/Profile/TVProfileView.swift` (`Cover`, the playback section, the cover switch)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.TV.Profile`)
- Test: `DionysusTVUITests/ProfileJourneyTests.swift`, `DionysusTVUITests/AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: `AudioOffsetStore`, `AudioOffset`, `AudioOffsetFormat`.
- Produces: `A11yID.TV.Profile.audioOffset = "tv.profile.audioOffset"`, `audioOffsetDecrease = "tv.profile.audioOffset.decrease"`, `audioOffsetIncrease = "tv.profile.audioOffset.increase"`, `audioOffsetValue = "tv.profile.audioOffset.value"`, `audioOffsetReset = "tv.profile.audioOffset.reset"`.

- [ ] **Step 1: Write the failing UI journey**

```swift
    func test_audioOffset_pageStepsAndResets() {
        let app = launchAtHome()
        openProfile(app)
        let row = app.buttons[A11yID.TV.Profile.audioOffset]
        pressDownThroughProfile(until: row)
        press(.select)
        let value = app.descendants(matching: .any)[A11yID.TV.Profile.audioOffsetValue]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "0 milliseconds, in sync")
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.audioOffsetIncrease]))
        press(.select)
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { value.label == "20 milliseconds, audio later" })
        press(.down)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Profile.audioOffsetReset]))
        press(.select)
        XCTAssertTrue(poll(timeout: 3) { value.label == "0 milliseconds, in sync" })
        press(.menu)
        XCTAssertTrue(waitForFocus(row))
        XCTAssertEqual(row.value as? String, "0 ms")
    }
```

- [ ] **Step 2: Run to verify it fails.** Run the single journey with `-only-testing:` on the `TVUITests` plan. Expected: FAIL.

- [ ] **Step 3: Implement the page**

```swift
import SwiftUI

/// Profile → Playback → Audio Offset: the global lip-sync offset, stepped
/// with − and +, in the Next Episode Countdown page's style. Titles override
/// it from the player's Audio tab (`AudioOffsetController`).
struct TVAudioOffsetPage: View {
    @Binding var milliseconds: Int
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 40) {
            Text("Audio Offset")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(A11yID.TV.Profile.pageTitle)
            VStack(spacing: 8) {
                Text(verbatim: AudioOffsetFormat.value(milliseconds)).font(.system(size: 96, weight: .bold).monospacedDigit())
                Text(verbatim: AudioOffsetFormat.hint(milliseconds)).font(.headline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: AudioOffsetFormat.spoken(milliseconds)))
            .accessibilityIdentifier(A11yID.TV.Profile.audioOffsetValue)
            HStack(spacing: 40) {
                stepButton("minus", steps: -1, enabled: milliseconds > AudioOffset.range.lowerBound, id: A11yID.TV.Profile.audioOffsetDecrease, label: "Decrease")
                stepButton("plus", steps: 1, enabled: milliseconds < AudioOffset.range.upperBound, id: A11yID.TV.Profile.audioOffsetIncrease, label: "Increase")
            }
            .focusSection()
            Button("Reset to 0 ms") { milliseconds = 0 }
                .disabled(milliseconds == 0)
                .focused($focused, equals: A11yID.TV.Profile.audioOffsetReset)
                .accessibilityIdentifier(A11yID.TV.Profile.audioOffsetReset)
            Text("Delays or advances audio to correct lip sync for your TV or receiver. Titles can override it from the player's Audio panel.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = A11yID.TV.Profile.audioOffsetIncrease }
    }

    private func stepButton(_ symbol: String, steps: Int, enabled: Bool, id: String, label: LocalizedStringKey) -> some View {
        Button {
            milliseconds = AudioOffset.normalized(milliseconds + steps * AudioOffset.step)
        } label: {
            Image(systemName: symbol).font(.title.bold()).frame(width: 120, height: 80)
        }
        .disabled(!enabled)
        .focused($focused, equals: id)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }
}
```

Holding Select repeats: tvOS repeats a held button's primary action natively only for some controls; if a held Select doesn't repeat on the Simulator, add `.onLongPressGesture(minimumDuration: 0.4, perform: {}, onPressingChanged:)` driving a 0.1 s repeat `Task`, and note it in the doc comment. Check on the Simulator before adding it (YAGNI if native repeat works).

In `TVProfileView`: add `audioOffset` to `Cover`; add state `@State private var audioOffsetMilliseconds = AudioOffsetStore().globalOffsetMilliseconds`; in the playback section after Chapters in Scrubber:

```swift
                    row(
                        "Audio Offset", value: AudioOffsetFormat.value(audioOffsetMilliseconds),
                        spokenValue: AudioOffsetFormat.spoken(audioOffsetMilliseconds),
                        hint: "Delays or advances audio to correct lip sync for your TV or receiver.",
                        opensPage: true, id: A11yID.TV.Profile.audioOffset
                    ) {
                        cover = .audioOffset
                    }
```

In the cover switch:

```swift
            case .audioOffset:
                TVAudioOffsetPage(milliseconds: Binding(
                    get: { audioOffsetMilliseconds },
                    set: { newValue in
                        let store = AudioOffsetStore()
                        store.globalOffsetMilliseconds = newValue
                        audioOffsetMilliseconds = store.globalOffsetMilliseconds
                    }
                ))
```

Append to the section's `TVSettingsFooter` text: " Audio Offset delays or advances audio to correct lip sync for your TV or receiver. Titles can override it from the player's Audio panel."

Add the five identifiers to `A11yID.TV.Profile`. Run `xcodegen generate`.

- [ ] **Step 4: Screenshot for Benjamin** (Profile → Playback row and the page, on the Apple TV Simulator); wait for his OK.

- [ ] **Step 5: Run to verify it passes**, plus `AccessibilityAuditTests` covering Profile pages. Expected: PASS.

- [ ] **Step 6: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusTV/Shell/Profile DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusTVUITests
git commit -m "Apple TV: the global audio offset in Profile → Playback"
```

---

### Task 9: iOS tracks panel, Audio page

**Files:**
- Modify: `DionysusPlayer/Features/Player/PlayerControlsOverlay.swift` (`hasAudioChoice` users ~612–700, `rootPage`, `leafPage`, `estimatedHeight`, `currentAudioTrackTitle` ~959)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.Player`)
- Modify: `DionysusPlayerUITests/Screens/Screens.swift` (`PlayerScreen`)
- Test: `DionysusPlayerUITests/Journeys/PlayerJourneyTests.swift`, `DionysusPlayerUITests/Journeys/AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: `viewModel.audioOffset`, `AudioOffsetFormat`, `AudioOffsetScope`.
- Produces: `A11yID.Player.audioOffsetValue = "player.audioOffset.value"`, `audioOffsetDecrease = "player.audioOffset.decrease"`, `audioOffsetIncrease = "player.audioOffset.increase"`, `audioOffsetScope(_ scope: String) -> String` (`"player.audioOffset.scope.\(scope)"`, keys `thisTitle`/`allTitles`), `audioOffsetReset = "player.audioOffset.reset"`; `PlayerScreen.audioOffsetValue/Decrease/Increase/Reset` and `audioOffsetScope(_:)`.

- [ ] **Step 1: Write the failing UI journeys**

```swift
    func testAudioOffsetStepsScopesResetsAndIsRemembered() {
        let player = openPlayer()
        player.tracksButton.tap()
        player.trackNavigationRow("audio").tap()
        let value = player.audioOffsetValue
        value.awaitExistence("the audio offset row")
        XCTAssertEqual(value.value as? String, "0 milliseconds, in sync")
        player.audioOffsetIncrease.tap()
        player.audioOffsetIncrease.tap()
        XCTAssertEqual(value.value as? String, "20 milliseconds, audio later")
        XCTAssertTrue(player.audioOffsetReset.isEnabled)
        player.audioOffsetReset.tap()
        XCTAssertEqual(value.value as? String, "0 milliseconds, in sync")
        player.audioOffsetIncrease.tap()

        app.terminate()
        launch(resetsState: false)
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let again = PlayerScreen(app: app)
        again.awaitControls()
        again.tracksButton.tap()
        again.trackNavigationRow("audio").tap()
        XCTAssertEqual(again.audioOffsetValue.value as? String, "10 milliseconds, audio later", "The title kept its offset")
    }

    func testAudioOffsetHiddenWhenUnavailable() {
        launch(scenario: "audioOffsetUnavailable")
        let home = HomeScreen(app: app)
        home.awaitLoaded()
        home.openItem(UITestFixtureIdentity.primaryMovieID)
        AssetDetailScreen(app: app).play()
        let player = PlayerScreen(app: app)
        player.awaitControls()
        player.tracksButton.tap()
        player.trackNavigationRow("audio").tap()
        player.trackOption("audio", 0).awaitExistence("the first audio track")
        XCTAssertFalse(player.audioOffsetValue.exists)
    }
```

(If the relaunch lands on a restored pushed page, pop back as `SearchJourneyTests.testHistoryPersistsAcrossARelaunch` does.)

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -testPlan UITests-Full -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerUITests/PlayerJourneyTests/testAudioOffsetStepsScopesResetsAndIsRemembered -only-testing:DionysusPlayerUITests/PlayerJourneyTests/testAudioOffsetHiddenWhenUnavailable`
Expected: FAIL.

- [ ] **Step 3: Implement the page logic**

```swift
    private var hasAudioChoice: Bool { viewModel.audioTracks.count > 1 }
    /// The Audio page: a track choice, the offset, or both.
    private var hasAudioPage: Bool { hasAudioChoice || viewModel.audioOffset.isAvailable }
```

Replace `hasAudioChoice` with `hasAudioPage` in `trackSelectionButton` (both the `hasAnyChoice` computation and the open branch) and in `leafPage`'s back-row test (`if hasAudioPage && hasSubtitleChoice`). `rootPage` keeps both rows (it's only shown when both pages exist). When the panel opens on, or navigates to, the Audio page, call `viewModel.audioOffset.panelDidOpen()`; when `isShowingTrackPicker` becomes false, call `viewModel.audioOffset.flush()`:

```swift
        .onChange(of: isShowingTrackPicker) { _, showing in
            if !showing { viewModel.audioOffset.flush() }
        }
```

and in `navigateToTrackPickerPage(_:)` plus the direct-open branch for `.audio`: `viewModel.audioOffset.panelDidOpen()`.

`currentAudioTrackTitle` becomes:

```swift
    private var currentAudioTrackTitle: String {
        if !hasAudioChoice, viewModel.audioOffset.isAvailable {
            return AudioOffsetFormat.value(viewModel.audioOffset.milliseconds)
        }
        return viewModel.audioTracks.first(where: \.isSelected)?.title ?? String(localized: "Default")
    }
```

- [ ] **Step 4: Implement the section** — in `leafPage`'s `.audio` case:

```swift
                    case .audio:
                        if hasAudioChoice {
                            trackRows(viewModel.audioTracks, kind: "audio") { track in
                                onInteract()
                                viewModel.selectAudioTrack(id: track.id)
                                withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                            }
                        }
                        if viewModel.audioOffset.isAvailable {
                            if hasAudioChoice { divider }
                            audioOffsetSection
                        }
```

```swift
    @ScaledMetric(relativeTo: .subheadline) private var audioOffsetRowHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .subheadline) private var audioOffsetScopeHeight: CGFloat = 52

    /// The offset, its scope and Reset (spec section 5). Hand-built capsules,
    /// not a system `Stepper`/`Picker`, whose light chrome breaks this dark
    /// overlay for the reasons `trackSelectionButton`'s doc comment gives.
    private var audioOffsetSection: some View {
        let offset = viewModel.audioOffset
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Offset").font(.subheadline)
                    Text(verbatim: "\(AudioOffsetFormat.value(offset.milliseconds)) · \(AudioOffsetFormat.hint(offset.milliseconds))")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Audio Offset"))
                .accessibilityValue(Text(verbatim: AudioOffsetFormat.spoken(offset.milliseconds)))
                .accessibilityAdjustableAction { direction in
                    onInteract()
                    switch direction {
                    case .increment: offset.step(by: 1)
                    case .decrement: offset.step(by: -1)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier(A11yID.Player.audioOffsetValue)
                Spacer()
                offsetStepButton("minus", steps: -1, enabled: offset.canDecrease, id: A11yID.Player.audioOffsetDecrease)
                offsetStepButton("plus", steps: 1, enabled: offset.canIncrease, id: A11yID.Player.audioOffsetIncrease)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: audioOffsetRowHeight)
            divider
            HStack(spacing: 8) {
                scopeSegment("This Title", scope: .thisTitle, key: "thisTitle")
                scopeSegment("All Titles", scope: .allTitles, key: "allTitles")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: audioOffsetScopeHeight)
            divider
            Button {
                onInteract()
                offset.resetToGlobal()
            } label: {
                Label("Reset to Global", systemImage: "arrow.uturn.backward")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .disabled(!offset.hasTitleOffset)
            .opacity(offset.hasTitleOffset ? 1 : 0.4)
            .accessibilityIdentifier(A11yID.Player.audioOffsetReset)
        }
    }

    private func offsetStepButton(_ symbol: String, steps: Int, enabled: Bool, id: String) -> some View {
        Button {
            onInteract()
            viewModel.audioOffset.step(by: steps)
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 36)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        // The adjustable value row speaks for both.
        .accessibilityHidden(true)
        .accessibilityIdentifier(id)
    }

    private func scopeSegment(_ title: LocalizedStringKey, scope: AudioOffsetScope, key: String) -> some View {
        let isOn = viewModel.audioOffset.scope == scope
        return Button {
            onInteract()
            viewModel.audioOffset.setScope(scope)
        } label: {
            Text(title)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Capsule().fill(Color.white.opacity(isOn ? 0.24 : 0.06)))
                .contentShape(Capsule())
        }
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(A11yID.Player.audioOffsetScope(key))
    }
```

`.accessibilityHidden(true)` on the step buttons hides them from VoiceOver and from XCUITest's accessibility tree, so a UI test couldn't tap them. If `player.audioOffsetIncrease` isn't found in Step 6, replace `.accessibilityHidden(true)` with `.accessibilityRemoveTraits(.isButton)` plus `.accessibilityLabel` and accept the duplicate, or drive the journey through the adjustable value row (`value.swipeUp()` under XCUITest's `adjust`). Decide on the Simulator and say which in the commit message.

`estimatedHeight(for:)`'s `.audio` case:

```swift
        case .audio:
            let count = hasAudioChoice ? viewModel.audioTracks.count : 0
            var height = leafHeaderHeight + Self.dividerHeight
                + selectionRowHeight * CGFloat(count) + Self.dividerHeight * CGFloat(max(0, count - 1))
            if viewModel.audioOffset.isAvailable {
                height += (count > 0 ? Self.dividerHeight : 0)
                    + audioOffsetRowHeight + audioOffsetScopeHeight + leafHeaderHeight + Self.dividerHeight * 2
            }
            return height
```

Add the identifiers to `A11yID.Player` and the accessors to `PlayerScreen` (`app.descendants(matching: .any)[…]` for the value row; `app.buttons[…]` for the others).

- [ ] **Step 5: Screenshot for Benjamin** (iPhone 17 Simulator, the Audio page with the offset at +20 ms and on a one-track title); wait for his OK.

- [ ] **Step 6: Run to verify they pass** (Step 2's command, plus `AccessibilityAuditTests` and the existing `testTrackPickerNavigatesBothLeavesAndDismissesOnSelection`). Expected: PASS.

- [ ] **Step 7: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusPlayer/Features/Player/PlayerControlsOverlay.swift DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayerUITests
git commit -m "iOS: the audio offset in the tracks panel's Audio page"
```

---

### Task 10: iOS Profile → Playback → Audio Offset

**Files:**
- Modify: `DionysusPlayer/Features/Profile/ProfileView.swift` (`playbackRows`, `playbackFooter`)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.Profile`)
- Test: `DionysusPlayerUITests/Journeys/ProfileJourneyTests.swift`

**Interfaces:**
- Consumes: `AudioOffsetStore`, `AudioOffset`, `AudioOffsetFormat`.
- Produces: `A11yID.Profile.audioOffsetStepper = "profile.audioOffset.stepper"`, `audioOffsetReset = "profile.audioOffset.reset"`.

- [ ] **Step 1: Write the failing UI journey**

```swift
    /// iPhone only: Profile is one scrolling list there (`ProfileScreen`'s
    /// note on the iPad sidebar fork).
    func testAudioOffsetStepperAndReset() {
        launch()
        HomeScreen(app: app).awaitLoaded()
        TabBar(app: app).profile.tap()
        ProfileScreen(app: app).awaitLoaded()
        let stepper = app.steppers[A11yID.Profile.audioOffsetStepper]
        for _ in 0..<6 where !stepper.isHittable { app.swipeUp() }
        stepper.awaitExistence("the audio offset stepper")
        XCTAssertFalse(app.buttons[A11yID.Profile.audioOffsetReset].exists, "No reset at 0 ms")
        stepper.buttons.element(boundBy: 1).tap() // increment
        stepper.buttons.element(boundBy: 1).tap()
        XCTAssertEqual(stepper.value as? String, "20 milliseconds, audio later")
        app.buttons[A11yID.Profile.audioOffsetReset].tap()
        XCTAssertEqual(stepper.value as? String, "0 milliseconds, in sync")
    }
```

- [ ] **Step 2: Run to verify it fails.** `-only-testing:DionysusPlayerUITests/ProfileJourneyTests/testAudioOffsetStepperAndReset` on `UITests-Full`. Expected: FAIL.

- [ ] **Step 3: Implement**

State in `ProfileView`: `@State private var audioOffsetMilliseconds = AudioOffsetStore().globalOffsetMilliseconds`.

In `playbackRows`, after the Chapters toggle:

```swift
        Stepper(
            value: Binding(
                get: { audioOffsetMilliseconds },
                set: { newValue in
                    let store = AudioOffsetStore()
                    store.globalOffsetMilliseconds = newValue
                    audioOffsetMilliseconds = store.globalOffsetMilliseconds
                }
            ),
            in: AudioOffset.range, step: AudioOffset.step
        ) {
            LabeledContent("Audio Offset", value: AudioOffsetFormat.value(audioOffsetMilliseconds))
                .monospacedDigit()
        }
        .accessibilityValue(Text(verbatim: AudioOffsetFormat.spoken(audioOffsetMilliseconds)))
        .accessibilityIdentifier(A11yID.Profile.audioOffsetStepper)
        if audioOffsetMilliseconds != 0 {
            Button("Reset to 0 ms") {
                AudioOffsetStore().globalOffsetMilliseconds = 0
                audioOffsetMilliseconds = 0
            }
            .accessibilityIdentifier(A11yID.Profile.audioOffsetReset)
        }
```

`playbackFooter`'s text gains: " Audio Offset delays or advances audio to correct lip sync for your TV or receiver. Titles can override it from the player's Audio panel."

Add the identifiers.

- [ ] **Step 4: Screenshot for Benjamin** (iPhone Profile → Playback; iPad split view if available on the booted Simulator); wait for his OK.

- [ ] **Step 5: Run to verify it passes**, plus `AccessibilityAuditTests`' Profile coverage. Expected: PASS.

- [ ] **Step 6: Stop for Benjamin's review.** Commit after sign-off:

```bash
git add DionysusPlayer/Features/Profile/ProfileView.swift DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayerUITests
git commit -m "iOS: the global audio offset in Profile → Playback"
```

---

### Task 11: Docs, String Catalog and the full suites

**Files:**
- Modify: `DionysusPlayer/Core/Playback/CLAUDE.md` (new "Audio offset" section)
- Modify: `DionysusTV/CLAUDE.md` (player panel: Audio tab rows)
- Modify: `TESTING.md` (scenario `audioOffsetUnavailable`)
- Modify: `README.md` (features list)
- Modify: `DionysusPlayer/Resources/Localizable.xcstrings`

- [ ] **Step 1: `Core/Playback/CLAUDE.md`** — add after "Reporting a stop":

```markdown
## Audio offset

A global lip-sync offset (Profile → Playback) and a per-title override (the
player's Audio panel), in `AudioOffsetStore` (device-wide, not per user: it
corrects the device's audio chain) and applied by `AudioOffsetController`
(`viewModel.audioOffset`). The load passes it as `audioDelaySeconds`, so the
first frame is in sync; a live change calls `setAudioDelay`.

- **Where it applies:** AetherEngine's `.loopback` and `.software` routes
  (`AetherPlaybackEngine.isAudioOffsetAvailable(on:)`), following
  `$videoRoute` through mid-session reroutes. **Not on a server transcode**:
  AVPlayer owns `.remoteBypass` and offers no audio delay (an `AVAudioMix`
  needs an `AVAssetTrack`, which HLS doesn't vend), Jellyfin's transcode
  request has no offset parameter, and AetherEngine sends only
  HEVC-in-MPEG-TS VOD through its own ingest (AE#268). The controls hide.
- **A change settles for 0.75 s before reaching the engine:** each one costs
  a session-preserving reload on `.loopback` (about 0.3 s of held picture), a
  seek on `.software`. It saves at once and is applied on panel close.
- **The software route runs slightly offset on an eARC chain** (Living Room,
  2026-10-18): the reason this exists; reported upstream with the measured
  value.
```

- [ ] **Step 2: `DionysusTV/CLAUDE.md`** — in the player panel section, add: "**The Audio tab ends with the audio offset's rows** while it can apply: Audio Offset (Left/Right step 10 ms, holding repeats), This Title | All Titles, Reset to Global (skipped by focus with no title offset). `TVPlayerInputModel.audioRow(at:_:)` numbers them after the tracks; the accessible transport's offset row is one adjustable element (`TVPlayerControl.adjustPanelRow`)."

- [ ] **Step 3: `TESTING.md`** — in the scenario list: "`audioOffsetUnavailable`: the fake engine reports the audio offset unavailable, standing in for a server transcode, so the player hides its offset controls." `README.md`: add "Audio offset (lip sync), global and per title" to the playback features list.

- [ ] **Step 4: String Catalog.** Follow the memory note "Automate Xcode string catalog sync" (watcher first, `open`, `osascript` Cmd+B); if Xcode can't be driven, hand-insert each new key (`{}` for English-only) at its `localizedStandardCompare` position. New keys include: "Audio Offset", "Audio later", "Audio earlier", "In sync", "%@%@ ms", "%@ milliseconds, %@", "This Title", "All Titles", "Apply To", "Reset to Global", "Reset to 0 ms", "Decrease", "Increase", the Profile hint and the two footers. Verify with `python3 -c "import json;json.load(open('DionysusPlayer/Resources/Localizable.xcstrings'))"`.

- [ ] **Step 5: Run every new and changed test once more, then stop for Benjamin's sign-off on the whole branch.**

- [ ] **Step 6: After sign-off, run the four full suites sequentially** (never unit and UI at once):

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -testPlan UnitTests -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -testPlan UITests-Full -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUnitTests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUITests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

Expected: all pass. Then restore both Simulators to SavareseHillFlix (memory: "Restore Simulator login on hand-back") and screenshot to confirm.

- [ ] **Step 7: Commit the docs and catalog** (after sign-off), push, open the PR into `develop` (no session URL in the body), and merge with `--merge` once the required checks pass:

```bash
git add DionysusPlayer/Core/Playback/CLAUDE.md DionysusTV/CLAUDE.md TESTING.md README.md DionysusPlayer/Resources/Localizable.xcstrings
git commit -m "Document the audio offset and sync the String Catalog"
```

- [ ] **Step 8: After merge — follow-ups (ask first for the device):** a debug build on Living Room to dial in Ocean's Thirteen and confirm Inside Out 2 needs 0; then file the AetherEngine issues (software-route offset with the measured value; fMP4 transcodes through the AE#268 ingest; 1080i surplus frames).
