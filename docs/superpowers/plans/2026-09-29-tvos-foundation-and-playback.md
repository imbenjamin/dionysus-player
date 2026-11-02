# tvOS Foundation and Core Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first real slice of Dionysus for Apple TV:
- a `DionysusTV` target on the shared core, with Downloads left out;
- tvOS unit and UI test targets, wired into CI;
- working onboarding and a basic browse screen;
- the AetherEngine player host, delivering **HDR** on a real Apple TV;
- a first TV transport.

**Architecture:**
- A separate tvOS app target compiles the iOS app's `Core/`, `App/AppState.swift`, selected `Shared/` files and every `*ViewModel.swift`.
- Shared download code sits behind a `DOWNLOADS` compilation condition, which only the iOS targets define.
- Playback runs through an `AVPlayerViewController` subclass that hides AVKit's chrome, shows the engine's `AetherPlayerView` only on the software route, and draws a SwiftUI transport. It is presented with UIKit.

**Tech Stack:** Swift 6, SwiftUI (tvOS 26), UIKit/AVKit, AetherEngine 7.21.0, XcodeGen, XCTest/XCUITest (`XCUIRemote`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-29-tvos-app-design.md`. The spike code on `spike/tvos-poc` is the reference implementation for Tasks 1, 2, 6 and 7. Read it, but don't cherry-pick it: it carries SPIKE hacks, including `SpikeDownloadStubs.swift`, the `spikeAutoplay` argument and the diagnostic overlay text.

## Global Constraints

- **Deployment target** `tvOS 26.0` for every tvOS target. iOS stays at `18.0`.
- **Bundle IDs:**
  - Product: `PRODUCT_BUNDLE_IDENTIFIER: com.imbenjamin.dionysusplayer`, the same as iOS.
  - Test bundles: `com.imbenjamin.dionysusplayer.tvtests` and `.tvuitests`.
- **`DOWNLOADS` is defined only on `DionysusPlayer` and `DionysusPlayerTests`**, as `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) DOWNLOADS"`. `$(inherited)` keeps `DEBUG`.
- **The iOS app must behave identically:** the iOS `UnitTests` plan and `UITests-Smoke` stay green on every PR.
- **The Xcode project is generated:**
  - Edit `project.yml` and run `xcodegen generate`; never commit `.xcodeproj`.
  - `Package.resolved` stays gitignored.
- **Localization:** `Text("…")` literals in views, and `String(localized:)` in view models and other non-view code. Sync `Localizable.xcstrings` in Xcode (Cmd+B) in the same PR as new strings.
- **A11y:** never select on a label, and never put an identifier on a screen-root container (see `A11yID`). New identifiers go in `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` under `A11yID.TV`.
- **Player presentation** is UIKit `present(_:animated:)`, never `fullScreenCover`, because the latter takes Menu away from the controller.
- **The engine's `AetherPlayerView` must be hidden (`isHidden = true`) whenever `currentAVPlayer != nil`.**
- **The AVKit host must not also own Now Playing:** `AetherPlaybackEngine(ownsNowPlayingSession: false)` under the AVKit host.
- **Workflow:**
  - Benjamin signs off every commit and every push.
  - Branch from `develop` in the main checkout.
  - One PR per group below, merged with `--merge`.
  - README.md and TESTING.md are reviewed in the same commit as any change they describe.
- **Commit trailer:** `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never include a Claude session URL.

## Review Focus

1. **A title with no logo image.** The player's top-left block must fall back to title text, as `LogoImageView(url:fallback:)` does, never an empty box. (Pinned in Task 8.)
2. **The Match Content setting read from a window that isn't the key window**, or before any window exists. `TVDisplayContext.current()` must return `matchContentEnabled: true` (the engine's own default), never `false` by accident. (Pinned in Task 7.)
3. **A route change mid-session.** For example, an audio-track reload moves native → native, and an escalation moves native → software. The engine view's visibility must follow every `$currentAVPlayer` emission, not just the first. (Pinned in Task 6.)
4. **Menu while the player is still loading.** It must stop the engine and dismiss, with no audio carrying on after the player has gone. (Pinned in Task 6.)
5. **A cancelled first Home load** (the tab rebuilt mid-request). It must return to a state from which `loadIfNeeded()` loads again, never stay stuck at `.loading`. (Pinned in Task 5.)

## Pull requests

| PR | Tasks | Branch |
|---|---|---|
| 1 | 1–3: seams, tvOS targets, CI | `feature/tvos-foundation` |
| 2 | 4–5: onboarding and the browse launcher | `feature/tvos-onboarding` |
| 3 | 6–8: player host, HDR, transport | `feature/tvos-playback` |

---

### Task 1: `DOWNLOADS` seams in the shared core

**Files:**
- Modify: `project.yml` (the `DionysusPlayer` and `DionysusPlayerTests` settings)
- Modify: `DionysusPlayer/App/AppState.swift` (the `downloadManager` property and `init`, lines ~21–43; the `DeviceTiltObserver` call, line ~56)
- Modify: `DionysusPlayer/Core/Playback/PlaybackSegment.swift` (`init(downloaded:)` and the private `Kind` extension)
- Modify: `DionysusPlayer/Core/Playback/Chapter.swift` (`init(downloaded:)`)
- Modify: `DionysusPlayer/Core/Networking/JellyfinAPIClient.swift` (`downloadStreamURL`, lines ~859–942)
- Modify: `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift:754` (`canStartPictureInPictureAutomaticallyFromInline`)
- Modify: `DionysusPlayer/Features/Player/PlayerViewModel.swift` (the init split; offline branches)
- Modify: `DionysusPlayerTests/Core/Networking/JellyfinAPIClientTests.swift` (the `downloadStreamURL` section, line ~965)
- Modify: `DionysusPlayerTests/Features/Player/ASSSubtitleMappingTests.swift` (the "Downloaded sidecar mapping" section, line ~197)
- Test: the existing `DionysusPlayerTests`, plus one new test in `PlayerViewModelTests.swift`

**Interfaces:**
- Produces: the `DOWNLOADS` condition. `PlayerViewModel.init(client:userID:itemID:engine:startFromBeginning:mediaSourceID:trackPreferenceStore:nextUpPreferenceStore:streamPreferenceStore:playbackQueue:)` is available on every platform. The download-taking `convenience init(... downloadedItem:downloadStore: ...)` exists only `#if DOWNLOADS`. `PlayerViewModel.isOfflinePlayback` exists on every platform.

- [ ] **Step 1: Add the condition to both iOS targets in `project.yml`**

Under `targets.DionysusPlayer.settings.base`, and under `targets.DionysusPlayerTests.settings.base`:

```yaml
        # Offline downloads exist only on iOS. Shared code guards its download
        # paths with `#if DOWNLOADS`; the tvOS targets never define it.
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) DOWNLOADS"
```

Run: `xcodegen generate`

- [ ] **Step 2: Write the failing test for the platform-neutral init**

Append to `DionysusPlayerTests/Features/Player/PlayerViewModelTests.swift`, inside the class. Use the file's existing helpers for the client and engine; `makeClient()` and `FakePlaybackEngine()` are what the other tests use. Check the file's top and match it.

```swift
    /// The download-free designated init is the one tvOS builds against, so it
    /// must stay callable without naming any Downloads type, and must never
    /// report an offline session.
    func test_designatedInit_withoutDownloadParameters_isNotOffline() {
        let viewModel = PlayerViewModel(
            client: makeClient(), userID: "user", itemID: "item",
            engine: FakePlaybackEngine(), playbackQueue: []
        )
        XCTAssertFalse(viewModel.isOfflinePlayback)
    }
```

- [ ] **Step 3: Run it to confirm it compiles and passes against today's init**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/PlayerViewModelTests/test_designatedInit_withoutDownloadParameters_isNotOffline`

Expected: PASS. Today's init defaults the download parameters. The test guards the split in Step 4.

- [ ] **Step 4: Split `PlayerViewModel`'s init**

In `PlayerViewModel.swift`:

1. Replace the two stored properties:

