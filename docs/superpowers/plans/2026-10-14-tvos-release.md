# tvOS M6: Now Playing, Top Shelf and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Apple TV app to TestFlight and the App Store with working Now Playing, a content-rich Top Shelf and its own store assets, from the same one-tag-push release as iOS.

**Architecture:** Now Playing moves from AVKit to the engine-owned `MPNowPlayingSession` iOS already uses. Top Shelf is a new TV Services extension (`DionysusTVTopShelf`) that reads the signed-in session from a shared keychain group, fetches Continue Watching / Next Up / Recently Added live through the existing `JellyfinAPIClient`, and builds carousel items with a pure `TopShelfContentBuilder`; its actions open the app through a `dionysus://` deep link the shell routes. `release.yml` gains a `prepare` job, a parallel tvOS archive-and-upload job and a final `publish` job.

**Tech Stack:** Swift 6, SwiftUI + UIKit (tvOS 26.0 floor), TV Services (`TVTopShelfContentProvider`, `TVTopShelfCarouselContent`), MediaPlayer, AetherEngine 7.x, XcodeGen, XCTest/XCUITest, GitHub Actions, App Store Connect API.

**Spec:** `docs/superpowers/specs/2026-10-14-tvos-release-design.md` (read it first; this plan argues from it).

## Global Constraints

- tvOS floor **26.0**; iOS floor 18 (root `CLAUDE.md`). Shared code that names a Downloads type stays inside `#if DOWNLOADS`.
- `PlaybackEngine` changes go to the protocol **and both conformers** (`AetherPlaybackEngine`, `PreviewPlaybackEngine`), and `FakePlaybackEngine` in tests.
- Regenerate the project after any `project.yml` or file-set change: `xcodegen generate`. A folder `CLAUDE.md` inside a target's sources must be excluded (`"**/CLAUDE.md"`).
- Bundle IDs: app `com.imbenjamin.dionysusplayer` (shared with iOS), extension `com.imbenjamin.dionysusplayer.topshelf`. Team `Z27T535BXZ`.
- Profiles are named by string: "Dionysus App Store" (iOS, exists), "Dionysus tvOS App Store", "Dionysus Top Shelf App Store".
- AetherEngine stays pinned with `version:` in `project.yml`; never a `from:` range.
- User-facing strings: SwiftUI literals or `String(localized:)`; sync `Localizable.xcstrings` in the same PR (Xcode build, or hand-insert per memory).
- Never select on an accessibility label in UI tests; never put an identifier on a screen-root container. Decorative `Image(systemName:)` gets `.accessibilityHidden(true)`.
- **Sign-off before every commit** (Benjamin). Ask before deploying to the Bedroom Apple TV. Reuse booted Simulators (tvOS 26.5 `90E06237-18E8-4D0D-A7A4-51529B237F05`, tvOS 27 `47399BA1-8F7A-45F6-9E8C-747034CE1DC7`, iPhone 17 `560CD3F0`); re-point them to SavareseHillFlix as Ben before hand-back.
- Suites run one after another, never concurrently: tvOS unit (`TVUnitTests`), tvOS UI (`TVUITests`), iOS unit (`UnitTests`), iOS smoke (`UITests-Smoke`). A tvOS-only change needs only the two tvOS suites.
- Commits never include a Claude session URL; keep `Co-Authored-By: Claude …`. Never commit `Config/Version.xcconfig` or `AppVersion.swift` drift.
- Portal changes through the ASC API are authorised (Benjamin, 2026-10-14) but each is announced before it runs. A release tag is pushed only when Benjamin says so.
- Store screenshots are captured against `demo.jellyfin.org/stable` (user `demo`, no password), never a personal server; nothing HDR-looking is faked.
- Top Shelf content (Benjamin, 2026-10-14): the **first 3** Continue Watching items, then Next Up not already shown, then Recently Added, **10 at most**; `.details` style; no preview video; no logo.
- Deep links: `dionysus://item/<id>?server=<serverID>` opens the detail page; `dionysus://play/<id>?server=<serverID>` plays over the detail page. Selecting a Home/grid/Search tile still never starts playback.

## Review Focus

1. **A revoked or expired token in the extension** (another device signed the user out, or the server restarted with a cleared session table): the shelf must quietly fall back to the static image, never hang tvOS's request or try to sign in with a password. Pinned in Task 8 (`TopShelfLoader` returns `[]` on a 401 with no re-authentication).
2. **A deep link for a title that no longer exists or that this user can't see** (deleted since the shelf was built, or another account's shelf after a user switch): the item link must land on a detail page showing its error with Retry, and the play link must fall back to that page, not leave the user on a blank Home. Pinned in Task 9 (router opens the page; play target failing falls back to the page) and its UI journey.
3. **A link arriving while the app is still restoring its session, on the login screen, or for another server**: wait for `.main` if restoring; drop it when signed out or the server differs. Pinned in Task 9's router tests.
4. **A thin library**: fewer than 3 resume items, a show in both Continue Watching and Next Up, items with no backdrop anywhere, every list empty. The shelf fills from the next source, never duplicates an item, leaves out art-less items and returns nothing (static image) when empty. Pinned in Task 7's builder tests.
5. **A play link while a player is already up** (Top Shelf reached via the TV button mid-playback): the current player closes, reporting its stop, and the new title plays. Pinned in Task 9's UI journey.

---

## PR map

| PR | Tasks | Branch |
|----|-------|--------|
| 1 Now Playing | 1–3 | `feature/tvos-now-playing` (spec + this plan ride in its first commit) |
| 2 Top Shelf spike (throwaway) | 4 | `spike/tvos-topshelf` (never merged; findings committed on PR 3's branch) |
| 3 Top Shelf + deep links | 5–10 | `feature/tvos-top-shelf` |
| 4 Interim device pass | 11 | `feature/tvos-m6-device-pass` |
| 5 Release pipeline | 12–15 | `infra/tvos-release` |
| 6 Store assets + listing | 16–17 | `docs/tvos-store-assets` |
| 7 Final pass + review | 18 | `fix/tvos-m6-review` |

Ledger: `.superpowers/sdd/2026-10-14-tvos-release/progress.md` (git-ignored). Record each task's outcome, rulings and measured facts there.

Each PR: branch from `develop`, implement, run the suites, Benjamin signs off the diff, commit, open the PR (concise body ending with the "Generated with Claude Code" line), merge with `gh pr merge --merge` once checks pass.

---

## PR 1: Now Playing

### Task 1: Diagnose Now Playing on the Simulator

No product code. The outcome decides Task 3.

**Files:**
- Read: `DionysusTV/Player/TVPlayerHostController.swift`, `DionysusTV/Player/TVPlayerPresenter.swift`, `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift:188-200,895-985`
- Read: AetherEngine checkout `Sources/AetherEngine/AetherEngine.swift` (`ownsVideoNowPlayingSession`, `videoNowPlayingSession`), `Sources/AetherEngine/Native/NativeAVPlayerHost.swift:300-335`
- Write: ledger only

- [ ] **Step 1: Read Sodalite's host.** Clone into the scratchpad and find how its `AVPlayerViewController` subclass handles Now Playing:

```bash
git clone --depth 1 https://github.com/superuser404notfound/Sodalite "$SCRATCH/sodalite"
grep -rn "NowPlaying\|updatesNowPlayingInfoCenter\|externalMetadata\|ownsVideoNowPlayingSession" "$SCRATCH/sodalite" --include=*.swift
```

Record in the ledger which of the three it does: AVKit-owned with `externalMetadata`, engine-owned session with `updatesNowPlayingInfoCenter = false`, or `MPNowPlayingInfoCenter` by hand.

- [ ] **Step 2: Reproduce on the tvOS 27 Simulator.** Build and run `DionysusTV` (Debug) on `47399BA1`, sign in to SavareseHillFlix as Ben, play a direct-play HEVC movie. Open Control Center (hold the TV button on the Simulator's remote, or `idb ui button --udid 47399BA1 HOME --duration 2`) and screenshot it to the scratchpad. Expected: no Now Playing tile (Benjamin's report).

- [ ] **Step 3: Try the engine-owned session, uncommitted.** In `TVPlayerPresenter.makeEngine()` change `AetherPlaybackEngine(ownsNowPlayingSession: false)` to `AetherPlaybackEngine(ownsNowPlayingSession: true)`; in `TVPlayerHostController.viewDidLoad` add `updatesNowPlayingInfoCenter = false`; comment out the `$currentAVPlayerItem` sink. Rebuild, play the same title, open Control Center, screenshot. Expected: a Now Playing tile with the title, subtitle, artwork and a working pause.

- [ ] **Step 4: Check the software route.** With Step 3's change, play a title the engine sends down the software route (an AV1 or VP9 file, or an interlaced MPEG-2; the stats panel's route row says `software`). Screenshot Control Center. Record whether anything shows.

- [ ] **Step 5: Record the outcome** in the ledger: Sodalite's approach, Step 3's result, Step 4's result. If Step 3 failed, stop and bring the evidence to Benjamin before Task 2. If Step 4 shows a tile already, mark Task 3 "not needed". Revert the uncommitted changes (`git checkout -- DionysusTV`).

### Task 2: Own the Now Playing session on tvOS

**Files:**
- Modify: `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift:188-200,904-907`
- Modify: `DionysusTV/Player/TVPlayerPresenter.swift:47-56`
- Modify: `DionysusTV/Player/TVPlayerHostController.swift` (viewDidLoad; remove `stampExternalMetadata` and its two call sites, lines ~239-241, ~250, ~278-287)
- Test: `DionysusTVTests/TVPlayerNowPlayingTests.swift` (create)
- Docs: `DionysusTV/CLAUDE.md` ("The player", first paragraph), `DionysusPlayer/Core/Playback/CLAUDE.md` ("Now Playing")

**Interfaces:**
- Produces: `AetherPlaybackEngine.init() throws` (the `ownsNowPlayingSession:` parameter is removed; every engine owns its session). `TVPlayerHostController` sets `updatesNowPlayingInfoCenter = false`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dionysus

/// Now Playing belongs to the engine's own session on tvOS too (M6): AVKit
/// publishing as well gives the half-working mix AetherEngine warns about.
@MainActor
final class TVPlayerNowPlayingTests: XCTestCase {
    private func makeHost(engine: FakePlaybackEngine = FakePlaybackEngine()) -> TVPlayerHostController {
        let client = JellyfinAPIClient(baseURL: URL(string: "http://example.invalid")!)
        let viewModel = PlayerViewModel(client: client, userID: "user-1", itemID: "movie-1", engine: engine)
        return TVPlayerHostController(viewModel: viewModel)
    }