```swift
    #if DOWNLOADS
    /// Set via the download-taking convenience `init`. When non-nil, `start()`,
    /// `stop()` and progress reporting route through the local-only offline paths.
    @ObservationIgnored private var downloadedItem: DownloadedItem?
    @ObservationIgnored private var downloadStore: DownloadStore?
    /// `true` for a session playing an offline download.
    var isOfflinePlayback: Bool { downloadedItem != nil }
    #else
    var isOfflinePlayback: Bool { false }
    #endif
```

2. Delete the `downloadedItem:`/`downloadStore:` parameters from the designated `init`, and the two assignments in its body.

3. After the designated `init`, add:

```swift
    #if DOWNLOADS
    /// The offline entry point: the same session, played from a download.
    convenience init(
        client: JellyfinAPIClient, userID: String, itemID: String, engine: PlaybackEngine,
        startFromBeginning: Bool = false, mediaSourceID: String? = nil,
        trackPreferenceStore: TrackPreferenceStore = TrackPreferenceStore(),
        nextUpPreferenceStore: NextUpPreferenceStore = NextUpPreferenceStore(),
        streamPreferenceStore: StreamPreferenceStore = StreamPreferenceStore(),
        downloadedItem: DownloadedItem?,
        downloadStore: DownloadStore?,
        playbackQueue: [MediaItem] = []
    ) {
        self.init(
            client: client, userID: userID, itemID: itemID, engine: engine,
            startFromBeginning: startFromBeginning, mediaSourceID: mediaSourceID,
            trackPreferenceStore: trackPreferenceStore,
            nextUpPreferenceStore: nextUpPreferenceStore,
            streamPreferenceStore: streamPreferenceStore,
            playbackQueue: playbackQueue
        )
        self.downloadedItem = downloadedItem
        self.downloadStore = downloadStore
    }
    #endif
```

4. Wrap each of these in `#if DOWNLOADS … #endif`. The spike branch shows the exact lines.
   - The `if let downloadedItem { await startOffline(…); return }` branch in `start(resumeSeconds:)`.
   - The whole block `startOffline` … `writeOfflineProgress` (doc comments included).
   - The `if let downloadedItem { … }` branch in `assScriptSource(for:)`.
   - The `if let downloadedItem { … }` branch in `fetchASSFonts()`.
   - `static func assFonts(fromDownloaded:)`.
   - The `if let downloadedItem { … writeOfflineProgress … return }` branch in `stop()`.

- [ ] **Step 5: Guard the other shared call sites**

`AppState.swift`:
- Wrap the `downloadManager` property and the existing `init` in `#if DOWNLOADS`.
- Add an `#else` init:

```swift
    #else
    init(sessionStore: ServerSessionStore = ServerSessionStore()) {
        self.sessionStore = sessionStore
    }
    #endif
```

- Wrap `Task { await DeviceTiltObserver.shared.warmUp() }` in `#if os(iOS)`.

The rest:
- `PlaybackSegment.swift`: wrap `init(downloaded:)` and the `private extension PlaybackSegment.Kind { init(downloadedKind:) }` in `#if DOWNLOADS`.
- `Chapter.swift`: wrap `init(downloaded:)` in `#if DOWNLOADS`.
- `JellyfinAPIClient.swift`: wrap `downloadStreamURL(…)` and its doc comment in `#if DOWNLOADS`.
- `AetherPlaybackEngine.swift`: wrap `controller?.canStartPictureInPictureAutomaticallyFromInline = true` in `#if os(iOS)`.
- `JellyfinAPIClientTests.swift`: wrap the `// MARK: downloadStreamURL` section, up to the next `// MARK:`, in `#if DOWNLOADS`.
- `ASSSubtitleMappingTests.swift`: wrap the `// MARK: - Downloaded sidecar mapping` section and its tests in `#if DOWNLOADS`.

`PlayerView.swift` (iOS only) keeps calling the download-taking init unchanged, because it passes `downloadedItem:` and `downloadStore:`.

- [ ] **Step 6: Run the whole iOS unit suite**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` with 0 failures. The count is one more than `develop`'s, from Step 2.

- [ ] **Step 7: Commit, after Benjamin signs off on the diff**

```bash
git switch -c feature/tvos-foundation develop
git add project.yml DionysusPlayer DionysusPlayerTests
git commit -m "Put shared download paths behind a DOWNLOADS condition

The tvOS app shares Core, AppState and the view models but has no
downloads. Only the iOS targets define DOWNLOADS; PlayerViewModel gains a
download-free designated init with the offline one as an iOS-only
convenience init.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `DionysusTV` app target, tvOS unit tests, and CI

**Files:**
- Modify: `project.yml` (new targets `DionysusTV` and `DionysusTVTests`; new scheme `DionysusTV`)
- Create: `DionysusTV/DionysusTVApp.swift`
- Create: `TestPlans/TVUnitTests.xctestplan`
- Modify: `.github/workflows/pr-checks.yml` (new job `tvos-build`)
- Modify: `README.md`, `TESTING.md`, `CLAUDE.md` (a short tvOS section: target, floor, `DOWNLOADS`, commands)
- Test: `DionysusTVTests`, which reuses the shared test files

**Interfaces:**
- Consumes: the `DOWNLOADS` condition from Task 1.
- Produces:
  - The scheme `DionysusTV`.
  - The test plan `TVUnitTests`.
  - `DionysusTVApp`, whose `@State var appState = AppState()` is injected as `.environment(appState)`.
  - `TVRootView`, which switches on `appState.phase`. Task 4 fills its cases.

- [ ] **Step 1: Add the targets to `project.yml`**

Insert before `DionysusPlayerTests:`:

```yaml
  # The Apple TV app: its own UI under DionysusTV/, on the iOS app's Core,
  # AppState and view models. Downloads are left out (no DOWNLOADS condition);
  # see docs/superpowers/specs/2026-09-29-tvos-app-design.md.
  DionysusTV:
    type: application
    platform: tvOS
    deploymentTarget: "26.0"
    sources:
      - path: DionysusTV
      - path: DionysusPlayer/Core
        excludes:
          - "Downloads/**"
          - "Persistence/Download*.swift"
      - path: DionysusPlayer/App/AppState.swift
      - path: DionysusPlayer/Shared
        includes:
          - "BrandColors.swift"
          - "AppVersion.swift"
          - "AppVersionInfo.swift"
          - "Accessibility/**"
          - "Components/AsyncRemoteImage.swift"
          - "Components/LogoImageView.swift"
          - "Components/MediaPlaceholderBox.swift"
          - "Components/ArtworkShape.swift"
          - "Navigation/AppRoute.swift"
      - path: DionysusPlayer/Features
        includes:
          - "**/*ViewModel.swift"
          - "Home/DynamicRailCandidate.swift"
          - "Player/PlaybackSessionOutcome.swift"
          - "Player/PlaybackRequest.swift"
        excludes:
          - "Downloads/**"
      - path: DionysusPlayer/Resources/Assets.xcassets
      - path: DionysusPlayer/Resources/Localizable.xcstrings
    dependencies:
      - package: AetherEngine
        product: AetherEngine
      - package: SwiftUIShimmer
        product: Shimmer
      - package: SwiftAssRenderer
        product: SwiftAssRenderer
      - package: SwiftLibass
        product: SwiftLibass
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.imbenjamin.dionysusplayer
        PRODUCT_NAME: Dionysus
        TARGETED_DEVICE_FAMILY: "3"
        SWIFT_EMIT_LOC_STRINGS: YES
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    info:
      path: Generated/Info-tvOS.plist
      properties:
        CFBundleDisplayName: Dionysus
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        LSApplicationCategoryType: public.app-category.entertainment
        ITSAppUsesNonExemptEncryption: false
        UIUserInterfaceStyle: Dark
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        NSLocalNetworkUsageDescription: "Dionysus looks for and connects to your Jellyfin media server on your local network."
        NSBonjourServices:
          - _jellyfin._tcp

  DionysusTVTests:
    type: bundle.unit-test
    platform: tvOS
    deploymentTarget: "26.0"
    sources:
      - path: DionysusPlayerTests
        includes:
          - "Support/**"
          - "App/AppStateTests.swift"
          - "Core/Networking/**"
          - "Core/Models/**"
          - "Core/Playback/**"
          - "Core/Persistence/**"
          - "Features/Home/**"
          - "Features/Collection/**"
          - "Features/AssetDetails/**"
          - "Features/Search/**"
          - "Features/ServerSetup/**"
          - "Features/Login/**"
          - "Features/Profile/**"
          - "Features/Player/PlaybackRequestTests.swift"
          - "Features/Player/PlayerViewModelTests.swift"
          - "Features/Player/ASSSubtitleMappingTests.swift"
          - "Shared/AppVersionInfoTests.swift"
        excludes:
          - "Core/Persistence/Download*.swift"
    dependencies:
      - target: DionysusTV
    settings:
      base:
        GENERATE_INFOPLIST_FILE: true
        PRODUCT_BUNDLE_IDENTIFIER: com.imbenjamin.dionysusplayer.tvtests
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Dionysus.app/Dionysus"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

Under `schemes:` add:

```yaml
  DionysusTV:
    build:
      targets:
        DionysusTV: all
        DionysusTVTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      testPlans:
        - path: TestPlans/TVUnitTests.xctestplan
          defaultPlan: true
    archive:
      config: Release