    func test_host_leavesNowPlayingToTheEngine() {
        let host = makeHost()
        host.loadViewIfNeeded()
        XCTAssertFalse(host.updatesNowPlayingInfoCenter)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUnitTests \
  -destination 'id=47399BA1-8F7A-45F6-9E8C-747034CE1DC7' -derivedDataPath "$SCRATCH/dd" \
  -only-testing:DionysusTVTests/TVPlayerNowPlayingTests
```

Expected: FAIL (`updatesNowPlayingInfoCenter` is `true` by default). If `PlayerViewModel`'s init needs more arguments, copy the call from `TVPlayerPresenter.present`.

- [ ] **Step 3: Implement**

In `TVPlayerHostController.viewDidLoad()`, before the surface is set up:

```swift
        // The engine owns Now Playing (`MPNowPlayingSession`), as on iOS: with
        // AVKit's chrome hidden it published nothing (M6), and both publishing
        // is the half-working mix AetherEngine's doc comment warns about.
        updatesNowPlayingInfoCenter = false
```

Delete `stampExternalMetadata(on:)`, the `hostEngine.$currentAVPlayerItem` sink, and the `stampExternalMetadata(on: avPlayer.currentItem)` line in `apply(avPlayer:hostEngine:)`.

In `AetherPlaybackEngine`, replace the init and its comment:

```swift
    init() throws {
        self.engine = try AetherEngine()
        pipDelegateProxy.engine = self
        // Takes ownership of the system Now-Playing session on the native video
        // path. AetherEngine defaults this off for `AVPlayerViewController`
        // hosts where AVKit owns Now-Playing; both apps draw their own
        // transport (on tvOS AVKit's chrome is hidden and its publishing turned
        // off), so this is the custom-UI case meant to opt in. Must precede
        // `load()`.
        engine.ownsVideoNowPlayingSession = true
        observeEngine()
        observeAppLifecycle()
    }
```

and drop the `guard engine.ownsVideoNowPlayingSession else { return }` and its comment from `setNowPlayingInfo`. In `TVPlayerPresenter.makeEngine()` use `try? AetherPlaybackEngine()` and change its doc comment to "The harness's fake under UI tests; otherwise AetherEngine, which owns Now Playing as on iOS." Fix any other `ownsNowPlayingSession:` call site the compiler names.

- [ ] **Step 4: Next Up needs no new test.** The next item stages its own Now Playing info through `PlayerViewModel.start()`, which `PlayerViewModelTests.test_start_setsNowPlayingTitleAndSubtitleImmediately` pins; that file is in `DionysusTVTests`' includes, so it already runs on tvOS. With the `ownsVideoNowPlayingSession` guard gone, nothing tvOS-specific remains to test. Note it in the ledger.

- [ ] **Step 5: Run the tests to verify they pass** (Step 2's command, then the whole `TVUnitTests` plan). Expected: PASS.

- [ ] **Step 6: Check by hand on the tvOS 27 Simulator.** Play a movie and an episode; open Control Center: title (show name for an episode), subtitle (year · runtime or `S1:E4 · Name`), artwork after a moment; pause, play, skip ±10s and scrub from Control Center, and see the transport follow. Let Next Up advance and confirm the tile changes. Screenshots to the scratchpad; show them to Benjamin.

- [ ] **Step 7: Docs.** `DionysusTV/CLAUDE.md`, "The player": replace "And the engine is made with `ownsNowPlayingSession: false`, since the `AVPlayerViewController` already runs Now Playing." with "And Now Playing is the engine's own session, as on iOS: the host turns AVKit's publishing off (`updatesNowPlayingInfoCenter = false`), since with its chrome hidden AVKit published nothing (M6)." `DionysusPlayer/Core/Playback/CLAUDE.md`, "Now Playing": replace the closing parenthesis about the Apple TV with "The Apple TV player does the same: its `AVPlayerViewController` host turns AVKit's own publishing off, never both."

- [ ] **Step 8: Sign-off and commit** (with the spec and this plan in the first commit of the branch):

```bash
git add docs/superpowers/specs/2026-10-14-tvos-release-design.md docs/superpowers/plans/2026-10-14-tvos-release.md \
  DionysusPlayer/Core/Playback DionysusTV/Player DionysusTV/CLAUDE.md DionysusTVTests/TVPlayerNowPlayingTests.swift
git commit -m "Give the Apple TV player Now Playing"
```

### Task 3: Now Playing on the software route

Skip if Task 1 Step 4 recorded a working tile. Otherwise:

**Files:**
- Create: `DionysusPlayer/Core/Playback/SoftwareNowPlaying.swift`
- Modify: `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift` (Now Playing section; the `$currentAVPlayer` sink)
- Test: `DionysusPlayerTests/Core/Playback/SoftwareNowPlayingTests.swift` (create; runs on both platforms via the TV target's `Core/Playback/**` include)
- Docs: `DionysusPlayer/Core/Playback/CLAUDE.md` ("Now Playing")

**Interfaces:**
- Produces: `enum SoftwareNowPlaying { static func info(title: String, subtitle: String?, elapsed: Double, duration: Double, rate: Float) -> [String: Any] }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import MediaPlayer
@testable import Dionysus

/// The software route has no AVPlayer, so no `MPNowPlayingSession`: its Now
/// Playing is written to the default center by hand (M6).
final class SoftwareNowPlayingTests: XCTestCase {
    func test_info_carriesIdentityAndTiming() {
        let info = SoftwareNowPlaying.info(title: "Northern Lights", subtitle: "S1:E2 · Dawn", elapsed: 61, duration: 1800, rate: 1)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Northern Lights")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "S1:E2 · Dawn")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 61)
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 1800)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 1)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.video.rawValue)
    }

    func test_info_omitsAMissingSubtitle() {
        let info = SoftwareNowPlaying.info(title: "Arrival", subtitle: nil, elapsed: 0, duration: 0, rate: 0)
        XCTAssertNil(info[MPMediaItemPropertyArtist])
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration], "An unknown duration isn't published as zero")
    }
}
```

- [ ] **Step 2: Run to verify it fails** (iOS: `xcodebuild test … -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/SoftwareNowPlayingTests`). Expected: FAIL, `SoftwareNowPlaying` undefined.

- [ ] **Step 3: Implement**

```swift
import MediaPlayer

/// Now Playing for AetherEngine's software route (AV1, VP9, interlaced and
/// legacy sources), which has no AVPlayer and so no `MPNowPlayingSession`.
/// `AetherPlaybackEngine` writes this to `MPNowPlayingInfoCenter.default()`
/// only while no session exists, and clears it when the route or the session
/// ends: the shared center and a session must never both publish.
enum SoftwareNowPlaying {
    static func info(title: String, subtitle: String?, elapsed: Double, duration: Double, rate: Float) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        info[MPMediaItemPropertyArtist] = subtitle
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        return info
    }
}
```

In `AetherPlaybackEngine`: keep the last `(title, subtitle, artwork)` passed to `setNowPlayingInfo` in a private property. Add `private func publishSoftwareNowPlaying()` that, when `engine.videoNowPlayingSession == nil && engine.currentAVPlayer == nil && hasLoaded`, sets `MPNowPlayingInfoCenter.default().nowPlayingInfo = SoftwareNowPlaying.info(...)` (plus `MPMediaItemPropertyArtwork` via `Self.makeArtwork`) and `playbackState` (`.playing`/`.paused`), and registers the same play/pause/toggle/skip/position handlers as `updateNowPlayingCommands()` on `MPRemoteCommandCenter.shared()` (factor the handler wiring into `private func wireCommands(_ center: MPRemoteCommandCenter)` and call it from both). Call it from `setNowPlayingInfo`, from the engine's state sink (play/pause), after a seek completes, and from the `$currentAVPlayer` sink. When a session appears (`currentAVPlayer != nil`) or on `stop()`, set `MPNowPlayingInfoCenter.default().nowPlayingInfo = nil` and remove the shared center's targets (`removeTarget(nil)` on each command).

- [ ] **Step 4: Run the tests** (Step 2, then the tvOS target's). Expected: PASS.

- [ ] **Step 5: Check by hand** on the tvOS 27 Simulator with the software-route title from Task 1, and on the iPhone 17 Simulator's lock screen: title, timing, pause/play from Control Center.

- [ ] **Step 6: Docs.** `DionysusPlayer/Core/Playback/CLAUDE.md`, "Now Playing": add a paragraph: "**The software route has no session**, AetherEngine's video Now Playing session existing only with an AVPlayer. `SoftwareNowPlaying` writes the same identity, with elapsed time and rate, to `MPNowPlayingInfoCenter.default()` and wires the commands on the shared `MPRemoteCommandCenter`, only while no session exists, and clears both when one appears or playback stops."

- [ ] **Step 7: Run all four suites, sign-off, commit, PR.** `git commit -m "Publish Now Playing on the software route"`. Open PR 1 ("Now Playing on the Apple TV"), merge on green.

---

## PR 2: Top Shelf spike (throwaway)

### Task 4: Spike: what a Top Shelf extension can read

**Files (all on `spike/tvos-topshelf`, never merged):**
- Create: `DionysusTVTopShelf/ContentProvider.swift`, `DionysusTVTopShelf/Info.plist` via `project.yml`
- Modify: `project.yml` (extension target, keychain groups), `DionysusPlayer/Core/Persistence/KeychainStore.swift` (nothing, unless Step 4 says so)

- [ ] **Step 1: Branch** `git switch -c spike/tvos-topshelf develop`.

- [ ] **Step 2: Add a bare extension target** to `project.yml`:

```yaml
  DionysusTVTopShelf:
    type: tv-app-extension
    platform: tvOS
    deploymentTarget: "26.0"
    sources:
      - path: DionysusTVTopShelf
      - path: DionysusPlayer/Core/Persistence/KeychainStore.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.imbenjamin.dionysusplayer.topshelf
    entitlements:
      path: Generated/DionysusTVTopShelf.entitlements
      properties:
        keychain-access-groups:
          - $(AppIdentifierPrefix)com.imbenjamin.dionysusplayer
    info:
      path: Generated/Info-TopShelf.plist
      properties:
        CFBundleDisplayName: Dionysus
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        NSExtension:
          NSExtensionPointIdentifier: com.apple.tv-top-shelf
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ContentProvider
```

Add `- target: DionysusTVTopShelf` to `DionysusTV`'s `dependencies` (XcodeGen embeds an app extension by default), and to the app's entitlements `keychain-access-groups: [$(AppIdentifierPrefix)com.imbenjamin.dionysusplayer]` beside the user-management key. `xcodegen generate`.

- [ ] **Step 3: Write a provider that reports what it sees**, as one carousel item per fact so it shows on the shelf:

```swift
import TVServices
import os

final class ContentProvider: TVTopShelfContentProvider {
    private let log = Logger(subsystem: "com.imbenjamin.dionysusplayer.topshelf", category: "spike")

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let facts = [
            "home \(NSHomeDirectory())",
            "creds(currentUser) \(KeychainStore.load(forKey: "server.credentials", scope: .currentUser) != nil)",
            "creds(allUsers) \(KeychainStore.load(forKey: "server.credentials", scope: .allUsers) != nil)",
            "server(allUsers) \(KeychainStore.load(forKey: "server.configuration", scope: .allUsers) != nil)",
            "deviceID(defaults) \(UserDefaults.standard.string(forKey: "device.identifier") ?? "nil")"
        ]
        facts.forEach { log.notice("\($0, privacy: .public)") }
        let items = facts.enumerated().map { index, fact in
            let item = TVTopShelfCarouselItem(identifier: "fact-\(index)")
            item.title = fact
            item.setImageURL(URL(string: "https://picsum.photos/1920/1080"), for: .screenScale1x)
            return item
        }
        return TVTopShelfCarouselContent(style: .details, items: items)
    }
}
```

- [ ] **Step 4: Run it on the tvOS 27 Simulator** as the primary user signed in to SavareseHillFlix: install the app, move it to the top row of the tvOS Home Screen, focus its icon, and read the shelf (and `xcrun simctl spawn 47399BA1 log stream --predicate 'subsystem == "com.imbenjamin.dionysusplayer.topshelf"'`). Then add a second tvOS user (Settings → Users and Accounts; ask Benjamin before changing the Simulator's users if it isn't throwaway), switch to them, sign the app in as a different Jellyfin user, focus the icon again. Record for each user: does the extension run as that user (home path), does it read that user's credentials, the shared server, and the app's device id from defaults.

- [ ] **Step 5: Try without the user-management entitlement on the extension** (as Step 2 has it) and then with it added; record which reads per-user data. Check whether items the app wrote before the access group existed are visible (they should be: an item without `kSecAttrAccessGroup` lands in the app's first group, which is now the shared one).

- [ ] **Step 6: Check the `.details` layout limits**: how many items the system shows, whether `contextTitle` renders, how a long summary truncates. Screenshot.

- [ ] **Step 7: Record findings** in the spec's "Step 0: spike" section (replace the question list with the answers) and the ledger. If the extension can't read per-user data in any configuration, stop and take the alternatives to Benjamin (e.g. the app writing a per-tvOS-user token copy into the shared keychain keyed by the app's container) before Task 5. Leave the spike branch unmerged; switch back to `develop`.

---

## PR 3: Top Shelf and deep links

Branch `feature/tvos-top-shelf` from `develop`. First commit (signed off 2026-10-14): the spike's findings in the spec and this plan's Tasks 6, 8, 10 and 11 rewritten for the last-used-profile session mirror.

### Task 5: Deep links

**Files:**
- Create: `DionysusTV/TopShelf/TVDeepLink.swift`
- Test: `DionysusTVTests/TVDeepLinkTests.swift`
- Modify: `project.yml` (`DionysusTV` info: `CFBundleURLTypes`)

**Interfaces:**
- Produces:

```swift
struct TVDeepLink: Equatable {
    enum Action: String { case item, play }
    var action: Action
    var itemID: String
    var serverID: String
    init(action: Action, itemID: String, serverID: String)
    init?(url: URL)
    var url: URL
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Dionysus

final class TVDeepLinkTests: XCTestCase {
    private let server = "http://jellyfin.local:8096"

    func test_url_roundTrips_forBothActions() {
        for action in [TVDeepLink.Action.item, .play] {
            let link = TVDeepLink(action: action, itemID: "abc123", serverID: server)
            XCTAssertEqual(TVDeepLink(url: link.url), link)
        }
    }

    func test_url_isTheDocumentedShape() {
        let link = TVDeepLink(action: .play, itemID: "abc123", serverID: server)
        XCTAssertEqual(link.url.scheme, "dionysus")
        XCTAssertEqual(link.url.host(), "play")
        XCTAssertEqual(link.url.path(), "/abc123")
    }

    func test_parse_rejectsOtherSchemesActionsAndMissingParts() {
        XCTAssertNil(TVDeepLink(url: URL(string: "https://item/abc?server=x")!))
        XCTAssertNil(TVDeepLink(url: URL(string: "dionysus://delete/abc?server=x")!))
        XCTAssertNil(TVDeepLink(url: URL(string: "dionysus://item/?server=x")!))
        XCTAssertNil(TVDeepLink(url: URL(string: "dionysus://item/abc")!))
    }
}
```

- [ ] **Step 2: Run to verify they fail** (`-only-testing:DionysusTVTests/TVDeepLinkTests`). Expected: FAIL, type undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What the Top Shelf's actions open (M6): `dionysus://item/<id>?server=<id>`
/// for a title's detail page, `dionysus://play/<id>?server=<id>` to play it
/// over that page. The server is `ServerConfiguration.id`, so a link built
/// for another server is never applied to this one.
struct TVDeepLink: Equatable {
    enum Action: String { case item, play }

    static let scheme = "dionysus"

    var action: Action
    var itemID: String
    var serverID: String

    init(action: Action, itemID: String, serverID: String) {
        self.action = action
        self.itemID = itemID
        self.serverID = serverID
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let host = url.host(), let action = Action(rawValue: host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverID = components.queryItems?.first(where: { $0.name == "server" })?.value, !serverID.isEmpty
        else { return nil }
        let itemID = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !itemID.isEmpty, !itemID.contains("/") else { return nil }
        self.init(action: action, itemID: itemID, serverID: serverID)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action.rawValue
        components.path = "/" + itemID
        components.queryItems = [URLQueryItem(name: "server", value: serverID)]
        return components.url!
    }
}
```

- [ ] **Step 4: Register the scheme.** In `project.yml`, `DionysusTV.info.properties`:

```yaml
        # The Top Shelf's actions open the app here (TVDeepLink).
        CFBundleURLTypes:
          - CFBundleURLName: com.imbenjamin.dionysusplayer.deeplink
            CFBundleURLSchemes: [dionysus]
```

`xcodegen generate`.

- [ ] **Step 5: Run the tests to verify they pass.** Expected: PASS.

### Task 6: The session the app mirrors for the Top Shelf

Rewritten after the spike (Task 4 ledger, Benjamin 2026-10-14): the extension reads the **default** Apple TV profile's keychain whatever profile is active, so it can't read the current user's credentials. The app instead mirrors what the extension needs into one item in the user-independent keychain, and the shelf shows **whoever last used Dionysus**.

**Files:**
- Create: `DionysusPlayer/Core/Persistence/TopShelfSession.swift` (under `Core/`, so every target compiles it; only tvOS uses it)
- Modify: `DionysusPlayer/Core/Persistence/DeviceIdentity.swift` (`adopt(deviceID:deviceName:)`)
- Modify: `project.yml` (app entitlements: `keychain-access-groups`)
- Test: `DionysusTVTests/TopShelfSessionTests.swift`

**Interfaces:**
- Produces:

```swift
struct TopShelfSession: Codable, Equatable {
    var serverURL: URL
    var serverID: String
    var userID: String
    var accessToken: String
    var deviceID: String
    var deviceName: String
    static let keychainKey = "topshelf.session"
    static func make(server: ServerConfiguration?, credentials: StoredCredentials?, deviceID: String, deviceName: String) -> TopShelfSession?
}
enum TopShelfSessionMirror {
    static func write(_ session: TopShelfSession?)   // nil deletes
    static func read() -> TopShelfSession?
}
extension DeviceIdentity { static func adopt(deviceID: String, deviceName: String) }
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Dionysus

/// The Top Shelf extension can't see the current Apple TV profile's keychain
/// (spike, M6), so the app mirrors the last-used session into the keychain
/// every profile shares.
final class TopShelfSessionTests: XCTestCase {
    private let server = ServerConfiguration(name: "JF", baseURL: URL(string: "http://jf.local")!)
    private func credentials(token: String? = "tok", userID: String? = "u1", serverID: String? = "http://jf.local") -> StoredCredentials {
        StoredCredentials(username: "ben", password: "", accessToken: token, userID: userID, serverID: serverID)
    }

    func test_make_carriesWhatTheExtensionNeeds() throws {
        let session = try XCTUnwrap(TopShelfSession.make(server: server, credentials: credentials(), deviceID: "dev", deviceName: "Bedroom"))
        XCTAssertEqual(session.serverURL, server.baseURL)
        XCTAssertEqual(session.serverID, server.id)
        XCTAssertEqual(session.userID, "u1")
        XCTAssertEqual(session.accessToken, "tok")
        XCTAssertEqual(session.deviceID, "dev")
        XCTAssertEqual(session.deviceName, "Bedroom")
    }

    func test_make_isNil_withoutAServerTokenOrUser() {
        XCTAssertNil(TopShelfSession.make(server: nil, credentials: credentials(), deviceID: "d", deviceName: "n"))
        XCTAssertNil(TopShelfSession.make(server: server, credentials: nil, deviceID: "d", deviceName: "n"))
        XCTAssertNil(TopShelfSession.make(server: server, credentials: credentials(token: nil), deviceID: "d", deviceName: "n"))
        XCTAssertNil(TopShelfSession.make(server: server, credentials: credentials(token: ""), deviceID: "d", deviceName: "n"))
        XCTAssertNil(TopShelfSession.make(server: server, credentials: credentials(userID: nil), deviceID: "d", deviceName: "n"))
    }

    func test_make_isNil_forCredentialsFromAnotherServer() {
        XCTAssertNil(TopShelfSession.make(server: server, credentials: credentials(serverID: "http://elsewhere"), deviceID: "d", deviceName: "n"))
    }

    func test_mirror_roundTrips_andNilDeletes() throws {
        let session = try XCTUnwrap(TopShelfSession.make(server: server, credentials: credentials(), deviceID: "d", deviceName: "n"))
        TopShelfSessionMirror.write(session)
        XCTAssertEqual(TopShelfSessionMirror.read(), session)
        TopShelfSessionMirror.write(nil)
        XCTAssertNil(TopShelfSessionMirror.read())
    }

    func test_adopt_replacesTheIdentityTheHeaderSends() {
        DeviceIdentity.adopt(deviceID: "app-device", deviceName: "Bedroom")
        defer { DeviceIdentity.adopt(deviceID: nil, deviceName: nil) }
        let header = JellyfinAuthorization.headerValue(token: nil)
        XCTAssertTrue(header.contains("DeviceId=\"app-device\""))
        XCTAssertTrue(header.contains("Device=\"Bedroom\""))
    }
}
```

(`adopt` takes optionals so tests can clear it; the extension always passes values.) Check the `ServerConfiguration` and `StoredCredentials` initialisers against the source before running and adjust the fixtures, not the production types.

- [ ] **Step 2: Run to verify they fail** (`-only-testing:DionysusTVTests/TopShelfSessionTests`). Expected: FAIL, types undefined.

- [ ] **Step 3: Implement.** `TopShelfSession.swift`:

```swift
import Foundation

/// What the Top Shelf extension needs to fetch (M6). The extension reads the
/// default Apple TV profile's keychain whichever profile is active (spike,
/// 2026-10-14), so it can't read the current user's credentials; the app
/// mirrors its session here, in the keychain every profile shares, each time
/// it's used, and the shelf shows whoever last used Dionysus (Benjamin). The
/// device id and name travel with the token: a token presented with another
/// device id risks Jellyfin revoking the session.
struct TopShelfSession: Codable, Equatable {
    var serverURL: URL
    var serverID: String
    var userID: String
    var accessToken: String
    var deviceID: String
    var deviceName: String

    static let keychainKey = "topshelf.session"

    static func make(
        server: ServerConfiguration?, credentials: StoredCredentials?, deviceID: String, deviceName: String
    ) -> TopShelfSession? {
        guard let server, let credentials,
              let token = credentials.accessToken, !token.isEmpty,
              let userID = credentials.userID,
              credentials.serverID == nil || credentials.serverID == server.id
        else { return nil }
        return TopShelfSession(
            serverURL: server.baseURL, serverID: server.id, userID: userID,
            accessToken: token, deviceID: deviceID, deviceName: deviceName
        )
    }
}

enum TopShelfSessionMirror {
    /// `nil` deletes the mirror (signing out).
    static func write(_ session: TopShelfSession?) {
        guard let session, let data = try? JSONEncoder().encode(session) else {
            KeychainStore.delete(forKey: TopShelfSession.keychainKey, scope: .allUsers)
            return
        }
        KeychainStore.save(data, forKey: TopShelfSession.keychainKey, scope: .allUsers)
    }

    static func read() -> TopShelfSession? {
        KeychainStore.load(forKey: TopShelfSession.keychainKey, scope: .allUsers)
            .flatMap { try? JSONDecoder().decode(TopShelfSession.self, from: $0) }
    }
}
```

In `DeviceIdentity`, an adopted identity wins over the stored one:

```swift
    /// Set only by the Top Shelf extension, which has its own defaults and
    /// must present the app's identity with the app's token (M6).
    nonisolated(unsafe) private static var adoptedDeviceID: String?
    nonisolated(unsafe) private static var adoptedDeviceName: String?

    static func adopt(deviceID: String?, deviceName: String?) {
        adoptedDeviceID = deviceID
        adoptedDeviceName = deviceName
    }
```

and `deviceID`/`deviceName` return the adopted value first when set. Check the `ServerConfiguration.id` property name in `Core/Models` and use the real one.

- [ ] **Step 4: Entitlements.** In `project.yml`, the `DionysusTV` entitlements gain:

```yaml
        # Shared with the Top Shelf extension: the session mirror
        # (TopShelfSession) lives in the user-independent keychain under it.
        keychain-access-groups:
          - $(AppIdentifierPrefix)com.imbenjamin.dionysusplayer
```

`xcodegen generate`.

- [ ] **Step 5: Run the tests** (tvOS unit, then iOS unit since `DeviceIdentity` is shared). Expected: PASS. Then on the tvOS 27 Simulator, launch the app already signed in: it must stay signed in after the entitlement change (the spike saw old items still found). Record in the ledger. The mirror is written in Task 10, which wires it to the app's lifecycle.

### Task 7: The Top Shelf content builder

**Files:**
- Create: `DionysusTV/TopShelf/TopShelfContentBuilder.swift`
- Modify: `DionysusPlayer/Core/Networking/JellyfinAPIClient.swift:356-375,418-426` (a `fields:` parameter on `resumeItems`, `latestItems`, `nextUp`)
- Test: `DionysusTVTests/TopShelfContentBuilderTests.swift`, `DionysusPlayerTests/Core/Networking/JellyfinAPIClientTests.swift` (three field tests)

**Interfaces:**
- Consumes: `TVDeepLink` (Task 5), `MediaItem`, `ImageURLBuilder`.
- Produces:

```swift
struct TopShelfEntry: Equatable {
    enum Context: Equatable { case continueWatching, nextUp, recentlyAdded }
    enum MediaOption: Equatable, Hashable { case hd, uhd4K, hdr, dolbyVision, atmos, closedCaptions }
    var id: String
    var title: String
    var contextTitle: String
    var summary: String?
    var genre: String?
    var duration: TimeInterval?
    var releaseYear: Int?
    var cast: [String]
    var mediaOptions: Set<MediaOption>
    var image1x: URL
    var image2x: URL
    var displayURL: URL
    var playURL: URL
}
enum TopShelfContentBuilder {
    static let continueWatchingLimit = 3
    static let totalLimit = 10
    static func entries(resume: [BaseItemDto], nextUp: [BaseItemDto], latest: [BaseItemDto],
                        images: ImageURLBuilder, serverID: String) -> [TopShelfEntry]
}
```

- `JellyfinAPIClient.resumeItems(userID:limit:excludeItemTypes:fields:)`, `latestItems(userID:parentID:limit:fields:)`, `nextUp(userID:seriesID:limit:fields:)`, each `fields: String = defaultFields`; `static let topShelfFields = "Overview,Genres,MediaSources,People,BasicSyncInfo"`.

- [ ] **Step 1: Write the failing client test** (add beside `test_resumeItems_asksForVideoOnly`):

```swift
    func test_listCalls_passTheFieldsAsked() async throws {
        let client = makeClient()
        var fields: [String] = []
        MockURLProtocol.requestHandler = { request in
            fields.append(request.queryDictionary["Fields"] ?? "")
            if request.url?.path.hasSuffix("/Items/Latest") == true {
                return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]())
            }
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        _ = try await client.resumeItems(userID: "u", fields: JellyfinAPIClient.topShelfFields)
        _ = try await client.nextUp(userID: "u", fields: JellyfinAPIClient.topShelfFields)
        _ = try await client.latestItems(userID: "u", fields: JellyfinAPIClient.topShelfFields)
        XCTAssertEqual(fields, Array(repeating: JellyfinAPIClient.topShelfFields, count: 3))
    }
```

- [ ] **Step 2: Write the failing builder tests**

```swift
import XCTest
@testable import Dionysus

/// The shelf's order and fill (Benjamin, 2026-10-14): the first 3 Continue
/// Watching items, then Next Up not already shown, then Recently Added,
/// 10 at most; nothing without art.
final class TopShelfContentBuilderTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://jf.local")!)
    private let server = "http://jf.local"

    private func movie(_ id: String, backdrop: Bool = true) -> BaseItemDto {
        var dto = BaseItemDto(id: id, name: "Movie \(id)", type: .movie)
        if backdrop { dto.backdropImageTags = ["tag-\(id)"] }
        return dto
    }

    private func episode(_ id: String, series: String, season: Int = 1, number: Int = 1) -> BaseItemDto {
        var dto = BaseItemDto(id: id, name: "Episode \(id)", type: .episode)
        dto.seriesId = series
        dto.seriesName = "Show \(series)"
        dto.parentIndexNumber = season
        dto.indexNumber = number
        dto.parentBackdropItemId = series
        dto.parentBackdropImageTags = ["tag-\(series)"]
        return dto
    }

    private func build(resume: [BaseItemDto] = [], nextUp: [BaseItemDto] = [], latest: [BaseItemDto] = []) -> [TopShelfEntry] {
        TopShelfContentBuilder.entries(resume: resume, nextUp: nextUp, latest: latest, images: images, serverID: server)
    }

    func test_takesTheFirstThreeResumeItems_thenNextUp_thenLatest_upToTen() {
        let resume = (1...5).map { movie("r\($0)") }
        let nextUp = (1...4).map { episode("n\($0)", series: "s\($0)") }
        let latest = (1...6).map { movie("l\($0)") }
        let ids = build(resume: resume, nextUp: nextUp, latest: latest).map(\.id)
        XCTAssertEqual(ids, ["r1", "r2", "r3", "n1", "n2", "n3", "n4", "l1", "l2", "l3"])
    }

    func test_fewerThanThreeResume_fillsFromNextUp() {
        let ids = build(resume: [movie("r1")], nextUp: [episode("n1", series: "s1")], latest: [movie("l1")]).map(\.id)
        XCTAssertEqual(ids, ["r1", "n1", "l1"])
    }

    func test_neverRepeatsAnItem_orAShowAlreadyResumed() {
        let resumed = episode("e1", series: "s1")
        let sameShowNext = episode("e2", series: "s1", number: 2)
        let ids = build(resume: [resumed], nextUp: [sameShowNext, episode("e9", series: "s9")], latest: [movie("e9"), movie("l1")]).map(\.id)
        XCTAssertEqual(ids, ["e1", "e9", "l1"])
    }

    func test_dropsItemsWithNoArt_andSeasonsOrShowsFromResume() {
        var season = BaseItemDto(id: "season", name: "Season 1", type: .season)
        season.backdropImageTags = ["t"]
        let ids = build(resume: [movie("bare", backdrop: false), season, movie("r1")]).map(\.id)
        XCTAssertEqual(ids, ["r1"])
    }

    func test_empty_isEmpty() {
        XCTAssertTrue(build().isEmpty)
    }

    func test_episode_isTitledByItsShow_withNumberInTheContextLine() throws {
        let entry = try XCTUnwrap(build(nextUp: [episode("e4", series: "s1", season: 2, number: 4)]).first)
        XCTAssertEqual(entry.title, "Show s1")
        XCTAssertEqual(entry.contextTitle, "Next Up · S2:E4 · Episode e4")
    }

    func test_contextLines_nameTheirSource() {
        let entries = build(resume: [movie("r1")], latest: [movie("l1")])
        XCTAssertEqual(entries.map(\.contextTitle), ["Continue Watching", "Recently Added"])
    }

    func test_art_isTheBackdropAt1080And4K() throws {
        let entry = try XCTUnwrap(build(resume: [movie("r1")]).first)
        XCTAssertTrue(entry.image1x.absoluteString.contains("/Items/r1/Images/Backdrop"))
        XCTAssertTrue(entry.image1x.absoluteString.contains("maxWidth=1920"))
        XCTAssertTrue(entry.image2x.absoluteString.contains("maxWidth=3840"))
    }

    func test_actions_areDeepLinksForThisServer() throws {
        let entry = try XCTUnwrap(build(resume: [movie("r1")]).first)
        XCTAssertEqual(TVDeepLink(url: entry.displayURL), TVDeepLink(action: .item, itemID: "r1", serverID: server))
        XCTAssertEqual(TVDeepLink(url: entry.playURL), TVDeepLink(action: .play, itemID: "r1", serverID: server))
    }

    func test_mediaOptions_comeFromTheDefaultSource() throws {
        var dto = movie("r1")
        dto.mediaSources = [MediaSourceInfo(id: "src", mediaStreams: [
            MediaStream(type: "Video", width: 3840, videoRangeType: "DOVIWithHDR10"),
            MediaStream(type: "Audio", codec: "eac3", audioSpatialFormat: "DolbyAtmos"),
            MediaStream(type: "Subtitle", isForced: false)
        ])]
        let entry = try XCTUnwrap(build(resume: [dto]).first)
        XCTAssertEqual(entry.mediaOptions, [.uhd4K, .dolbyVision, .atmos, .closedCaptions])
    }
}
```

Before running, check `MediaSourceInfo`/`MediaStream` initialisers in `JellyfinModels.swift` and adjust the `test_mediaOptions…` construction to the real memberwise signatures (they are structs with optional vars; if no memberwise init with these labels exists, build them with `var stream = MediaStream(...)` defaults and set properties, the way `MediaItemTests` does: `grep -n "MediaStream(" DionysusPlayerTests/Core/Models/MediaItemTests.swift`).

- [ ] **Step 3: Run to verify they fail.** Expected: FAIL (undefined types, missing `fields:` labels).

- [ ] **Step 4: Implement the client change.** Add `fields: String = defaultFields` as the last parameter of `resumeItems`, `latestItems` and `nextUp`, used in place of `Self.defaultFields`, and:

```swift
    /// What the Top Shelf shows per item (M6): the summary and genres, the
    /// default source's streams for its 4K/HDR/Atmos/CC badges, and the cast.
    static let topShelfFields = "Overview,Genres,MediaSources,People,BasicSyncInfo"
```

- [ ] **Step 5: Implement the builder**

```swift
import Foundation

/// One Top Shelf carousel item, platform-free so it's testable; the extension
/// turns it into a `TVTopShelfCarouselItem`.
struct TopShelfEntry: Equatable {
    enum Context: Equatable { case continueWatching, nextUp, recentlyAdded }
    enum MediaOption: Equatable, Hashable { case hd, uhd4K, hdr, dolbyVision, atmos, closedCaptions }

    var id: String
    var title: String
    var contextTitle: String
    var summary: String?
    var genre: String?
    var duration: TimeInterval?
    var releaseYear: Int?
    var cast: [String]
    var mediaOptions: Set<MediaOption>
    var image1x: URL
    var image2x: URL
    var displayURL: URL
    var playURL: URL
}

/// The shelf's content (Benjamin, 2026-10-14): the first 3 Continue Watching
/// items, then Next Up not already shown, then Recently Added, 10 at most.
/// An item is shown once, a show once (its resumed episode wins over its Next
/// Up), and a title with no backdrop up its chain is left out: a carousel
/// item without art draws an empty frame.
enum TopShelfContentBuilder {
    static let continueWatchingLimit = 3
    static let totalLimit = 10

    static func entries(
        resume: [BaseItemDto], nextUp: [BaseItemDto], latest: [BaseItemDto],
        images: ImageURLBuilder, serverID: String
    ) -> [TopShelfEntry] {
        var entries: [TopShelfEntry] = []
        var seenItems = Set<String>()
        var seenShows = Set<String>()

        func take(_ dtos: [BaseItemDto], as context: TopShelfEntry.Context, limit: Int) {
            var taken = 0
            for dto in dtos where taken < limit && entries.count < totalLimit {
                guard dto.type != .season, !(context == .continueWatching && dto.type == .series) else { continue }
                guard !seenItems.contains(dto.id) else { continue }
                if let show = dto.seriesId, seenShows.contains(show) { continue }
                guard let entry = entry(for: MediaItem(dto: dto, images: images), context: context, images: images, serverID: serverID) else { continue }
                entries.append(entry)
                seenItems.insert(dto.id)
                if let show = dto.seriesId { seenShows.insert(show) }
                taken += 1
            }
        }

        take(resume, as: .continueWatching, limit: continueWatchingLimit)
        take(nextUp, as: .nextUp, limit: totalLimit)
        take(latest, as: .recentlyAdded, limit: totalLimit)
        return entries
    }

    private static func entry(for item: MediaItem, context: TopShelfEntry.Context, images: ImageURLBuilder, serverID: String) -> TopShelfEntry? {
        guard let art = backdrop(of: item) else { return nil }
        let contextLabel = switch context {
        case .continueWatching: String(localized: "Continue Watching")
        case .nextUp: String(localized: "Next Up")
        case .recentlyAdded: String(localized: "Recently Added")
        }
        let contextTitle = item.kind == .episode
            ? [contextLabel, item.numberedEpisodeName].joined(separator: " \u{00B7} ")
            : contextLabel
        return TopShelfEntry(
            id: item.id,
            title: item.railTitle,
            contextTitle: contextTitle,
            summary: item.overview,
            genre: item.genres.first,
            duration: item.dto.runTimeTicks.map { TimeInterval($0) / 10_000_000 },
            releaseYear: item.dto.productionYear,
            cast: item.cast.prefix(4).map(\.name),
            mediaOptions: mediaOptions(item.metadataBadges),
            image1x: images.url(itemID: art.itemID, imageType: "Backdrop", tag: art.tag, maxWidth: 1920)!,
            image2x: images.url(itemID: art.itemID, imageType: "Backdrop", tag: art.tag, maxWidth: 3840)!,
            displayURL: TVDeepLink(action: .item, itemID: item.id, serverID: serverID).url,
            playURL: TVDeepLink(action: .play, itemID: item.id, serverID: serverID).url
        )
    }

    /// Jellyfin's own fallback: the item's backdrop, else the nearest
    /// ancestor's it names (an episode's show), as `MediaItem.backdropImageURL`.
    private static func backdrop(of item: MediaItem) -> (itemID: String, tag: String)? {
        if let tag = item.dto.backdropImageTags?.first { return (item.id, tag) }
        if let parent = item.dto.parentBackdropItemId, let tag = item.dto.parentBackdropImageTags?.first { return (parent, tag) }
        return nil
    }

    private static func mediaOptions(_ badges: [String]) -> Set<TopShelfEntry.MediaOption> {
        var options = Set<TopShelfEntry.MediaOption>()
        for badge in badges {
            switch badge {
            case "4K": options.insert(.uhd4K)
            case "HD": options.insert(.hd)
            case "Dolby Vision": options.insert(.dolbyVision)
            case "HDR10", "HDR10+", "HDR": options.insert(.hdr)
            case "Dolby Atmos": options.insert(.atmos)
            case "CC": options.insert(.closedCaptions)
            default: break
            }
        }
        return options
    }
}
```

`item.cast`'s element type is `CastMember` with a `name` (check `MediaItem.swift:613`); adjust if the property differs.

- [ ] **Step 6: Run the tests to verify they pass** (`DionysusTVTests/TopShelfContentBuilderTests`, then `DionysusPlayerTests/JellyfinAPIClientTests` on iOS). Expected: PASS. If `test_neverRepeatsAnItem…` fails on `e9` (the Recently Added movie shares the episode's id only in this synthetic test), keep the rule and the test: ids are unique per server.

### Task 8: The Top Shelf extension

**Files:**
- Create: `DionysusTV/TopShelf/TopShelfLoader.swift` (in the app target too, so `DionysusTVTests` can test it)
- Create: `DionysusTVTopShelf/ContentProvider.swift`
- Modify: `project.yml` (the `DionysusTVTopShelf` target, the app's dependency on it)
- Test: `DionysusTVTests/TopShelfLoaderTests.swift`
- Docs: `DionysusTV/CLAUDE.md` (new "Top Shelf" section), root `CLAUDE.md` ("The Apple TV target, in brief": the extension and what it compiles), the parent spec's Non-goals line

**Interfaces:**
- Consumes: `TopShelfContentBuilder.entries(...)`, `JellyfinAPIClient.topShelfFields`, `TopShelfSession`/`TopShelfSessionMirror`, `DeviceIdentity.adopt` (Task 6).
- Produces: `enum TopShelfLoader { static func load(session: TopShelfSession?, urlSession: URLSession) async -> [TopShelfEntry] }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Dionysus

/// The extension's fetch (M6): nothing without the mirrored session or a
/// server answering; never a password sign-in (Review Focus 1).
final class TopShelfLoaderTests: XCTestCase {
    private let session = TopShelfSession(
        serverURL: URL(string: "http://jf.local")!, serverID: "http://jf.local", userID: "u1",
        accessToken: "tok", deviceID: "dev", deviceName: "Bedroom"
    )

    override func tearDown() {
        MockURLProtocol.reset()
        DeviceIdentity.adopt(deviceID: nil, deviceName: nil)
        super.tearDown()
    }

    func test_noSession_loadsNothing_andAsksNothing() async {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: [], totalRecordCount: 0))
        }
        let entries = await TopShelfLoader.load(session: nil, urlSession: MockURLProtocol.makeSession())
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(requests, 0)
    }

    func test_401_loadsNothing_withoutSigningIn() async {
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            return MockURLProtocol.jsonResponse(for: request, status: 401, body: Data())
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/AuthenticateByName") }, "The extension never signs in")
    }

    func test_success_buildsEntries_presentingTheAppsDeviceID() async {
        var headers: [String] = []
        MockURLProtocol.requestHandler = { request in
            headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let path = request.url?.path ?? ""
            if path.hasSuffix("/Items/Latest") { return try MockURLProtocol.encodedJSONResponse(for: request, value: [BaseItemDto]()) }
            var movie = BaseItemDto(id: "m1", name: "Arrival", type: .movie)
            movie.backdropImageTags = ["t"]
            let items = path.hasSuffix("/Items/Resume") ? [movie] : []
            return try MockURLProtocol.encodedJSONResponse(for: request, value: BaseItemDtoQueryResult(items: items, totalRecordCount: items.count))
        }
        let entries = await TopShelfLoader.load(session: session, urlSession: MockURLProtocol.makeSession())
        XCTAssertEqual(entries.map(\.id), ["m1"])
        XCTAssertTrue(headers.allSatisfy { $0.contains("DeviceId=\"dev\"") }, "Every request carries the app's device id")
    }
}
```

- [ ] **Step 2: Run to verify they fail.** Expected: FAIL, `TopShelfLoader` undefined.

- [ ] **Step 3: Implement the loader**

```swift
import Foundation

/// The Top Shelf extension's fetch (M6), in the app target as well so it's
/// unit-tested. It uses the session the app mirrored (`TopShelfSession`),
/// presenting the app's own device id, and never signs in: with no usable session, the shelf falls
/// back to the static Top Shelf image.
enum TopShelfLoader {
    /// tvOS gives the extension little time; a slow server shows the static
    /// image rather than holding the shelf.
    static let timeout: TimeInterval = 8

    static func load(session: TopShelfSession?, urlSession: URLSession) async -> [TopShelfEntry] {
        guard let session else { return [] }
        // The app's identity, so the token is presented with the device id
        // it was issued to.
        DeviceIdentity.adopt(deviceID: session.deviceID, deviceName: session.deviceName)
        let userID = session.userID
        let client = JellyfinAPIClient(baseURL: session.serverURL, accessToken: session.accessToken, session: urlSession)
        do {
            async let resume = client.resumeItems(
                userID: userID, excludeItemTypes: JellyfinAPIClient.audioItemTypeExclusions, fields: JellyfinAPIClient.topShelfFields)
            async let nextUp = client.nextUp(userID: userID, limit: TopShelfContentBuilder.totalLimit, fields: JellyfinAPIClient.topShelfFields)
            async let latest = client.latestItems(userID: userID, limit: TopShelfContentBuilder.totalLimit, fields: JellyfinAPIClient.topShelfFields)
            return try await TopShelfContentBuilder.entries(
                resume: resume.items, nextUp: nextUp.items, latest: latest,
                images: client.makeImageURLBuilder(), serverID: session.serverID
            )
        } catch {
            return []
        }
    }

    /// A session for the extension, with `timeout` on every request.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }
}
```

The client re-authenticates on a 401 only with `reauthCredentials`, which only `authenticate(...)` sets, so a fresh client surfaces `.notAuthenticated` at once (Review Focus 1). If `test_401…` shows otherwise, stop and read `sendRaw`.

- [ ] **Step 4: Run the loader tests to verify they pass.**

- [ ] **Step 5: Add the extension target** (from the spike, now real) to `project.yml`:

```yaml
  # The Top Shelf (M6): Continue Watching, Next Up and Recently Added as a
  # `.details` carousel, fetched live with the app's stored session. Compiles
  # the networking and model layers and the session stores, never
  # AetherEngine or UI, to stay inside an extension's memory limit.
  DionysusTVTopShelf:
    type: tv-app-extension
    platform: tvOS
    deploymentTarget: "26.0"
    sources:
      - path: DionysusTVTopShelf
        excludes:
          - "**/CLAUDE.md"
      - path: DionysusTV/TopShelf
      - path: DionysusPlayer/Core/Networking
        excludes:
          - "ServerDiscovery.swift"
          - "LocalNetworkPermission.swift"
          - "TrickplayThumbnailProvider.swift"
          - "RemoteImageLoader.swift"
      - path: DionysusPlayer/Core/Models
      - path: DionysusPlayer/Core/Persistence/KeychainStore.swift
      - path: DionysusPlayer/Core/Persistence/TopShelfSession.swift
      - path: DionysusPlayer/Core/Persistence/DeviceIdentity.swift
      - path: DionysusPlayer/Shared/AppVersion.swift
      - path: DionysusPlayer/Resources/Localizable.xcstrings
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.imbenjamin.dionysusplayer.topshelf
        PRODUCT_NAME: DionysusTopShelf
        SWIFT_EMIT_LOC_STRINGS: YES
        TARGETED_DEVICE_FAMILY: "3"
        # Xcode links a tv-app-extension with -e _TVExtensionMain; the
        # TVTopShelfContentProvider API needs NSExtensionMain, or the
        # extension exits at launch (spike, as Sodalite).
        OTHER_LDFLAGS: -e _NSExtensionMain
    entitlements:
      path: Generated/DionysusTVTopShelf.entitlements
      properties:
        # The session mirror lives in the user-independent keychain under
        # this group. No user-management entitlement: with or without it the
        # extension reads the default profile's keychain (spike).
        keychain-access-groups:
          - $(AppIdentifierPrefix)com.imbenjamin.dionysusplayer
    info:
      path: Generated/Info-TopShelf.plist
      properties:
        CFBundleDisplayName: Dionysus
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        # Self-hosted servers on plain http, as the app.
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        NSExtension:
          NSExtensionPointIdentifier: com.apple.tv-top-shelf
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ContentProvider
```

Add `- target: DionysusTVTopShelf` to `DionysusTV.dependencies`. Run `xcodegen generate` and build the `DionysusTV` scheme. If the extension fails to compile on a type from a file not listed (e.g. `ConnectivityMonitor` pulls in something), add that one file to its sources, or exclude the file that needs UI; record each addition in the ledger. Nothing under `Features/` or `DionysusTV/` other than `DionysusTV/TopShelf` goes in.

- [ ] **Step 6: Write the provider**

```swift
import TVServices

/// The Top Shelf (M6). tvOS calls this when the app's icon is in the top row
/// and on its own schedule; the app also asks for a refresh after playback,
/// sign-in or a watched change (`TopShelfRefresh`).
final class ContentProvider: TVTopShelfContentProvider {
    /// The completion-handler form: the `async` override doesn't compile
    /// under Swift 6 (its return isn't Sendable; spike).
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        Task {
            let entries = await TopShelfLoader.load(
                session: TopShelfSessionMirror.read(), urlSession: TopShelfLoader.makeSession()
            )
            completionHandler(entries.isEmpty ? nil : TVTopShelfCarouselContent(style: .details, items: entries.map(Self.item)))
        }
    }

    private static func item(_ entry: TopShelfEntry) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: entry.id)
        item.title = entry.title
        item.contextTitle = entry.contextTitle
        item.summary = entry.summary
        item.genre = entry.genre
        if let duration = entry.duration { item.duration = duration }
        if let year = entry.releaseYear {
            item.creationDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: year))
        }
        if !entry.cast.isEmpty {
            item.namedAttributes = [TVTopShelfNamedAttribute(name: String(localized: "Starring"), values: entry.cast)]
        }
        item.mediaOptions = mediaOptions(entry.mediaOptions)
        // 2x only: the scale Apple TV renders (Sodalite: setting both doubles
        // the system's fetches).
        item.setImageURL(entry.image2x, for: .screenScale2x)
        item.displayAction = TVTopShelfAction(url: entry.displayURL)
        item.playAction = TVTopShelfAction(url: entry.playURL)
        return item
    }

    private static func mediaOptions(_ options: Set<TopShelfEntry.MediaOption>) -> TVTopShelfCarouselItem.MediaOptions {
        var result: TVTopShelfCarouselItem.MediaOptions = []
        if options.contains(.uhd4K) { result.insert(.videoResolution4K) } else if options.contains(.hd) { result.insert(.videoResolutionHD) }
        if options.contains(.dolbyVision) { result.insert(.videoColorSpaceDolbyVision) } else if options.contains(.hdr) { result.insert(.videoColorSpaceHDR) }
        if options.contains(.atmos) { result.insert(.audioDolbyAtmos) }
        if options.contains(.closedCaptions) { result.insert(.audioTranscriptionClosedCaptioning) }
        return result
    }
}
```

Check each `MediaOptions` constant name against the SDK (`mcp__xcode__DocumentationSearch` "TVTopShelfCarouselItem.MediaOptions") and fix any that differ. If the `Task { }` capturing `completionHandler` trips Swift 6's sendability checks, wrap the handler in a small `@unchecked Sendable` box and record it in the ledger.

- [ ] **Step 7: Check on the tvOS 27 Simulator.** Build and run `DionysusTV` (it embeds the extension), signed in as Ben; move the app to the Home Screen's top row; focus it. The mirror is only written once Task 10 wires it, so until then write it once from a throwaway line in the app (reverted). Expected: the carousel with Continue Watching first, with the summary, context line and attributes drawn (a title alone draws nothing, spike). Select a backdrop (display action) and press Play/Pause on one (play action): the app opens (routing comes in Task 9; for now it just launches). Sign out in the app, return to the Home Screen: the static Top Shelf image. Screenshots to the scratchpad; show Benjamin.

- [ ] **Step 8: Docs.** `DionysusTV/CLAUDE.md`, new section "## Top Shelf" (after "Profile and settings"): what it shows and why (Benjamin's rule), that it fetches live with the session the app mirrors into the user-independent keychain (the last-used profile's, because the extension reads the default profile's keychain whichever is active: spike), the device-id rule, the `_NSExtensionMain` link flag, what makes it fall back to the static image, and that the logo is parked. Root `CLAUDE.md`, "The Apple TV target, in brief": add a sentence on `DionysusTVTopShelf` and its sources list. Parent spec: delete "Top Shelf" from "Non-goals".

### Task 9: Routing deep links in the app

**Files:**
- Create: `DionysusTV/TopShelf/TVDeepLinkRouter.swift`
- Modify: `DionysusTV/DionysusTVApp.swift` (`TVRootView`: `.onOpenURL`, pending link held until `.main`)
- Modify: `DionysusTV/Browse/TVMainView.swift` (apply a link: drop the path, open the detail page, play over it)
- Test: `DionysusTVTests/TVDeepLinkRouterTests.swift`, `DionysusTVUITests/TopShelfLinkJourneyTests.swift`

**Interfaces:**
- Consumes: `TVDeepLink`, `TVHeroPlayTarget.resolve(_:client:userID:)`, `TVPlayerPresenter.present/dismissPlayer`, `TVMainView.open(_:)`, `openDetailBeneathPlayer(_:)`.
- Produces:

```swift
enum TVDeepLinkRouter {
    enum Decision: Equatable { case wait, ignore, openDetail(itemID: String), play(itemID: String) }
    static func decide(_ link: TVDeepLink, isRestoringSession: Bool, isSignedIn: Bool, serverID: String?) -> Decision
}
extension EnvironmentValues { @Entry var tvPendingDeepLink: TVDeepLink? }  // read by TVMainView
```

- [ ] **Step 1: Write the failing router tests**

```swift
import XCTest
@testable import Dionysus