```

- [ ] **Step 2: Create the test plan**

`TestPlans/TVUnitTests.xctestplan`:

```json
{
  "configurations" : [
    {
      "id" : "9A1C0E2B-0000-4000-9000-0000000000A1",
      "name" : "Configuration 1",
      "options" : {

      }
    }
  ],
  "defaultOptions" : {
    "targetForVariableExpansion" : {
      "containerPath" : "container:DionysusPlayer.xcodeproj",
      "identifier" : "DionysusTV",
      "name" : "DionysusTV"
    }
  },
  "testTargets" : [
    {
      "target" : {
        "containerPath" : "container:DionysusPlayer.xcodeproj",
        "identifier" : "DionysusTVTests",
        "name" : "DionysusTVTests"
      }
    }
  ],
  "version" : 1
}
```

- [ ] **Step 3: Create the minimal app shell**

`DionysusTV/DionysusTVApp.swift`:

```swift
import SwiftUI

@main
struct DionysusTVApp: App {
    @State private var appState = AppState()

    init() {
        #if DEBUG
        UITestHarness.installIfNeeded()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(appState)
                .task { await appState.start() }
        }
    }
}

/// Where the user is in the app: `AppState.phase`, as on iOS. Task 4 replaces
/// the placeholders with the onboarding screens and the browse launcher.
struct TVRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isRestoringSession {
                ProgressView()
            } else {
                switch appState.phase {
                case .serverSetup: Text("Find Your Server")
                case .login: Text("Who's Watching?")
                case .main: Text("Home")
                }
            }
        }
    }
}
```

- [ ] **Step 4: Build, and run the tvOS unit tests**

Run:
```bash
xcodegen generate
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0'
```

Expected: `** TEST SUCCEEDED **`.

A shared test file that fails to compile on tvOS has two fixes:
- If it tests iOS-only behaviour, drop it from `includes` and record the reason in a comment beside the list.
- If only part of it touches Downloads, wrap that part in `#if DOWNLOADS`.

Don't change a test's assertions to make it pass on tvOS.

- [ ] **Step 5: Add the CI job**

Append a job to `.github/workflows/pr-checks.yml`, beside `release-build`. **Don't** add it to the branch rulesets in this PR; Benjamin does that once it has been green a few times. Record this in `TESTING.md`.

```yaml
  tvos-build:
    # Not a required check yet: added to the rulesets once it has proven
    # stable. Renaming it after that needs the rulesets updated first.
    name: tvOS build and unit tests
    runs-on: macos-26
    timeout-minutes: 45
    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Set up iOS project
        uses: ./.github/actions/setup-ios-project

      - name: List tvOS runtimes
        run: xcrun simctl list runtimes | grep -i tvos || (echo "::error::No tvOS runtime on this image" && exit 1)

      - name: Build and test (tvOS)
        run: |
          set -o pipefail
          xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
            -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
            -resultBundlePath .build/TVTestResults.xcresult | tail -200

      - name: Upload test results
        if: failure()
        uses: actions/upload-artifact@v7
        with:
          name: tvos-test-results
          path: .build/TVTestResults.xcresult
          retention-days: 7
          if-no-files-found: ignore
```

- [ ] **Step 6: Document it**

- **`CLAUDE.md`:** add a "tvOS app" subsection under "What this is". Cover the target, the tvOS 26 floor, the `DOWNLOADS` rule, the scheme and test plan names, and the spec link.
- **`TESTING.md`:** add `TVUnitTests` and the non-required CI job.
- **`README.md`:** add a one-line mention and the build command.

- [ ] **Step 7: Commit, after sign-off**

```bash
git add project.yml DionysusTV TestPlans/TVUnitTests.xctestplan .github/workflows/pr-checks.yml README.md TESTING.md CLAUDE.md
git commit -m "Add the DionysusTV target, its unit tests and a CI job

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: tvOS UI test target driven by the Siri Remote

**Files:**
- Modify: `project.yml` (new target `DionysusTVUITests`; add it to the `DionysusTV` scheme)
- Create: `DionysusTVUITests/Support/TVUITestCase.swift`
- Create: `DionysusTVUITests/LaunchJourneyTests.swift`
- Create: `TestPlans/TVUITests.xctestplan`
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (add `A11yID.TV`)

**Interfaces:**
- Produces:
  - `TVUITestCase.launch(scenario:seedSession:extraArguments:) -> XCUIApplication`.
  - `TVUITestCase.press(_:times:)`.
  - `A11yID.TV.Onboarding.findServerTitle`, `A11yID.TV.Main.root`, and `A11yID.TV.Player.transport`.

- [ ] **Step 1: Add the identifiers**

In `AccessibilityIdentifiers.swift`, inside `enum A11yID`:

```swift
    /// The Apple TV app's identifiers. Never on a screen-root container (see the
    /// file's header); each sits on a concrete element inside the screen.
    enum TV {
        enum Onboarding {
            static let findServerTitle = "tv.onboarding.findServer.title"
            static func serverRow(_ id: String) -> String { "tv.onboarding.server.\(id)" }
            static let whosWatchingTitle = "tv.onboarding.whosWatching.title"
            static func user(_ id: String) -> String { "tv.onboarding.user.\(id)" }
        }
        enum Main {
            static let root = "tv.main.firstRail"
            static func tile(_ itemID: String) -> String { "tv.main.tile.\(itemID)" }
        }
        enum Player {
            static let transport = "tv.player.transport"
            static let titleBlock = "tv.player.title"
            static let elapsed = "tv.player.elapsed"
            static let formatLabel = "tv.player.format"
        }
    }
```

- [ ] **Step 2: Add the target**

In `project.yml`:

```yaml
  DionysusTVUITests:
    type: bundle.ui-testing
    platform: tvOS
    deploymentTarget: "26.0"
    sources:
      - path: DionysusTVUITests
      - path: DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift
      - path: DionysusPlayer/Core/UITestSupport/UITestFixtureIdentity.swift
    dependencies:
      - target: DionysusTV
    settings:
      base:
        GENERATE_INFOPLIST_FILE: true
        PRODUCT_BUNDLE_IDENTIFIER: com.imbenjamin.dionysusplayer.tvuitests
        TEST_TARGET_NAME: DionysusTV
```

Then:
- Add `DionysusTVUITests: [test]` to the `DionysusTV` scheme's build targets.
- Add `- path: TestPlans/TVUITests.xctestplan` to its `testPlans`.
- Write `TestPlans/TVUITests.xctestplan` in the same shape as Task 2 Step 2, targeting `DionysusTVUITests`, with id `9A1C0E2B-0000-4000-9000-0000000000A2`.

- [ ] **Step 3: Write the base class**

`DionysusTVUITests/Support/TVUITestCase.swift`:

```swift
import XCTest