final class TVDeepLinkRouterTests: XCTestCase {
    private let link = TVDeepLink(action: .item, itemID: "m1", serverID: "http://jf.local")

    func test_waitsWhileTheSessionRestores() {
        XCTAssertEqual(TVDeepLinkRouter.decide(link, isRestoringSession: true, isSignedIn: false, serverID: nil), .wait)
    }

    func test_ignoresALinkWhenSignedOut_orForAnotherServer() {
        XCTAssertEqual(TVDeepLinkRouter.decide(link, isRestoringSession: false, isSignedIn: false, serverID: "http://jf.local"), .ignore)
        XCTAssertEqual(TVDeepLinkRouter.decide(link, isRestoringSession: false, isSignedIn: true, serverID: "http://other"), .ignore)
    }

    func test_itemOpensTheDetailPage_playPlaysIt() {
        XCTAssertEqual(TVDeepLinkRouter.decide(link, isRestoringSession: false, isSignedIn: true, serverID: "http://jf.local"), .openDetail(itemID: "m1"))
        var play = link
        play.action = .play
        XCTAssertEqual(TVDeepLinkRouter.decide(play, isRestoringSession: false, isSignedIn: true, serverID: "http://jf.local"), .play(itemID: "m1"))
    }
}
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement the router**

```swift
import SwiftUI

/// What a Top Shelf link does on arrival (M6). A link waits while the session
/// restores (a cold launch from the shelf), and is dropped when nobody is
/// signed in or it was built for another server: the shelf may be a few
/// minutes older than a sign-out or a server change.
enum TVDeepLinkRouter {
    enum Decision: Equatable {
        case wait
        case ignore
        case openDetail(itemID: String)
        case play(itemID: String)
    }

    static func decide(_ link: TVDeepLink, isRestoringSession: Bool, isSignedIn: Bool, serverID: String?) -> Decision {
        if isRestoringSession { return .wait }
        guard isSignedIn, serverID == link.serverID else { return .ignore }
        switch link.action {
        case .item: return .openDetail(itemID: link.itemID)
        case .play: return .play(itemID: link.itemID)
        }
    }
}

extension EnvironmentValues {
    /// A Top Shelf link for `TVMainView` to apply; set by `TVRootView`, which
    /// clears it once applied.
    @Entry var tvPendingDeepLink: TVDeepLink? = nil
    @Entry var tvDeepLinkApplied: @MainActor () -> Void = {}
}
```

- [ ] **Step 4: Run the router tests to verify they pass.**

- [ ] **Step 5: Wire `TVRootView`.** Add `@State private var pendingLink: TVDeepLink?`; on the `Group`:

```swift
        .onOpenURL { url in pendingLink = TVDeepLink(url: url) }
        .environment(\.tvPendingDeepLink, appliedLink)
        .environment(\.tvDeepLinkApplied, { pendingLink = nil })
```

with

```swift
    /// The pending link once the router says it can go; a dropped one is
    /// cleared here, a waiting one is kept until the session has restored.
    private var appliedLink: TVDeepLink? {
        guard let pendingLink else { return nil }
        switch TVDeepLinkRouter.decide(
            pendingLink,
            isRestoringSession: appState.isRestoringSession,
            isSignedIn: appState.phase == .main,
            serverID: appState.sessionStore.serverConfiguration?.id
        ) {
        case .wait: return nil
        case .ignore:
            Task { @MainActor in self.pendingLink = nil }
            return nil
        case .openDetail, .play: return pendingLink
        }
    }
```

- [ ] **Step 6: Apply it in `TVMainView`.** Read `@Environment(\.tvPendingDeepLink)` and `@Environment(\.tvDeepLinkApplied)`; add `.onChange(of: pendingLink, initial: true) { _, link in if let link { apply(link) } }` and:

```swift
    /// A Top Shelf link (M6): Home with its path dropped, the title's page
    /// pushed over it, and for Play the player over that page, as the hero's
    /// Play does, so Menu lands on the page.
    private func apply(_ link: TVDeepLink) {
        deepLinkApplied()
        TVPlayerPresenter.dismissPlayer()
        if nav.destination != .home || !nav.path.isEmpty { select(.home) }
        Task { @MainActor in
            // Lets the dismissal and Home's rebuild land before the push.
            try? await Task.sleep(for: .milliseconds(300))
            let item: MediaItem
            if let dto = try? await client.item(userID: userID, itemID: link.itemID) {
                item = MediaItem(dto: dto, images: await client.makeImageURLBuilder())
            } else {
                // Gone or not this user's: the page shows its own error and Retry.
                open(.assetDetail(itemID: link.itemID, preloadedItem: nil))
                return
            }
            guard link.action == .play,
                  let target = await TVHeroPlayTarget.resolve(item, client: client, userID: userID) else {
                open(.assetDetail(itemID: item.id, preloadedItem: item))
                return
            }
            var playbackEnded: (@MainActor (PlaybackSessionOutcome) -> Void)?
            let presented = TVPlayerPresenter.present(PlaybackRequest(itemID: target), client: client, userID: userID) { outcome in
                playbackEnded?(outcome)
            }
            if presented { playbackEnded = openDetailBeneathPlayer(item) } else { open(.assetDetail(itemID: item.id, preloadedItem: item)) }
        }
    }
```