/// Launches the TV app against the in-process stub server (the same
/// `UITestHarness` the iOS suite uses) and drives it with the Siri Remote.
class TVUITestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @discardableResult
    func launch(scenario: String = "standard", seedSession: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestMode", "YES",
            "-UITestScenario", scenario,
            "-UITestResetState", "YES",
            "-UITestDisableAnimations", "YES",
            "-onboarding.welcomeCompleted", "YES"
        ] + (seedSession ? ["-UITestSeedSession", "YES"] : []) + extraArguments
        app.launch()
        return app
    }

    func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times { XCUIRemote.shared.press(button) }
    }
}
```

- [ ] **Step 4: Write the failing journey**

`DionysusTVUITests/LaunchJourneyTests.swift`:

```swift
import XCTest

final class LaunchJourneyTests: TVUITestCase {
    /// A fresh install lands on Find Your Server.
    func test_freshLaunch_showsFindYourServer() {
        let app = launch()
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.findServerTitle].waitForExistence(timeout: 10))
    }
}
```

- [ ] **Step 5: Run it and confirm it fails**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUITests -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0'`

Expected: FAIL, because the placeholder `Text("Find Your Server")` carries no identifier.

- [ ] **Step 6: Make it pass with a temporary identifier on the placeholder**

In `TVRootView`, change `case .serverSetup: Text("Find Your Server")` to:

```swift
                case .serverSetup:
                    Text("Find Your Server").accessibilityIdentifier(A11yID.TV.Onboarding.findServerTitle)
```

Task 4 moves the identifier onto the real title.

- [ ] **Step 7: Run it and confirm it passes, then commit after sign-off, then open PR 1**

Run the Step 5 command. Expected: PASS.

```bash
git add project.yml DionysusTVUITests TestPlans/TVUITests.xctestplan DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusTV TESTING.md
git commit -m "Add Siri Remote UI tests for the tvOS app

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Then push, and open PR 1 against `develop` with a skimmable body ending in the "Generated with Claude Code" line. Push only after Benjamin says so.

---

### Task 4: Onboarding: server setup, sign-in and Quick Connect

This task is functional only; visual polish to the prototype comes in Milestone 2.

**Files:**
- Create: `DionysusTV/Onboarding/TVBrandBackground.swift`
- Create: `DionysusTV/Onboarding/TVServerSetupView.swift`
- Create: `DionysusTV/Onboarding/TVLoginView.swift`
- Create: `DionysusTV/Onboarding/TVQuickConnectView.swift`
- Modify: `DionysusTV/DionysusTVApp.swift` (the `TVRootView` cases)
- Test: `DionysusTVUITests/OnboardingJourneyTests.swift`

**Interfaces:**
- Consumes (all unchanged):
  - `ServerSetupViewModel()`: `discoveredServers`, `connect(to:)`, `testConnection()`, `address`, `canSubmit`, `startScanOnArrival()`.
  - `LoginViewModel()`: `load(using:)`, `usersState`, `choose(_:using:)`, `selectedUser`, `selectedUserPassword`, `signInSelectedUser(using:)`, `isQuickConnectAvailable`.
  - `QuickConnectViewModel(client:)`: `run(signIn:)`.
  - `AppState.completeServerSetup(_:)` and `AppState.signInWithQuickConnect(secret:)`.
- Produces: `TVServerSetupView`, `TVLoginView`, `TVQuickConnectView`.

- [ ] **Step 1: Write the failing journey**

`DionysusTVUITests/OnboardingJourneyTests.swift`:

```swift
import XCTest

final class OnboardingJourneyTests: TVUITestCase {
    /// Discovery lists the stub server with default focus on it, so one Select
    /// connects; the stub's public user list then shows, and choosing the
    /// passwordless user signs straight in.
    func test_selectDiscoveredServer_thenUser_reachesMain() {
        let app = launch()
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(server.hasFocus, "The first discovered server must take default focus")
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Main.root].waitForExistence(timeout: 10))
    }
}
```

`UITestFixtureIdentity.discoveredServerID` is the id `UITestServerDiscovery` reports for the stub server.

If the stub's default user has a password, choose the scenario whose user signs in on one Select. `UITestScenario` lists them. Don't change the stub.

- [ ] **Step 2: Run it and confirm it fails**

Run: `xcodebuild test … -testPlan TVUITests -only-testing:DionysusTVUITests/OnboardingJourneyTests`
Expected: FAIL, because the placeholders have no buttons.

- [ ] **Step 3: Implement the views**

Port the spike's `DionysusTV/TVOnboardingViews.swift` into the four files above, with these corrections from the spike's findings:

- **`TVServerSetupView`:**
  - `@FocusState private var focusedServer: DiscoveredServer.ID?`, with `.defaultFocus($focusedServer, viewModel.discoveredServers.first?.id)` on the list's container.
  - Each server row is a `Button` with `.accessibilityIdentifier(A11yID.TV.Onboarding.serverRow(server.id))`.
  - The title carries `A11yID.TV.Onboarding.findServerTitle`.
- **`TVLoginView`:**
  - Each user is a `Button { … } label: { avatar + name }` with `.buttonStyle(.card)`, **not** `.borderless`, which shows no focus.
  - Each carries `.accessibilityIdentifier(A11yID.TV.Onboarding.user(user.id))`.
  - The title carries `whosWatchingTitle`.
  - Quick Connect opens as a `.fullScreenCover`. That's acceptable here because it isn't the player.
- **Copy:**
  - The Quick Connect instruction is the iOS string: "On a device already signed in to \(serverName), open Quick Connect and enter this code."
  - No menu path, per the product rule.
- **`TVBrandBackground`:** the spike's `MeshGradient`, unchanged.

In `TVRootView`, replace the placeholders:
- `.serverSetup` → `TVServerSetupView()`
- `.login` → `TVLoginView()`
- `.main` → `TVBrowseLauncher()`, from Task 5. Until then, `Text("Home").accessibilityIdentifier(A11yID.TV.Main.root)`.

- [ ] **Step 4: Run the journey and confirm it passes**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit, after sign-off**

```bash
git switch -c feature/tvos-onboarding develop   # after PR 1 merges
git add DionysusTV DionysusTVUITests
git commit -m "Add tvOS onboarding on the shared setup and sign-in view models

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Browse launcher, and the cancelled-first-load fix in `HomeViewModel`

**Files:**
- Modify: `DionysusPlayer/Features/Home/HomeViewModel.swift` (`load()`'s cancellation handling)
- Test: `DionysusPlayerTests/Features/Home/HomeViewModelTests.swift` (new test; it runs on both platforms)
- Create: `DionysusTV/Browse/TVBrowseLauncher.swift`
- Modify: `DionysusTV/DionysusTVApp.swift`
- Test: `DionysusTVUITests/BrowseJourneyTests.swift`

**Interfaces:**
- Consumes: `HomeViewModel(client:userID:)`, `rails`, `loadIfNeeded()`, `MediaItem.primaryImageURL`, and `AsyncRemoteImage(url:placeholderSystemImage:)`.
- Produces:
  - `TVBrowseLauncher(client:userID:)`: rails of tiles. Selecting one calls `TVPlayerPresenter.present(item:client:userID:)` from Task 6. Until Task 6 exists, selection is a no-op.

- [ ] **Step 1: Write the failing unit test**

In `HomeViewModelTests.swift`, reuse the file's stub helpers. The test must make the first request block until the task is cancelled; `MockURLProtocol` supports a handler that awaits. Follow how the file's existing slow-server tests do it.

```swift
    /// A tvOS tab rebuild cancels the first `.task` mid-request. That must not
    /// leave `.loading` behind, or `loadIfNeeded()` skips forever and Home
    /// stays empty (spike finding, 2026-09-28).
    func test_cancelledFirstLoad_returnsToIdle_soLoadIfNeededRetries() async {
        let viewModel = makeViewModel(respondingSlowly: true)
        let task = Task { await viewModel.loadIfNeeded() }
        await waitUntil { viewModel.loadState == .loading }
        task.cancel()
        await task.value
        XCTAssertEqual(viewModel.loadState, .idle)
    }
```

If `makeViewModel(respondingSlowly:)` and `waitUntil` don't exist under those names, use the file's equivalents; `AsyncTestHelpers.swift` has the waiting helper. Add a `respondingSlowly` parameter to the file's factory only if nothing equivalent exists.

- [ ] **Step 2: Run it and confirm it fails**

Run: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/HomeViewModelTests/test_cancelledFirstLoad_returnsToIdle_soLoadIfNeededRetries`
Expected: FAIL, because `loadState` stays `.loading`.

- [ ] **Step 3: Fix it**

In `HomeViewModel`'s full-load path, the function that calls `setLoadState(.loading)` and then awaits the requests, catch cancellation and reset:

```swift
        } catch is CancellationError {
            // Superseded rather than failed: a later `loadIfNeeded()` must run.
            setLoadState(.idle)
            return
        } catch let error as URLError where error.code == .cancelled {
            setLoadState(.idle)
            return
        }