Check `client.item(userID:itemID:)`'s real name and fields parameter (`JellyfinAPIClient.swift:~345`) and `AppRoute.assetDetail`'s `preloadedItem` optionality, and adjust. Closing a player reports its stop through `close()` (`TVPlaybackSession.end()`); confirm `dismissPlayer()` goes through it. If `TVPlayerPresenter.present` refuses because the dismissed player is still in the presented chain, wait for `presentedViewController == nil` (poll every 50ms, up to 2s) before presenting, and record that in the ledger.

- [ ] **Step 7: Write the UI journeys**

```swift
import XCTest

/// Top Shelf links (M6), opened as tvOS opens them.
final class TopShelfLinkJourneyTests: TVUITestCase {
    private func link(_ action: String, _ itemID: String) -> URL {
        var components = URLComponents()
        components.scheme = "dionysus"
        components.host = action
        components.path = "/" + itemID
        components.queryItems = [URLQueryItem(name: "server", value: UITestFixtureIdentity.serverAddress)]
        return components.url!
    }

    func test_itemLink_opensTheDetailPage_overHome() {
        let app = launchAtHome()
        app.open(link("item", UITestFixtureIdentity.primaryMovieID))
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(play))
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]), "Menu goes back to Home")
    }

    func test_playLink_playsOverTheDetailPage() {
        let app = launchAtHome()
        app.open(link("play", UITestFixtureIdentity.primaryMovieID))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Detail.play]), "Leaving the player lands on the title's page")
    }

    func test_playLink_whilePlaying_switchesTitle() {
        let app = openEpisodeOne(scenario: "standard")
        app.open(link("play", UITestFixtureIdentity.primaryMovieID))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Player.elapsed].waitForExistence(timeout: 10))
        press(.menu)
        let play = app.buttons[A11yID.TV.Detail.play]
        XCTAssertTrue(waitForFocus(play))
        XCTAssertTrue(app.staticTexts[A11yID.TV.Detail.title].label.isEmpty == false)
        XCTAssertFalse(app.descendants(matching: .any)[A11yID.TV.Detail.title].label.contains(UITestFixtureIdentity.seriesName),
                       "The page is the movie's, not the episode's show")
    }

    func test_linkForAnotherServer_isIgnored() {
        let app = launchAtHome()
        var components = URLComponents(url: link("item", UITestFixtureIdentity.primaryMovieID), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "server", value: "http://elsewhere.invalid")]
        app.open(components.url!)
        XCTAssertFalse(app.buttons[A11yID.TV.Detail.play].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.heroPlay]))
    }

    func test_itemLink_forAMissingTitle_opensAPageWithRetry() {
        let app = launchAtHome()
        app.open(link("item", "no-such-item"))
        XCTAssertTrue(app.buttons[A11yID.TV.Detail.retry].waitForExistence(timeout: 10))
    }
}
```

Before running, check: the stub's `ServerConfiguration.id` is `UITestFixtureIdentity.serverAddress` (it's `baseURL.absoluteString`; adjust for a trailing slash if the stub stores one); the stub answers an unknown item id with an error (if it returns 200 with a placeholder, change the last test to assert what the stub does and note it). `test_playLink_whilePlaying…`'s title assertion should use the detail title identifier as the other journeys do (`DetailJourneyTests`); align it with theirs.

- [ ] **Step 8: Run the router tests and the new journeys**, then the full tvOS suites. Expected: PASS. If `XCUIApplication.open(_:)` hands the URL to the system instead of the app under test on the Simulator, open it with `XCUIDevice.shared.system.open(_:)` (tvOS 16.4+), and record which works.

### Task 10: Mirroring the session and refreshing the shelf

**Files:**
- Create: `DionysusTV/TopShelf/TopShelfRefresh.swift`
- Modify: `DionysusTV/Player/TVPlaybackSession.swift` (on end), `DionysusPlayer/App/AppState.swift` (session restore, sign-in paths incl. Quick Connect, `signOut`, `signOutForgettingAccount`, `signIn(rememberedAccount:)`; inside `#if os(tvOS)`), `DionysusTV/DionysusTVApp.swift` (scene becoming active with a session), `DionysusPlayer/Features/AssetDetails/AssetDetailViewModel.swift` (after a watched toggle succeeds; inside `#if os(tvOS)`)
- Test: `DionysusTVTests/TopShelfRefreshTests.swift`

**Interfaces:**
- Consumes: `TopShelfSession.make`, `TopShelfSessionMirror` (Task 6).
- Produces: `enum TopShelfRefresh { @MainActor static var notify: () -> Void; @MainActor static func contentChanged(); @MainActor static func sessionChanged(_ session: TopShelfSession?) }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Dionysus

@MainActor
final class TopShelfRefreshTests: XCTestCase {
    private var calls = 0
    private var saved: (() -> Void)!

    override func setUp() {
        super.setUp()
        saved = TopShelfRefresh.notify
        TopShelfRefresh.notify = { [unowned self] in calls += 1 }
    }

    override func tearDown() {
        TopShelfRefresh.notify = saved
        super.tearDown()
    }

    private let suiteName = "com.dionysusplayer.tests.TopShelfRefreshTests"

    func test_signOut_deletesTheMirror_andRefreshesTheShelf() throws {
        TopShelfSessionMirror.write(TopShelfSession(
            serverURL: URL(string: "http://jf.local")!, serverID: "http://jf.local", userID: "u1",
            accessToken: "tok", deviceID: "d", deviceName: "n"
        ))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let state = AppState(sessionStore: ServerSessionStore(defaults: defaults))
        state.signOut()
        XCTAssertNil(TopShelfSessionMirror.read(), "A signed-out app leaves the shelf nothing to fetch with")
        XCTAssertEqual(calls, 1)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_sessionChanged_writesTheMirror_andRefreshes() {
        let session = TopShelfSession(
            serverURL: URL(string: "http://jf.local")!, serverID: "http://jf.local", userID: "u1",
            accessToken: "tok", deviceID: "d", deviceName: "n"
        )
        TopShelfRefresh.sessionChanged(session)
        defer { TopShelfSessionMirror.write(nil) }
        XCTAssertEqual(TopShelfSessionMirror.read(), session)
        XCTAssertEqual(calls, 1)
    }

    /// `end()` returns an outcome only once a session has started; one never
    /// started reports nothing and asks for no refresh.
    func test_endingASessionThatNeverStarted_leavesTheShelf() {
        let viewModel = PlayerViewModel(
            client: JellyfinAPIClient(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok", session: MockURLProtocol.makeSession()),
            userID: "user-1", itemID: "item-1", engine: FakePlaybackEngine()
        )
        let session = TVPlaybackSession(viewModel: viewModel)
        XCTAssertNil(session.end())
        XCTAssertEqual(calls, 0)
    }
}
```

Add one more test, `test_endingAStartedSession_refreshesTheShelf`, by copying the setup of `TVPlaybackSessionTests`' test that starts playback and reads `end()`'s outcome (`grep -n "end()" DionysusTVTests/TVPlaybackSessionTests.swift`), then asserting `calls == 1` after `end()`. If `end()` returns an outcome even for a session never started, change the second test's expectation to match `end()`'s documented contract and refresh only when it returns one.

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement**

```swift
import TVServices

/// Asks tvOS to reload the Top Shelf (M6) after what changes it: a playback
/// session ending, signing in or out or switching account, and a watched
/// toggle. tvOS also refreshes it on its own schedule.
enum TopShelfRefresh {
    /// Replaced in tests.
    @MainActor static var notify: () -> Void = { TVTopShelfContentProvider.topShelfContentDidChange() }

    @MainActor static func contentChanged() { notify() }

    /// Mirrors the session the shelf fetches with (`nil` on sign-out) and
    /// reloads it. The shelf shows whoever last used Dionysus: the extension
    /// can't read the current Apple TV profile's keychain (spike).
    @MainActor static func sessionChanged(_ session: TopShelfSession?) {
        TopShelfSessionMirror.write(session)
        notify()
    }
}
```

Call `TopShelfRefresh.contentChanged()` at the end of `TVPlaybackSession.end()` (only when it returns an outcome) and in `AssetDetailViewModel`'s watched toggle after the server call succeeds. Call `TopShelfRefresh.sessionChanged(TopShelfSession.make(server:credentials:deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName))` in `AppState` once a session is restored at launch, after each successful sign-in path (password, Quick Connect, remembered account), and from `DionysusTVApp` when the scene becomes active while in `.main` (that's what makes the shelf follow the profile now using the app); call `TopShelfRefresh.sessionChanged(nil)` in `signOut()` and `signOutForgettingAccount()`. Read the server and credentials from `AppState`'s own session store, not new reads of the keychain. In shared files wrap each call in `#if os(tvOS)`. `TopShelfRefresh.swift` lives in `DionysusTV/TopShelf/`, which the app compiles; the extension also compiles that folder, so guard the file's content with `#if !TOPSHELF_EXTENSION` … or, simpler, move `TopShelfRefresh.swift` to `DionysusTV/Shell/` so the extension never compiles it. Do the latter.

- [ ] **Step 4: Run the tests to verify they pass**, then all four suites (shared files changed).

- [ ] **Step 5: Check on the Simulator**: signed in, go to the Home Screen: the shelf shows Ben's rows (the mirror was written at launch). Watch a few minutes of a new title, close it, go back: the title leads the shelf within seconds. Sign out: the static image. Per-profile behaviour (the shelf follows the last profile to open Dionysus) is checked on Bedroom in Task 11.

- [ ] **Step 6: Strings and docs.** Sync `Localizable.xcstrings` ("Continue Watching", "Next Up", "Recently Added" already exist; "Starring" is new). Add the refresh triggers to `DionysusTV/CLAUDE.md`'s "Top Shelf" section. Update `PRIVACY.md` with one line in the relevant section: the Top Shelf shows your Continue Watching, Next Up and recently added titles from your own server, fetched on the Apple TV with a copy of your session that the app keeps in the Apple TV's shared keychain, so it shows the rows of whoever used Dionysus last.

- [ ] **Step 7: Sign-off, commit, PR 3.** Re-point Simulators. Commits: one per task (5–10) or one squashed set as Benjamin prefers at sign-off. PR "Top Shelf for the Apple TV app"; merge on green.

---

## PR 4: Interim device pass

### Task 11: Bedroom Apple TV pass

**Files:** fixes only, as found. Ledger.

- [ ] **Step 1: Ask Benjamin** for the Bedroom Apple TV, then build and install a Debug build of `DionysusTV` (with the extension) per [[physical-device-cli-deployment]].
- [ ] **Step 2: Now Playing**: play an HDR movie (native route); open Control Center with the TV button: title, art, pause/play, ±10s, scrub. Let an episode count down into the next: the tile changes. If a software-route title exists in the library (AV1/VP9), repeat.
- [ ] **Step 3: Top Shelf, last-used profile**: as Ben, check the shelf's order (3 resume, then Next Up, then Recently Added), badges (4K/HDR/DV/Atmos), how many items show and how long text truncates, and both actions from a cold app (force-quit first) and a warm one. Switch to Tara's profile: the shelf still shows Ben's rows (expected, Benjamin 2026-10-14); open Dionysus as Tara and return: Tara's rows. Sign out on one profile: the static image until a profile with a session opens Dionysus. Watch something on the iPhone app, return to the Apple TV Home Screen: the shelf reflects it after a refresh.
- [ ] **Step 4: Fix what the device shows**, each fix test-first where it's code, re-checked on the device by Benjamin.
- [ ] **Step 5: Suites, sign-off, commit, PR** ("M6 device pass: Now Playing and Top Shelf"), merge.

---

## PR 5: Release pipeline

### Task 12: Portal setup through the App Store Connect API

**Files:** none in the repo; ledger records each ID created.

- [ ] **Step 1: Read the current state** with the hand-rolled ES256 JWT ([[asc-api-direct-queries]]): `GET /v1/apps?filter[bundleId]=com.imbenjamin.dionysusplayer&include=appStoreVersions` (platforms present), `GET /v1/bundleIds?filter[identifier]=com.imbenjamin.dionysusplayer,com.imbenjamin.dionysusplayer.topshelf&include=bundleIdCapabilities`, `GET /v1/profiles?filter[name]=Dionysus App Store,Dionysus tvOS App Store,Dionysus Top Shelf App Store`, `GET /v1/certificates?filter[certificateType]=DISTRIBUTION`.
- [ ] **Step 2: Tell Benjamin exactly what will be created**, then, one call at a time, recording each response:
  1. ~~`POST /v1/bundleIds` for the extension~~: done in the spike (2026-10-14): `9GM3388778`, `com.imbenjamin.dionysusplayer.topshelf`, "Dionysus Top Shelf", UNIVERSAL, with USER_MANAGEMENT enabled. The shipped extension doesn't use user-management, so `DELETE /v1/bundleIdCapabilities/9GM3388778_USER_MANAGEMENT` before making its profile (announce it).
  2. `POST /v1/bundleIdCapabilities` for keychain sharing on both bundle IDs if the API lists it as a capability (it may be implicit; skip if `GET /v1/bundleIds/{id}/bundleIdCapabilities` shows no such type is needed).
  3. `POST /v1/profiles` `{name: "Dionysus tvOS App Store", profileType: "TVOS_APP_STORE"}` with the app's bundle ID and the distribution certificate.
  4. `POST /v1/profiles` `{name: "Dionysus Top Shelf App Store", profileType: "TVOS_APP_STORE"}` with the extension's bundle ID and the certificate.
  5. Re-create "Dionysus App Store" (IOS_APP_STORE) if Step 1 shows it invalid after the capability change: delete it and `POST` it again under the same name (the API has no "re-save").
  6. The tvOS platform on the app record: `POST /v1/appStoreVersions` `{platform: "TV_OS", versionString: "<next version>"}` for the app. If the API refuses because the platform must be added in the web UI first, ask Benjamin to add it (App Store Connect → the app → "+" beside the platforms) and continue.
- [ ] **Step 3: Verify** with the Step 1 queries: both new profiles `ACTIVE`, the iOS profile `ACTIVE`, a `TV_OS` version on the app.

### Task 13: Signing configuration and a local archive

**Files:**
- Modify: `project.yml` (`DionysusTV` and `DionysusTVTopShelf` `configs.Release`)
- Create: `Config/ExportOptions-tvOS.plist`
- Docs: `VERSIONING.md` ("Signing setup": the two profiles, the shared App ID trap now covering three profiles)

- [ ] **Step 1: Release signing in `project.yml`**, mirroring the iOS app target's block (`project.yml:185-190`):

```yaml
    configs:
      Release:
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: Apple Distribution
        PROVISIONING_PROFILE_SPECIFIER: Dionysus tvOS App Store
```

on `DionysusTV`'s `settings`, and the same with `Dionysus Top Shelf App Store` on `DionysusTVTopShelf`. `xcodegen generate`.

- [ ] **Step 2: Export options**: copy `Config/ExportOptions.plist` to `Config/ExportOptions-tvOS.plist`, keep every key and comment, change the header comment to say it's the Apple TV export (`release.yml`'s `tvos-release` job), and set:

```xml
	<key>provisioningProfiles</key>
	<dict>
		<key>com.imbenjamin.dionysusplayer</key>
		<string>Dionysus tvOS App Store</string>
		<key>com.imbenjamin.dionysusplayer.topshelf</key>
		<string>Dionysus Top Shelf App Store</string>
	</dict>
```

- [ ] **Step 3: Archive and export locally** (the Mac has the distribution identity; download the two profiles first with the API or Xcode):

```bash
xcodebuild archive -project DionysusPlayer.xcodeproj -scheme DionysusTV -configuration Release \
  -destination 'generic/platform=tvOS' -archivePath "$SCRATCH/DionysusTV.xcarchive"
xcodebuild -exportArchive -archivePath "$SCRATCH/DionysusTV.xcarchive" \
  -exportOptionsPlist Config/ExportOptions-tvOS.plist -exportPath "$SCRATCH/tv-export"
codesign -dvv "$SCRATCH/tv-export/"*.ipa 2>&1 | head; unzip -l "$SCRATCH/tv-export/"*.ipa | grep -i "PlugIns/DionysusTopShelf.appex"
```

Expected: an `.ipa` signed "Apple Distribution" with the extension embedded. Record in the ledger. Do not upload.

- [ ] **Step 4: Docs.** `VERSIONING.md`, "Signing setup": list all three profiles, their bundle IDs and types, that the export for tvOS uses `Config/ExportOptions-tvOS.plist`, and that a capability change on the shared App ID invalidates all three.

### Task 14: The release workflow

**Files:**
- Modify: `.github/workflows/release.yml` (restructure into `ui-tests`, `tv-ui-tests`, `prepare`, `ios-release`, `tvos-release`, `publish`)
- Modify: `.github/workflows/pr-checks.yml` (`release-build` job: a tvOS step)
- Docs: `VERSIONING.md` (the release flow), `TESTING.md` ("Where they run in CI"), root `CLAUDE.md` ("Cutting a release")

- [ ] **Step 1: `prepare` job.** Move the "Resolve tag", "Checkout", "Verify the tag is on the right branch" and "Compose release notes" steps out of `build-test-release` into a new job:

```yaml
  prepare:
    name: Resolve the tag and compose release notes
    runs-on: macos-26
    timeout-minutes: 10
    outputs:
      tag: ${{ steps.tag.outputs.tag }}
      prerelease: ${{ steps.tag.outputs.prerelease }}
      summary: ${{ steps.notes.outputs.summary }}
    steps:
      # (the four steps, unchanged)
      - name: Keep the notes for publish
        uses: actions/upload-artifact@v7
        with:
          name: release-notes
          path: ${{ runner.temp }}/notes.md
          retention-days: 7
```

- [ ] **Step 2: `ios-release` job.** Rename `build-test-release` to `ios-release` (`name: iOS: build, test, archive and upload`), `needs: [ui-tests, prepare]`. Its first steps become Checkout (`ref: ${{ needs.prepare.outputs.tag }}`, `fetch-depth: 0`), then the existing steps from "Set up iOS project" on, with every `steps.tag.outputs.*` / `steps.notes.outputs.summary` replaced by `needs.prepare.outputs.*`. Remove its "Create GitHub Release" step.