```

Put these two `catch` clauses before the existing generic `catch`, which sets `.failed`.

- [ ] **Step 4: Run it and confirm it passes, then run it on tvOS too**

Run the Step 2 command, then:

```bash
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' \
  -only-testing:DionysusTVTests/HomeViewModelTests
```

Expected: PASS on both.

- [ ] **Step 5: Write the failing browse journey**

`DionysusTVUITests/BrowseJourneyTests.swift`:

```swift
import XCTest

final class BrowseJourneyTests: TVUITestCase {
    /// A signed-in launch shows the rails, and the playback fixture's tile is
    /// focusable from the remote.
    func test_signedIn_showsRailsWithPrimaryMovie() {
        let app = launch(seedSession: true)
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
    }
}
```

- [ ] **Step 6: Implement `TVBrowseLauncher`**

`DionysusTV/Browse/TVBrowseLauncher.swift` is a temporary browse surface that Milestone 3 replaces with the prototype's Home.

```swift
import SwiftUI

/// A plain vertical stack of `HomeViewModel`'s rails, enough to reach playback
/// from the remote. Milestone 3 replaces it with the prototype's Home.
struct TVBrowseLauncher: View {
    let client: JellyfinAPIClient
    let userID: String
    @State private var viewModel: HomeViewModel

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
        _viewModel = State(initialValue: HomeViewModel(client: client, userID: userID))
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 50) {
                ForEach(Array(viewModel.rails.enumerated()), id: \.element.id) { index, rail in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(rail.title).font(.headline)
                            .accessibilityIdentifier(index == 0 ? A11yID.TV.Main.root : "")
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 48) {
                                ForEach(rail.items) { item in
                                    Button {
                                        TVPlayerPresenter.present(item: item, client: client, userID: userID)
                                    } label: {
                                        AsyncRemoteImage(url: item.primaryImageURL, placeholderSystemImage: item.kind.placeholderSystemImage)
                                            .frame(width: 250, height: 375)
                                    }
                                    .buttonStyle(.card)
                                    .accessibilityIdentifier(A11yID.TV.Main.tile(item.id))
                                }
                            }
                            .padding(.vertical, 30)
                        }
                        .scrollClipDisabled()
                    }
                    .focusSection()
                }
            }
        }
        .task { await viewModel.loadIfNeeded() }
    }
}
```

Until Task 6 lands, temporarily define `enum TVPlayerPresenter { static func present(item: MediaItem, client: JellyfinAPIClient, userID: String) {} }` in this file. Task 6 deletes it.

In `TVRootView`, `.main` becomes:

```swift
                case .main:
                    if let client = appState.apiClient, let userID = appState.currentUser?.id {
                        TVBrowseLauncher(client: client, userID: userID)
                    }
```

- [ ] **Step 7: Run the browse and onboarding journeys and confirm they pass; then commit after sign-off and open PR 2**

Run: `xcodebuild test … -testPlan TVUITests`. Expected: all pass.

```bash
git add DionysusPlayer/Features/Home/HomeViewModel.swift DionysusPlayerTests/Features/Home/HomeViewModelTests.swift DionysusTV DionysusTVUITests TESTING.md
git commit -m "Retry Home's first load after cancellation; add the tvOS browse launcher

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The AVKit player host

**Files:**
- Modify: `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift`:
  - `init(ownsNowPlayingSession: Bool = true)`.
  - A tvOS-only `var hostEngine: AetherEngine`.
  - `setNowPlayingInfo` returns early when the engine doesn't own the session.
- Create: `DionysusTV/Player/TVPlayerSurfacePolicy.swift`
- Create: `DionysusTV/Player/TVPlayerHostController.swift`
- Create: `DionysusTV/Player/TVPlayerPresenter.swift`
- Delete: the temporary `TVPlayerPresenter` stub from Task 5
- Test: `DionysusTVTests/TVPlayerSurfacePolicyTests.swift`. Add `- path: DionysusTVTests` to the `DionysusTVTests` target's sources in `project.yml`, and make it the folder for TV-only unit tests.
- Modify: `DionysusPlayer/Core/UITestSupport/UITestConfiguration.swift` and `UITestStubURLProtocol.swift` (the `slowPlaybackInfo` scenario)
- Test: `DionysusTVUITests/PlayerJourneyTests.swift`

**Interfaces:**
- Consumes:
  - `PlaybackEngineFactory.make()`, which is a `PreviewPlaybackEngine` under the harness.
  - `PlayerViewModel(client:userID:itemID:engine:…)`, `start()`, `stop()`, `togglePlayPause()`, `seek(to:)`, `currentTime`, `duration` and `state`.
- Produces:
  - `TVPlayerPresenter.present(item: MediaItem, client: JellyfinAPIClient, userID: String)`.
  - `TVPlayerHostController(viewModel:engine:overlay:)`.
  - `TVPlayerSurfacePolicy.surface(nativePlayerAvailable: Bool) -> TVPlayerSurface`.

- [ ] **Step 1: Write the failing policy tests**

`DionysusTVTests/TVPlayerSurfacePolicyTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVPlayerSurfacePolicyTests: XCTestCase {
    /// Native route: AVKit renders the engine's AVPlayer, and the engine's own
    /// view must leave the stack, or its layer covers the video (spike:
    /// sound, mode switch, black picture).
    func test_nativeRoute_handsPlayerToAVKit_andHidesEngineView() {
        XCTAssertEqual(
            TVPlayerSurfacePolicy.surface(nativePlayerAvailable: true),
            TVPlayerSurface(avKitRendersPlayer: true, engineViewVisible: false)
        )
    }

    /// Software route: no AVPlayer exists, so AVKit must drop its player (or
    /// it draws a spinner over the frames) and the engine view renders.
    func test_softwareRoute_clearsAVKitPlayer_andShowsEngineView() {
        XCTAssertEqual(
            TVPlayerSurfacePolicy.surface(nativePlayerAvailable: false),
            TVPlayerSurface(avKitRendersPlayer: false, engineViewVisible: true)
        )
    }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `xcodegen generate && xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -only-testing:DionysusTVTests/TVPlayerSurfacePolicyTests`
Expected: a compile FAIL, because `TVPlayerSurfacePolicy` is undefined.

- [ ] **Step 3: Implement the policy**

`DionysusTV/Player/TVPlayerSurfacePolicy.swift`:

```swift
/// Which surface draws the picture for the engine's current route. Applied on
/// every `$currentAVPlayer` emission, not just the first: an audio reload
/// re-emits, and an escalation can move native to software mid-session.
struct TVPlayerSurface: Equatable {
    let avKitRendersPlayer: Bool
    let engineViewVisible: Bool
}