- [ ] **Step 3: `tv-ui-tests` gate.** Add, beside `ui-tests`:

```yaml
  tv-ui-tests:
    name: tvOS UI tests
    uses: ./.github/workflows/tv-ui-tests.yml
    with:
      test-plan: TVUITests-Smoke
```

(check `tv-ui-tests.yml`'s required inputs and pass what it needs, as `pr-checks.yml` does).

- [ ] **Step 4: `tvos-release` job**:

```yaml
  tvos-release:
    name: tvOS: build, test, archive and upload
    needs: [tv-ui-tests, prepare]
    runs-on: macos-26
    timeout-minutes: 60
    steps:
      - name: Checkout
        uses: actions/checkout@v7
        with:
          ref: ${{ needs.prepare.outputs.tag }}
          fetch-depth: 0
      - name: Set up iOS project
        uses: ./.github/actions/setup-ios-project
      - name: Stamp version from the tag being built
        run: ./Scripts/update-version.sh
      - name: Build and test (tvOS)
        # The same command as pr-checks.yml's "tvOS build and unit tests" job.
        run: |
          set -o pipefail
          xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUnitTests \
            -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
            | xcbeautify --renderer github-actions
      - name: Check for signing credentials
        id: signing
        # (identical to ios-release's step)
      - name: Import signing certificate
        if: steps.signing.outputs.available == 'true'
        uses: apple-actions/import-codesign-certs@5142e029c445c10ffc7149d172e540235a065466 # v7
        with:
          p12-file-base64: ${{ secrets.APPSTORE_CERTIFICATES_FILE_BASE64 }}
          p12-password: ${{ secrets.APPSTORE_CERTIFICATES_PASSWORD }}
      - name: Download the app's provisioning profile
        if: steps.signing.outputs.available == 'true'
        uses: apple-actions/download-provisioning-profiles@2126b5f86a0e2863cbf4d2d312112b22b943a594 # v6
        with:
          bundle-id: com.imbenjamin.dionysusplayer
          profile-type: TVOS_APP_STORE
          issuer-id: ${{ vars.APPSTORE_ISSUER_ID }}
          api-key-id: ${{ vars.APPSTORE_API_KEY_ID }}
          api-private-key: ${{ secrets.APPSTORE_API_PRIVATE_KEY }}
      - name: Download the Top Shelf extension's provisioning profile
        if: steps.signing.outputs.available == 'true'
        uses: apple-actions/download-provisioning-profiles@2126b5f86a0e2863cbf4d2d312112b22b943a594 # v6
        with:
          bundle-id: com.imbenjamin.dionysusplayer.topshelf
          profile-type: TVOS_APP_STORE
          issuer-id: ${{ vars.APPSTORE_ISSUER_ID }}
          api-key-id: ${{ vars.APPSTORE_API_KEY_ID }}
          api-private-key: ${{ secrets.APPSTORE_API_PRIVATE_KEY }}
      - name: Archive and export
        if: steps.signing.outputs.available == 'true'
        id: export
        # Signed manually as the iOS job is (see its comment); the profiles are
        # named on each target's Release config and in ExportOptions-tvOS.plist.
        run: |
          set -o pipefail
          xcodebuild archive -project DionysusPlayer.xcodeproj -scheme DionysusTV -configuration Release \
            -destination 'generic/platform=tvOS' -archivePath .build/DionysusTV.xcarchive \
            | xcbeautify --renderer github-actions
          xcodebuild -exportArchive -archivePath .build/DionysusTV.xcarchive \
            -exportOptionsPlist Config/ExportOptions-tvOS.plist -exportPath .build/tv-export \
            | xcbeautify --renderer github-actions
          IPA=$(find .build/tv-export -name '*.ipa' -maxdepth 1 | head -1)
          if [ -z "$IPA" ]; then echo "::error::Export produced no .ipa in .build/tv-export." >&2; exit 1; fi
          echo "ipa=$IPA" >> "$GITHUB_OUTPUT"
      - name: Upload to App Store Connect
        if: steps.signing.outputs.available == 'true'
        uses: apple-actions/upload-testflight-build@1ad58030672057aa084b4e96beb6f7a8c627f9e6 # v5
        with:
          app-path: ${{ steps.export.outputs.ipa }}
          app-type: appletvos
          issuer-id: ${{ vars.APPSTORE_ISSUER_ID }}
          api-key-id: ${{ vars.APPSTORE_API_KEY_ID }}
          api-private-key: ${{ secrets.APPSTORE_API_PRIVATE_KEY }}
          release-notes: ${{ needs.prepare.outputs.summary }}
      - name: Upload build artifacts
        if: steps.signing.outputs.available == 'true'
        uses: actions/upload-artifact@v7
        with:
          name: ${{ needs.prepare.outputs.tag }}-tvos-build
          path: |
            .build/tv-export/*.ipa
            .build/DionysusTV.xcarchive/dSYMs
          retention-days: 30
          if-no-files-found: warn
```

Check the action's input name for the platform at its pinned commit (`app-type`, values `ios`/`appletvos`/`osx`) before relying on it. If the iOS job's tvOS runtime check is needed here (macos-26 image), copy pr-checks.yml's "List tvOS runtimes" step.

- [ ] **Step 5: `publish` job**:

```yaml
  publish:
    name: Publish the GitHub Release
    needs: [prepare, ios-release, tvos-release]
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/download-artifact@v7
        with:
          name: release-notes
          path: ${{ runner.temp }}
      - name: Create GitHub Release
        # (the existing step, with TAG / IS_PRERELEASE from needs.prepare.outputs,
        # and `--repo "$GITHUB_REPOSITORY"` added since there's no checkout)
```

Update the file's header comment: both platforms ship from one tag, the release is published only when both have, and an upload that went through can't be undone (re-run the failed job: `gh run rerun <id> --job <job id>`; the shared build number is counted per platform).

- [ ] **Step 6: PR gate.** In `pr-checks.yml`'s `release-build` job, add after the iOS step:

```yaml
      - name: Build Release for a generic tvOS device
        # The Apple TV app and its Top Shelf extension, Release, unsigned: a
        # Release-only break (the extension not embedded, a stray #if DEBUG)
        # fails here, not at the tag.
        run: |
          set -o pipefail
          xcodebuild build -project DionysusPlayer.xcodeproj -scheme DionysusTV -configuration Release \
            -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO \
            | xcbeautify --renderer github-actions
```

Its job name doesn't change, so no ruleset edit.

- [ ] **Step 7: Lint and review.** `actionlint .github/workflows/*.yml` if installed (else `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" .github/workflows/*.yml`). Read the diff end to end for every `steps.tag`/`steps.notes` reference left behind: `grep -n "steps.tag\|steps.notes" .github/workflows/release.yml` must only match inside `prepare`.

- [ ] **Step 8: Docs.** `VERSIONING.md`: the release flow section (jobs, the publish rule, re-running one platform). `TESTING.md` "Where they run in CI": release runs tvOS smoke; pr-checks' Release build covers tvOS. Root `CLAUDE.md` "Cutting a release": "builds and uploads both apps".

- [ ] **Step 9: Sign-off, commit, PR 5**, merge on green (the PR's own checks run the new Release build step).

### Task 15: The first tvOS release run

- [ ] **Step 1: Ask Benjamin** for the tag name (next free `vX.Y.Z-alpha.N` on `develop`, `git tag -l 'v*' --sort=-v:refname | head`) and its annotated message. Do not push a tag without his go-ahead.
- [ ] **Step 2: Tag and push** as he says: `git tag -a <tag> -m "<message>" origin/develop && git push origin <tag>`.
- [ ] **Step 3: Watch the run** (`gh run watch`). On a failure, read the log, fix on a branch, and re-run per `VERSIONING.md`; a fix to `release.yml` itself needs a new tag.
- [ ] **Step 4: Verify in App Store Connect** (API: `GET /v1/builds?filter[app]=<id>&filter[preReleaseVersion.platform]=TV_OS`): the tvOS build processed and in TestFlight. Ask Benjamin to install it from TestFlight on Bedroom and confirm launch, Now Playing and Top Shelf. Record in the ledger.

---

## PR 6: Store assets and listing

### Task 16: Apple TV screenshots

**Files:**
- Modify: `Scripts/store-screenshots/gen.py` (a TV layout), `Scripts/render-store-screenshots.sh` (the TV set)
- Create: `store-screenshots/appstore-appletv/` (rendered PNGs and raw captures, as the iOS sets keep them)
- Docs: root `CLAUDE.md` "Store screenshots", `README.md` "Store screenshots"

- [ ] **Step 1: Read the existing pipeline** (`gen.py`, `shot.swift`, the render script, README's section) and note how a set is declared (sizes, frames, captions).
- [ ] **Step 2: Add a TV layout to `gen.py`**: canvas 1920×1080; the brand gradient (`MAGENTA`/`AMBER` as defined); the headline top-left at the iOS sets' type scale, scaled for 1080p; the capture scaled to about 78% width, centred low, with rounded corners and the iOS sets' shadow; **no device frame**. One `TV_SLIDES` list of (capture file, headline, subline).
- [ ] **Step 3: Capture** on the tvOS 27 Simulator signed in to `demo.jellyfin.org/stable` as `demo` (no password), `xcrun simctl io 47399BA1 screenshot`: Home with the hero; a movie page; a show page with season tabs; the player with the swipe-down panel on Info; Search with results; Who's Watching? with two remembered accounts; the tvOS Home Screen with Dionysus in the top row showing its Top Shelf. Show Benjamin the raw captures before rendering.
- [ ] **Step 4: Draft the headlines** (show Benjamin before rendering): e.g. "Your Jellyfin library, on the big screen", "Every detail, at a glance", "Pick up where you left off" (Top Shelf), "Scrub like you mean it" (player), "Everyone gets their own profile". HDR/Dolby Vision only as a caption about capability.
- [ ] **Step 5: Render** with the script and review at 100% for clipped text and contrast. Commit captures and renders.
- [ ] **Step 6: Docs.** Root `CLAUDE.md` "Store screenshots": the Apple TV set, that `simctl io screenshot` works on tvOS (no rotation issues), and how the Top Shelf capture was made. README: the TV set in the workflow.

### Task 17: The tvOS listing

**Files:** `docs/store/tvos-listing.md` (create: the approved text, for the record)

- [ ] **Step 1: Read the iOS listing** from App Store Connect (API: the iOS version's `appStoreVersionLocalizations`: description, keywords, promotional text).
- [ ] **Step 2: Draft the tvOS text**: iOS's description with downloads and Picture in Picture replaced by Top Shelf, Apple TV profiles (Who's Watching?), Siri Remote scrubbing and scanning; keywords adjusted (`apple tv`, `top shelf` where they fit the 100-character limit); promotional text. Write it to `docs/store/tvos-listing.md` and show Benjamin.
- [ ] **Step 3: After his approval**, upload: the text through `PATCH /v1/appStoreVersionLocalizations/{id}` on the `TV_OS` version, and the screenshots through `appScreenshotSets` (`APP_APPLE_TV`) and `appScreenshots` (reserve, upload the parts, commit). Announce each call. Verify in the API that the set lists the screenshots in order.
- [ ] **Step 4: Sign-off, commit, PR 6** ("Apple TV store screenshots and listing"), merge.

---

## PR 7: Final pass and whole-milestone review

### Task 18: Close the milestone

- [ ] **Step 1: Device pass on Bedroom** (ask first), on the TestFlight build: launch, sign in, Top Shelf for two tvOS users, both link actions, Now Playing on native and software routes, Next Up, sign out (static image). Fix and re-check anything found.
- [ ] **Step 2: Whole-milestone review** with `superpowers:requesting-code-review` over `git diff 7e8e0a8..origin/develop` (the M5 end commit to now). Fixes in a follow-up PR, as M4's #317 and M5's #342.
- [ ] **Step 3: Closing docs.** Parent spec's milestone 6 line: "done: PRs #…"; `DionysusTV/CLAUDE.md` reflects everything shipped; the memory file `tvos-app-direction.md` says M6 done and what's next.
- [ ] **Step 4: Clean up** scratch artifacts per [[clean-up-scratch-artifacts]]; delete the spike branch after Benjamin agrees.