enum TVPlayerSurfacePolicy {
    static func surface(nativePlayerAvailable: Bool) -> TVPlayerSurface {
        TVPlayerSurface(avKitRendersPlayer: nativePlayerAvailable, engineViewVisible: !nativePlayerAvailable)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Add the engine hooks**

In `AetherPlaybackEngine.swift`:

```swift
    /// `ownsNowPlayingSession: false` is the AVPlayerViewController host's
    /// setting: AVKit owns Now Playing there, and a second owner breaks it.
    init(ownsNowPlayingSession: Bool = true) throws {
        self.engine = try AetherEngine()
        pipDelegateProxy.engine = self
        engine.ownsVideoNowPlayingSession = ownsNowPlayingSession
        observeEngine()
        observeAppLifecycle()
    }
```

Keep the existing doc comment on `ownsVideoNowPlayingSession` above the assignment, and add one line for the tvOS case.

Then add:

```swift
    #if os(tvOS)
    /// The tvOS player host binds the engine's own view on the software route
    /// and hands `$currentAVPlayer` to AVKit on the native one. The protocol
    /// keeps AetherEngine out of feature code; this is the one door.
    var hostEngine: AetherEngine { engine }
    #endif
```

At the top of `setNowPlayingInfo(title:subtitle:artwork:)`:

```swift
        // Under an AVPlayerViewController host AVKit owns Now Playing.
        guard engine.ownsVideoNowPlayingSession else { return }
```

- [ ] **Step 6: Write the failing player journey**

`DionysusTVUITests/PlayerJourneyTests.swift`:

```swift
import XCTest

final class PlayerJourneyTests: TVUITestCase {
    /// Select on a tile opens the player (fake engine under the harness),
    /// Play/Pause and Right reach our handlers, and Menu dismisses back to the
    /// tile with the engine stopped.
    func test_openPlayer_skipForward_menuDismisses() {
        let app = launch(seedSession: true, extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        while !tile.hasFocus { press(.right) }
        press(.select)

        let elapsed = app.staticTexts[A11yID.TV.Player.elapsed]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        let before = elapsed.label
        press(.right)
        XCTAssertTrue(NSPredicate(format: "label != %@", before).evaluate(with: elapsed) ||
                      elapsed.waitForExistence(timeout: 2))

        press(.menu)
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertFalse(elapsed.exists)
    }

    /// Menu while the item is still loading must stop and dismiss, leaving no
    /// session behind (Review Focus 4).
    func test_menuDuringLoading_dismisses() {
        let app = launch(scenario: "slowPlaybackInfo", seedSession: true)
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        while !tile.hasFocus { press(.right) }
        press(.select)
        press(.menu)
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
    }
}
```

About the second test:
- It needs a new `UITestScenario` case, `slowPlaybackInfo`, which delays `/PlaybackInfo` by 30s in `UITestStubURLProtocol`. Model it on the existing `slowLogoImage` / `slowVideoDownload` cases, and add it to TESTING.md's scenario list.
- The test passes the scenario through `launch(scenario: "slowPlaybackInfo", seedSession: true)`, not through `extraArguments`.

- [ ] **Step 7: Run the journey and confirm it fails**

Run: `xcodebuild test … -testPlan TVUITests -only-testing:DionysusTVUITests/PlayerJourneyTests`
Expected: FAIL, because nothing presents yet.

- [ ] **Step 8: Implement the host and the presenter**

`DionysusTV/Player/TVPlayerHostController.swift` is the spike's `TVPlayerHostController`, productionised:

- **Drop the host modes.** It is always the AVKit host.
- **With an `AetherPlaybackEngine`**, bind as the spike does:
  - `showsPlaybackControls = true`, `appliesPreferredDisplayCriteriaAutomatically = false`, `playbackControlsIncludeInfoViews = false` and `contextualActions = []`.
  - An `AetherPlayerView` goes in `contentOverlayView` at index 0.
  - Subscribe to `hostEngine.$currentAVPlayer` and apply `TVPlayerSurfacePolicy.surface(nativePlayerAvailable: avPlayer != nil)` on **every** emission:
    - When `avKitRendersPlayer`, set `player = avPlayer` and stamp `externalMetadata` (title).
    - Otherwise set `player = nil`.
    - Set `aetherView.isHidden = !engineViewVisible`, and bind or unbind the view to match.
- **With a fake engine** (`PreviewPlaybackEngine` under the harness), skip AVKit binding. Embed `engine.makeSurface()` in a `UIHostingController` behind the overlay.
- **Remote:**
  - One `UITapGestureRecognizer` per press type: `.select` (show chrome), `.playPause`, `.leftArrow` (−10s), `.rightArrow` (+10s) and `.menu` (close).
  - In `viewDidAppear`, disable AVKit's own recognizers and hide AVKit's chrome by class name, as the spike's `suppressAVKitGestures`/`hideAVKitChrome` do. Keep the spike's comment that this keys off private class names.
  - Re-run the chrome hiding in `viewDidLayoutSubviews`.
- **`close()`:** `Task { await viewModel.stop() }` **before** `dismiss(animated:)`. It must work in any `viewModel.state`, `.loading` included.
- **Overlay:** a `UIHostingController` over everything, with `isUserInteractionEnabled = false`. Task 8 supplies the view; for now pass a minimal `TVTransportOverlay` that shows `Text(elapsed)` with `A11yID.TV.Player.elapsed`.

`DionysusTV/Player/TVPlayerPresenter.swift`:

```swift
import UIKit

/// Presents the player with UIKit, never `fullScreenCover`, which takes the
/// Menu press away from the controller.
enum TVPlayerPresenter {
    @MainActor
    static func present(item: MediaItem, client: JellyfinAPIClient, userID: String) {
        let engine: PlaybackEngine
        #if DEBUG
        if UITestConfiguration.isActive {
            engine = (try? PlaybackEngineFactory.make()) ?? PreviewPlaybackEngine()
        } else {
            guard let real = try? AetherPlaybackEngine(ownsNowPlayingSession: false) else { return }
            engine = real
        }
        #else
        guard let real = try? AetherPlaybackEngine(ownsNowPlayingSession: false) else { return }
        engine = real
        #endif
        let viewModel = PlayerViewModel(client: client, userID: userID, itemID: item.playableItemID, engine: engine)
        let host = TVPlayerHostController(viewModel: viewModel, engine: engine)
        host.modalPresentationStyle = .fullScreen
        topViewController()?.present(host, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
```

**`item.playableItemID`:** a Series must resolve to an episode before playback (spike finding). If `MediaItem` has no such property, the launcher calls `PlaybackRequest`'s existing resolution, which is what iOS's hero Play uses; check `PlaybackRequest.swift`. For the launcher, which shows movies and episodes, `item.id` is correct, so use `item.id`. Leave a `// Milestone 3: resolve a Series via PlaybackRequest` note at the call site; there is no hero yet.

- [ ] **Step 9: Run the journeys and policy tests and confirm they pass**

Run: `xcodebuild test … -testPlan TVUITests` and `xcodebuild test … -scheme DionysusTV`. Expected: PASS.

- [ ] **Step 10: Check on the device (Benjamin watches the TV)**

Build and install on "Bedroom" (UDID `00008110-000158190A88201E`):

```bash
xcodebuild -project DionysusPlayer.xcodeproj -scheme DionysusTV -destination 'id=00008110-000158190A88201E' -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008110-000158190A88201E ~/Library/Developer/Xcode/DerivedData/DionysusPlayer-*/Build/Products/Debug-appletvos/Dionysus.app
xcrun devicectl device process launch --device 00008110-000158190A88201E --terminate-existing com.imbenjamin.dionysusplayer
```

Play four titles from the launcher: 3:10 to Yuma (native), 1917 (native HDR10), The Godfather Part III (AV1, software) and Moana (DV). Expected: **picture and sound on all four.** A black picture with sound means the engine view is covering AVKit's video; recheck Step 8's `isHidden` handling.

- [ ] **Step 11: Commit, after sign-off**

```bash
git switch -c feature/tvos-playback develop   # after PR 2 merges
git add DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift DionysusTV DionysusTVTests DionysusTVUITests project.yml
git commit -m "Add the tvOS AVKit player host for AetherEngine

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: HDR output on a real Apple TV

This task is investigation first. Steps 1–4 are code with tests. Steps 5–8 find and fix why the spike's Apple TV stayed in SDR. They are ordered cheapest first, and **stop at the first step that yields HDR**.

**Files:**
- Create: `DionysusPlayer/Core/Playback/DisplayContext.swift`, compiled on both platforms and inert on iOS
- Modify: `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift` (`load(...)` builds `LoadOptions` through a new pure `static func makeLoadOptions(...)`)
- Test: `DionysusPlayerTests/Core/Playback/AetherPlaybackEngineLoadOptionsTests.swift`, which runs on both platforms through the shared test includes (`Core/Playback/**`)

**Interfaces:**
- Produces:
  - `struct DisplayContext: Equatable { var matchContentEnabled: Bool; var panelIsInHDRMode: Bool }`.
  - `static func current() -> DisplayContext`.
  - `static let unknown = DisplayContext(matchContentEnabled: true, panelIsInHDRMode: false)`.
  - `AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: Bool, externalSubtitles: [ExternalSubtitleTrack], display: DisplayContext) -> LoadOptions`. Use the element type `load` already maps to via `makeExternalSubtitleTrack`.

- [ ] **Step 1: Write the failing tests**

`DionysusPlayerTests/Core/Playback/AetherPlaybackEngineLoadOptionsTests.swift`:

```swift
import XCTest
import AetherEngine
@testable import Dionysus

final class AetherPlaybackEngineLoadOptionsTests: XCTestCase {
    /// tvOS's Match Content setting and the panel's live HDR state reach the
    /// engine, as AetherEngine's "Host setup on tvOS" and Sodalite pass them.
    func test_displayContext_isPassedThrough() {
        let options = AetherPlaybackEngine.makeLoadOptions(
            isRemoteHLS: false, externalSubtitles: [],
            display: DisplayContext(matchContentEnabled: false, panelIsInHDRMode: true)
        )
        XCTAssertFalse(options.matchContentEnabled)
        XCTAssertTrue(options.panelIsInHDRMode)
        XCTAssertFalse(options.suppressDisplayCriteria, "The engine must stay the only criteria writer")
    }

    /// With no window to ask (Review Focus 2), the engine's own defaults apply:
    /// matching assumed on, panel state unproven.
    func test_unknownDisplay_keepsEngineDefaults() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: false, externalSubtitles: [], display: .unknown)
        XCTAssertTrue(options.matchContentEnabled)
        XCTAssertFalse(options.panelIsInHDRMode)
        XCTAssertTrue(options.attemptsHDRMasterOnUnprovenPanel)
    }

    /// The iOS behaviour is unchanged: the same remote-HLS and subtitle flags as before.
    func test_existingFlags_unchanged() {
        let options = AetherPlaybackEngine.makeLoadOptions(isRemoteHLS: true, externalSubtitles: [], display: .unknown)
        XCTAssertTrue(options.nativeRemoteHLS)
        XCTAssertTrue(options.prepareNativeSubtitles)
        XCTAssertFalse(options.isLive)
    }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `xcodebuild test … -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/AetherPlaybackEngineLoadOptionsTests`
Expected: a compile FAIL.

- [ ] **Step 3: Implement**

`DionysusPlayer/Core/Playback/DisplayContext.swift`:

```swift
import UIKit

/// What the host knows about the display at load time. On tvOS it feeds
/// AetherEngine's display-criteria handshake; on iOS it is always `.unknown`,
/// which reproduces the engine's defaults, so iOS behaviour is unchanged.
struct DisplayContext: Equatable {
    var matchContentEnabled: Bool
    var panelIsInHDRMode: Bool

    static let unknown = DisplayContext(matchContentEnabled: true, panelIsInHDRMode: false)

    @MainActor
    static func current() -> DisplayContext {
        #if os(tvOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // The key window, not `windows.first`: the player is presented modally and
        // the spike read Match Content inconsistently from an arbitrary window.
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
                ?? scenes.first?.windows.first else { return .unknown }
        return DisplayContext(
            matchContentEnabled: window.avDisplayManager.isDisplayCriteriaMatchingEnabled,
            // Headroom 1.0 is SDR; the epsilon dodges a boundary float glitch.
            panelIsInHDRMode: window.screen.currentEDRHeadroom > 1.001
        )
        #else
        return .unknown
        #endif
    }
}
```

In `AetherPlaybackEngine.swift`, move the `LoadOptions(...)` construction out of `load(...)` into:

```swift
    static func makeLoadOptions(isRemoteHLS: Bool, externalSubtitles: [ExternalSubtitleTrack], display: DisplayContext) -> LoadOptions {
        // Parameter order is LoadOptions' own declaration order, which Swift
        // enforces even with labels.
        LoadOptions(
            suppressDisplayCriteria: false,
            matchContentEnabled: display.matchContentEnabled,
            panelIsInHDRMode: display.panelIsInHDRMode,
            isLive: false,
            nativeRemoteHLS: isRemoteHLS,
            prepareNativeSubtitles: true,
            externalSubtitles: externalSubtitles
        )
    }
```

Then:
- Keep the existing comments that explain each flag.
- Replace the inline construction with `let options = Self.makeLoadOptions(isRemoteHLS: isRemoteHLS, externalSubtitles: externalSubtitles.map(Self.makeExternalSubtitleTrack), display: DisplayContext.current())`.
- If the element type isn't `ExternalSubtitleTrack`, use the type `makeExternalSubtitleTrack` returns.

- [ ] **Step 4: Run the tests on both platforms and confirm they pass; run the full iOS suite**

Run the Step 2 command, the same filter on the `DionysusTV` scheme, and then the whole iOS suite. Expected: PASS everywhere.

- [ ] **Step 5: Device check, readouts first**

Temporarily show a DEBUG-only diagnostics line in the transport, from the spike's overlay: `AetherEngine.displayCapabilities`, `DisplayContext.current()`, `currentEDRHeadroom`, `engine.stats.sourceColorFormat` / `displayColorFormat`. Install on the Apple TV and play **1917**. Record every value in the PR description. **If `displayColorFormat` reads HDR10 and EDR headroom is above 1, stop.** Go to Step 9.

- [ ] **Step 6: Read the engine's own log**

Benjamin runs this, because it needs root:

```bash
sudo log collect --device-udid 00008110-000158190A88201E --last 5m --output ~/Desktop/tv.logarchive
log show ~/Desktop/tv.logarchive --predicate 'subsystem CONTAINS[c] "aether"' --style compact > ~/Desktop/aether-1917.log
```

Search it for the display-criteria handshake: `DisplayCriteria`, `criteria`, `-11868`, `-11848`, `refus`, `latch` and `EDR`. Also look for the master-vs-media routing decision. Quote the decisive lines in the PR.

- [ ] **Step 7: A/B against Sodalite on the same Apple TV**

This is a local build for diagnosis only. It's GPLv3 and stays undistributed.

```bash
git clone https://github.com/superuser404notfound/Sodalite /tmp/sodalite && cd /tmp/sodalite
```

Build its tvOS scheme to the Apple TV with a temporary bundle ID under Team `Z27T535BXZ`, sign in to the LAN server, play 1917, and read its stats overlay.

- **If Sodalite reaches HDR,** diff its host against ours: `LoadOptions` (`dolbyVisionHandling`, `forceDolbyVisionOnNonDVDisplay`, `audioBridgeMode`), window and timing, and when `present` happens relative to `load`. Adopt the difference that matters, one change per install.
- **If Sodalite stays in SDR too,** it's an engine or tvOS 27 issue. File an AetherEngine issue with the Step 5 readouts and the Step 6 log lines. Keep the app-side code as it is, and record the known issue in `CLAUDE.md`'s tvOS section.

Remove the Sodalite build from the device afterwards.

- [ ] **Step 8: Moana (Dolby Vision Profile 8 on an HDR10-only TV)**

This box reports `supportsDolbyVision == false`. Per AetherEngine's docs (`docs/formats.md`, "HDR and Dolby Vision"), a DV P8 source on such a panel should present as HDR10 from the base layer. The alternative is `forceDolbyVisionOnNonDVDisplay`, which serves Profile 5 and is device-verified on that panel class (AE#455).

Measure both on this TV, with Benjamin judging against Infuse. Keep the engine default unless the forced path is visibly better. If it is, add a Settings toggle in Milestone 3; don't hard-code it.

- [ ] **Step 9: Acceptance, on the device with Benjamin**

| Title | Expected |
|---|---|
| 1917 (HDR10) | EDR headroom > 1; `displayColorFormat` "HDR10"; the TV in HDR; the picture comparable to Infuse |
| The End of Oak Street (HDR10+) | HDR10+ or HDR10 displayed |
| Moana (DV P8) | HDR (HDR10 base layer, or DV per Step 8) |
| 3:10 to Yuma (SDR, 23.976) | SDR; the frame-rate switch happens; no HDR switch |

Then remove the temporary diagnostics line. The real format label is Task 8.

- [ ] **Step 10: Commit, after sign-off**

```bash
git add DionysusPlayer/Core/Playback DionysusPlayerTests/Core/Playback CLAUDE.md
git commit -m "Pass tvOS display state to AetherEngine's criteria handshake

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

If Step 7 found a further host change, it gets its own commit, with the measurement in the message.

---

### Task 8: TV transport v1

**Files:**
- Create: `DionysusTV/Player/TVTransportOverlay.swift`
- Create: `DionysusTV/Player/TVTransportChrome.swift`
- Create: `DionysusTV/Player/TVPlaybackTimeFormat.swift`
- Test: `DionysusTVTests/TVPlaybackTimeFormatTests.swift`
- Test: `DionysusTVUITests/PlayerJourneyTests.swift` (new cases)

**Interfaces:**
- Consumes: `PlayerViewModel.item`, `currentTime`, `duration`, `state`, `chapters`, `videoFormatDescription` and `errorMessage`; `LogoImageView(url:fallback:)`; `MediaItem.logoImageURL`, `railTitle` and `numberedEpisodeName`.
- Produces:
  - `TVTransportOverlay(viewModel:chrome:)`.
  - `TVTransportChrome.poke()`, which shows the chrome for 4s. It stays shown while paused or loading, and always under `-UITestDisableControlAutoHide`.
  - `TVPlaybackTimeFormat.string(_:)`.

- [ ] **Step 1: Write the failing formatter tests**

`DionysusTVTests/TVPlaybackTimeFormatTests.swift`:

```swift
import XCTest
@testable import Dionysus

final class TVPlaybackTimeFormatTests: XCTestCase {
    func test_underAnHour_isMinutesSeconds() { XCTAssertEqual(TVPlaybackTimeFormat.string(754), "12:34") }
    func test_overAnHour_isHoursMinutesSeconds() { XCTAssertEqual(TVPlaybackTimeFormat.string(7_325), "2:02:05") }
    func test_nonFinite_isZero() {
        XCTAssertEqual(TVPlaybackTimeFormat.string(.nan), "0:00")
        XCTAssertEqual(TVPlaybackTimeFormat.string(.infinity), "0:00")
    }
    func test_negative_isZero() { XCTAssertEqual(TVPlaybackTimeFormat.string(-3), "0:00") }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `xcodebuild test … -scheme DionysusTV -only-testing:DionysusTVTests/TVPlaybackTimeFormatTests`
Expected: a compile FAIL.

- [ ] **Step 3: Implement the formatter**

```swift
import Foundation

enum TVPlaybackTimeFormat {
    static func string(_ time: TimeInterval) -> String {
        let t = time.isFinite ? max(0, Int(time)) : 0
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Write the failing transport journeys**

Add to `PlayerJourneyTests`:

```swift
    /// The title block sits top-left and falls back to text when the item has
    /// no logo (Review Focus 1); the elapsed label and scrubber are present.
    func test_transport_showsTitleAndTimes() {
        let app = launch(seedSession: true, extraArguments: ["-UITestDisableControlAutoHide", "YES"])
        let tile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.primaryMovieID)]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        while !tile.hasFocus { press(.right) }
        press(.select)
        let title = app.descendants(matching: .any)[A11yID.TV.Player.titleBlock]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertLessThan(title.frame.minY, 300, "The title block sits at the top of the screen")
        XCTAssertLessThan(title.frame.minX, 300, "…and on the left")
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].exists)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Player.transport].exists)
    }
```

The stub's primary movie has no logo, per its fixture. If it does have one, add a `UITestFixtureIdentity` movie without a logo, following the fixture file's pattern, and play that one here.

- [ ] **Step 6: Implement the overlay**

`TVTransportChrome.swift` is the spike's `TVTransportChrome`, plus `-UITestDisableControlAutoHide` support: when `UITestConfiguration.disablesControlAutoHide` is set, `poke()` never schedules the hide, under `#if DEBUG`.

`TVTransportOverlay.swift` follows the prototype's player screens (canvas 12 and 13) and iOS's layout:

- **Top-left**, with 80pt leading and 60pt top padding, over a `LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.45), .clear])` about 360pt tall:
  - `LogoImageView(url: logo, fallback: Text(item.railTitle).font(.title2.bold()))` with `maxWidth: 460, maxHeight: 110, alignment: .topLeading`, or `Text(item.railTitle)` when `logoImageURL == nil`.
  - For episodes, a second line: `item.numberedEpisodeName`, the "S1:E3 · Title" form iOS uses. Check its exact output in `MediaItem.swift`.
  - The block carries `A11yID.TV.Player.titleBlock`, with `.accessibilityElement(children: .combine)`.
- **Bottom**, over a bottom fade:
  - The scrubber: a white fill over `white.opacity(0.3)`, with chapter ticks from `viewModel.chapters` (skip `startSeconds == 0`). It carries `A11yID.TV.Player.transport`.
  - A row with elapsed on the left (`A11yID.TV.Player.elapsed`), the format chip in the centre, and `−remaining` on the right.
  - The format chip shows `viewModel.videoFormatDescription?.uppercased()` in a capsule and carries `A11yID.TV.Player.formatLabel`. It is omitted when nil, because SDR shows nothing, as on iOS.
- **Centre:** a `ProgressView` while `.loading`, and `errorMessage` in a material card when set.
- **Visibility:** shown when `chrome.isVisible || state == .paused || state == .loading`, with a 0.25s ease.

In `TVPlayerHostController`, pass `TVTransportOverlay(viewModel:chrome:)` as the overlay and call `chrome.poke()` on every handled press.

- [ ] **Step 7: Run all tvOS tests and confirm they pass**

Run: `xcodebuild test … -scheme DionysusTV` and `… -testPlan TVUITests`. Expected: PASS.

- [ ] **Step 8: Check on the device with Benjamin**

- 1917: the logo top-left over the fade, the chapter ticks, and "HDR10" in the format chip (after Task 7).
- An episode: the series logo plus "S1:E3 · …".
- ±10s and play/pause respond without lag.
- Menu returns to the launcher.

Compare the scrub responsiveness against Infuse, and note the gaps for Milestone 4.

- [ ] **Step 9: Docs, commit after sign-off, then PR 3**

Update `TESTING.md` (the TV journeys) and `CLAUDE.md` (the tvOS player host: the three hard rules from the Global Constraints, and the HDR outcome from Task 7).

```bash
git add DionysusTV DionysusTVTests DionysusTVUITests TESTING.md CLAUDE.md
git commit -m "Add the first tvOS transport: title top-left, chapters, format

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Later milestones (each gets its own plan)

- **M2, Onboarding, shell and profiles:**
  - The prototype's onboarding visuals.
  - A sidebar `TabView` with Home, Search, a `TabSection` per library (folded into "Libraries" above 5) and Profile.
  - Per-tvOS-user sessions: the `com.apple.developer.user-management` entitlement, `runs-as-current-user-with-user-independent-keychain`. Server config goes in the user-independent keychain; the Jellyfin session stays per-user. Handle the user-change notification.
  - Re-check the one-off session loss after a reinstall.
- **M3, Browse:**
  - Home (hero, rails, tile badges, a hero Series resolving to an episode).
  - Movie and show detail (Resume/Restart/Watched eye/Favorite/More).
  - The collection grid with the five facets and the alphabet jump bar.
  - Search.
  - Profile/Settings.
- **M4, Playback features:**
  - Audio and subtitle menus, as UIKit `UIButton.menu`, because an open SwiftUI `Menu` blinks on tvOS 26.
  - libass ASS subtitles.
  - Skip Intro/Credits, the compact Next Up card, and trickplay scrubbing to the Infuse bar.
  - The swipe-down tabs and Stats for Nerds.
- **M5, Now Playing (deferred by Benjamin), Top Shelf, release and docs:**
  - Now Playing under the AVKit host. Nothing showed in the spike; compare Sodalite's `delegate`/`skippingBehavior` setup.
  - Top Shelf (Continue Watching / Next Up, with an App Group, and PRIVACY.md updated).
  - A tvOS archive and upload in `release.yml` under Universal Purchase.
  - Store screenshots from the demo server.
