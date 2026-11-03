# CI and test flake reduction: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `develop` PR goes green on its first attempt at least 90% of the time (66% today), and no flake is hidden behind a retry.

**Architecture:** The fixes are ordered by measured cost. First the infrastructure failures that no test-level retry can catch: a cold Simulator booting inside the test step, and the runner crashing in bootstrap. Then the specific flaky tests, each one traced to a root cause (shared mock state, timing windows, a fragile Duo selector, fixed sleeps). Last, making flakes visible and owned: a summary of retried tests on every job, a weekly flake report, and a written quarantine policy.

**Tech Stack:** GitHub Actions (`xcode-27-arm64` image, Xcode 27.1), composite actions under `.github/actions/`, xcodebuild/xcresulttool, XCTest/XCUITest, Python 3 (CI scripts, stdlib only).

**Spec:** this document's "Findings" section (the review of 2026-11-03). There is no separate spec.

## Findings (the review, 2026-11-03)

Data: every PR-checks, nightly and release run from 2026-10-12 to 2026-11-02, the logs of all 92 jobs that failed in any attempt, and 24 green smoke jobs for comparison (scripts and raw data were in the session's scratchpad; Task 6 checks in a reusable version).

| Workflow | Runs | Green first time | Needed a rerun |
| --- | --- | --- | --- |
| PR checks | 106 | 71 (66%) | 26 |
| Nightly UI tests | 29 | 15 (51%) | n/a |
| Release | 12 | 6 (50%) | 4 |

Failed jobs fall into five causes, largest first:

1. **The Simulator boots cold inside the test step (about 21 jobs, the biggest single cause).** `ui-tests.yml` runs `simctl shutdown all` and never boots the iPhone or iPad, so `xcodebuild test-without-building` boots it. Even on **green** runs, iOS 27.0 spends 413 to 617 s (iPhone) and 564 to 900 s (iPad) from `xcodebuild` starting to "Testing started"; the Duo, booted before its build, spends 182 to 325 s. When that wait runs long the runner crashes before any test runs: `Early unexpected exit, operation never finished bootstrapping - no restart will be attempted … -[XCTWaiter(StallHandling) handleStalledWait:]`. The plan's `retryOnFailure` can't help, since no test ever started. Related signatures: "Failed to get background assertion" (`HarnessTests.testStateResetClearsTheKeychainBetweenLaunches`, 3 jobs) and "Timed out while launching application" (5).
2. **Diagnostics collection costs 10 minutes per failure.** 18 failed jobs log `Failure collecting diagnostics from simulator: Timed out after 600.0 seconds`. Nobody reads the sysdiagnose it is waiting for; the `.xcresult` keeps the screenshots and recording.
3. **Specific flaky tests:**
   - `HarnessTests.testEmptyLibraryScenarioIsServed`: 8 jobs, **iPhone Duo only** (every pose), "Timed out after 15.0s waiting for the main tab bar". `TabBar.tab(_:index:)`'s Duo fallback (an unidentified `toolbars` button) finds nothing on the empty Home.
   - `HeroLogoFallbackUITests` (both tests): 6 jobs, mostly Duo closed and tabletop. `slowLogoImage` holds the logo a fixed time from the **first** request, which Home can make before the detail page mounts, a window bounded on both sides (`UITestStubURLProtocol.slowLogoImageDelay`'s doc comment says so).
   - The Profile and Spatial Audio journeys and audits on the Duo (about 30 failures, 2026-10-31 to 11-01) were fixed by #417; no failures since. Nothing to do but confirm in Task 3's verification run.
   - Unit: `DownloadManagerTests.test_retryableFailure_exhaustedBudget_failsWithAWrittenMessage` (3 jobs here, 5 in all), which waits with `waitForRetry()`, ten `Task.yield()`s; `ServerSetupViewModelTests.test_testConnection_ordinaryFailure_neitherWaitsNorRetries` (a 0.5 s bound, measured 0.627 s).
   - Unit, local and CI: the shared static `MockURLProtocol.requestHandler` receives requests from other tests and from **the host app itself**: `DionysusPlayerApp`'s `.task { await appState.start() }` runs in the unit-test host on `URLSession.shared`, where several tests register `MockURLProtocol` process-wide (open-issues memory: `AppStateTests`, `LoginViewModelTests`, `ServerSetupViewModelTests`, a host crash on 2026-10-23).
4. **tvOS stale accessibility tree** (about 5% of attempts; already mitigated by shards, 5 attempts and the warm-up). What's left is mostly in our hands: 19 fixed sleeps in UI tests, 17 of them in tvOS journeys (up to 12 s).
5. **One-offs:** pose setting (3, already retried once with a reboot), the 18.6 runtime import filling the disk (2, fixed), an SPM fetch (1).

**What the research says** (sources at the end): wait for a booted Simulator explicitly (`simctl bootstatus -b`) before testing; split build and test (already done); give every test an execution-time allowance so a hang fails one test instead of the job; retries are for gathering data, not hiding it (WWDC21 10296): report first-attempt failures even when the retry passes; quarantine only with an owner, an expiry and a cap, and keep quarantined tests running; reproduce with `-test-iterations N -run-tests-until-failure`; prefer state-based waits over sleeps.

## Global Constraints

- Every job builds with **Xcode 27.1** on `runs-on: xcode-27`; nothing moves to another image or Xcode.
- **Required check names don't change.** No job, device, pose or OS is renamed; if one must be, both rulesets (ids 20404081 `develop`, 20403514 `stable`) are updated in the same change.
- Every step that pipes `xcodebuild` into `xcbeautify` runs under `shell: bash` (pipefail).
- Third-party actions are pinned to a commit SHA.
- Keep `UITestCase`/`TVUITestCase` `setUp`/`tearDown` synchronous and no test method `async` (Apple issue 108565878).
- Select UI elements by `A11yID` identifier, never by label; a new identifier is added to `A11yID` in the same change that applies it.
- **Retries never hide a flake.** Any retry added here (step-level or test-level) emits a `::warning` naming what was retried.
- Each task: docs (`TESTING.md`) and tests in the same PR; sign-off from Benjamin before every commit; PRs into `develop` with `--merge`.
- Locally, use the iPhone 17 Simulator (the Duo only for Duo tasks); never a physical device. Don't run unit and UI suites at the same time.

## Review Focus

1. **A genuine regression that crashes the app at launch reads like an infrastructure failure** ("Early unexpected exit"). The step-level retry must run only once, and on a second failure fail the job with both attempts' logs. Task 2's tests pin "retries at most once".
2. **A test that starts failing every time must not be treated as flaky.** The flake summary separates "passed on retry" from "failed every attempt". Task 3's fixture test covers both.
3. **A Simulator that was already booted** (the Duo job boots and poses it before the build) must not be shut down or rebooted by the new boot step, or the pose is lost. Task 1's verification runs a Duo leg and checks the pose step's output still holds.
4. **Making the unit-test host app inert must not stop the tvOS launch checks** (`TVAppLaunchTests` relies on `DionysusTVApp.init`'s side effects). Task 4 keeps `init` as it is and skips only `start()`.
5. **Unmarked requests in the mock** (from `URLSession.shared` in `AppState`/`ServerSetupViewModel` tests) must still reach the handler of the test that opted in. Task 5's tests pin both the rejection and the opt-in.

---

## Phase 1: Infrastructure (largest share of reruns)

### Task 1: Boot the Simulator while the app builds

**Files:**
- Modify: `.github/actions/build-and-test/action.yml` (new steps between "Select simulator" and "Build", and between "Build" and "Warm up")
- Modify: `TESTING.md` ("Where they run in CI")

**Interfaces:**
- Produces: the Simulator `steps.select_simulator.outputs.udid` is in state `Booted` with `bootstatus` complete before any `test-without-building` runs. Later tasks rely on that.

- [ ] **Step 1: Record the baseline.** From the 24 green smoke jobs above: iPhone 27.0 bootstrap 413 to 617 s, iPad 564 to 900 s, Duo 182 to 325 s (the `IDETestOperationsObserverDebug: N elapsed -- Testing started completed` line).
- [ ] **Step 2: Add a "Start booting the simulator" step** right after "Select simulator": if `simctl list devices -j` reports the udid as `Shutdown`, run `xcrun simctl boot "$udid"` (it returns at once and boots in the background while the build compiles); if it's already `Booted` (the Duo job), do nothing. Never shut down a booted device here.
- [ ] **Step 3: Add a "Wait for the simulator" step** after "Build": `xcrun simctl bootstatus "$udid" -b` under a 15-minute `timeout-minutes`, printing the seconds it waited. On timeout: `::error::` naming the device and runtime, then exit 1.
- [ ] **Step 4: Verify.** Open a draft PR into `develop`; dispatch `nightly-ui-tests.yml` on the branch for the full matrix. Expected: iPhone and iPad 27.0 bootstrap under 300 s, Duo unchanged or lower, the pose steps still report their pose, every leg green or failing only on tests that failed before.
- [ ] **Step 5: Document** in TESTING.md, next to the warm-up paragraph: the device boots during the build and why (the bootstrap times above and the `handleStalledWait` crash).
- [ ] **Step 6: Commit** (after sign-off): "Boot the UI-test Simulator while the app builds".

### Task 2: Fail fast, and retry an infrastructure failure once

**Files:**
- Create: `Scripts/ci/xcodebuild_failure.py` (classifier, stdlib only)
- Create: `Scripts/ci/test_xcodebuild_failure.py` (`unittest`, with fixtures)
- Create: `Scripts/ci/fixtures/` (log excerpts copied from real failed jobs: one each of early-exit, background-assertion, launch-timeout, an ordinary assertion failure, a compile error)
- Modify: `.github/actions/build-and-test/action.yml` ("Test" step)
- Modify: `TestPlans/UITests-Smoke.xctestplan`, `UITests-Full.xctestplan`, `TVUITests-Smoke.xctestplan`, `TVUITests.xctestplan` (`defaultOptions`)
- Modify: `.github/workflows/pr-checks.yml` (new job `ci-scripts`)
- Modify: `TESTING.md`

**Interfaces:**
- Produces: `python3 Scripts/ci/xcodebuild_failure.py <log>` prints one of `infrastructure:<signature>` or `test` and exits 0; `classify(log_text: str) -> tuple[str, str | None]` returning `("infrastructure", signature)` or `("test", None)`.
- Signatures (exact substrings): `Early unexpected exit, operation never finished bootstrapping`, `Failed to get background assertion`, `Timed out while launching application`, `Test runner never began executing tests`, `The test runner crashed while preparing to run tests`.

- [ ] **Step 1: Write the failing tests** in `test_xcodebuild_failure.py`: `test_earlyExit_isInfrastructure`, `test_backgroundAssertion_isInfrastructure`, `test_launchTimeout_isInfrastructure`, `test_assertionFailure_isTest` (a log with `XCTAssertTrue failed` and no signature), `test_compileError_isTest`, `test_signatureAfterATestFailure_isStillTest` (a log where tests ran and failed and then the runner exited: a real failure must not be retried as infrastructure; the rule is "a signature and no `Test Case … failed` line").
- [ ] **Step 2: Run** `python3 -m unittest discover Scripts/ci`. Expected: fails (module missing).
- [ ] **Step 3: Implement `classify`.**
- [ ] **Step 4: Run** the tests again. Expected: 6 pass.
- [ ] **Step 5: Change the "Test" step:** add `-collect-test-diagnostics never`; `tee` xcodebuild's raw output to `.build/test-attempt-1.log`; on a non-zero exit, classify it. On `infrastructure:<sig>`: `::warning::Infrastructure failure (<sig>); rebooting the simulator and running the plan once more`, then `simctl shutdown` / `boot` / `bootstatus -b` and rerun once with `-resultBundlePath` suffixed `-attempt-2`. **For a Duo udid, re-run `Scripts/duo-pose/set-duo-pose.sh` after the reboot** (pass the pose in through a new optional input `duo-pose`). On `test`, or a second failure, exit with xcodebuild's status. Upload both bundles (the callers' upload steps take a glob).
- [ ] **Step 6: Per-test time allowance** in each UI plan's `defaultOptions`: `"testTimeoutsEnabled": true`, `"defaultTestExecutionTimeAllowance": 300`, `"maximumTestExecutionTimeAllowance": 600`. The longest passing UI test in the logs is under 3 min (check with Task 3's summary before merging, and raise the allowance if one is longer).
- [ ] **Step 7: Add the `ci-scripts` job** to `pr-checks.yml` on `ubuntu-latest`, 5-minute timeout, running `python3 -m unittest discover Scripts/ci`. Not a required check yet (adding one means editing the rulesets: ask Benjamin).
- [ ] **Step 8: Verify** on a draft PR: deliberately break the runner once (temporary commit: `xcrun simctl shutdown "$udid"` straight after "Wait for the simulator" makes `xcodebuild` boot it cold again, which doesn't reliably crash; if it doesn't, run the classifier against the real fixture instead and say so). Check that a normal failing test (temporary `XCTFail` in one smoke journey) fails the job **without** the step-level retry, and that the plan's own retry shows "Iteration 2".
- [ ] **Step 9: Document** in TESTING.md: the signatures that trigger a single rerun, why they're infrastructure, and that diagnostics collection is off and why (10 minutes per failure, nobody reads the sysdiagnose).
- [ ] **Step 10: Commit** (after sign-off): "Retry the UI-test plan once on runner bootstrap failures, and stop waiting on diagnostics".

### Task 3: Show every retried test on the job's summary

**Files:**
- Create: `Scripts/ci/xcresult_summary.py`
- Create: `Scripts/ci/test_xcresult_summary.py`, `Scripts/ci/fixtures/test-results-flaky.json`, `Scripts/ci/fixtures/test-results-failing.json`
- Modify: `.github/actions/build-and-test/action.yml` (new step "Summarize results", `if: always()`)
- Create: `Scripts/ci/flake-report.py` (the analysis behind this plan's Findings, reusable)

**Interfaces:**
- Consumes: the `.xcresult` bundle(s) from Task 2.
- Produces: `python3 Scripts/ci/xcresult_summary.py <results.json> [<results.json> …]` writes Markdown to stdout and one `::warning title=Flaky test::<Class>/<test> passed on attempt N of M` per retried test that passed in the end. `summarize(nodes: dict) -> Summary` with `Summary.flaky: list[TestOutcome]`, `Summary.failed: list[TestOutcome]`, `Summary.passed_count: int`; `TestOutcome(identifier: str, attempts: int, failure_messages: list[str])`.
- Produces: `flake-report.py --since YYYY-MM-DD [--workflow pr-checks.yml …]` printing a Markdown table of failed jobs by name, failing tests by count and failure signatures (Task 2's classifier), from `gh api` (it shells out to an authenticated `gh`).

- [ ] **Step 1: Capture the fixtures.** Locally, on the iPhone 17 Simulator, run one UI test with a temporary `XCTFail` that fires only on its first attempt, with `-retry-tests-on-failure -test-iterations 2`; then `xcrun xcresulttool get test-results tests --path <bundle> > fixtures/test-results-flaky.json`. Repeat with a test that always fails for `test-results-failing.json`. Trim both to the relevant nodes. Note the real node shape in the script's docstring (expected: a `Test Case` node whose children include `Repetition` nodes, each with its own `result`).
- [ ] **Step 2: Write the failing tests:** `test_retriedThenPassed_isFlaky` (attempts 2, one failure message), `test_failedEveryAttempt_isFailedNotFlaky`, `test_passedFirstTime_isNeither`, `test_markdown_listsFlakyThenFailed`.
- [ ] **Step 3: Run** `python3 -m unittest discover Scripts/ci`. Expected: the new tests fail.
- [ ] **Step 4: Implement** `summarize` and the Markdown/annotation output.
- [ ] **Step 5: Run** the tests. Expected: pass.
- [ ] **Step 6: Add the step**: for each bundle, `xcresulttool get test-results tests --path … > …json`, run the script, append to `$GITHUB_STEP_SUMMARY`. Also append the bootstrap time measured in Task 1 and whether Task 2's step-level retry fired.
- [ ] **Step 7: Verify** with the nightly dispatched on the branch: each job's summary lists its flaky tests; a green job with a retried test shows a yellow annotation on the run page. Also confirm here that #417 cleared the Duo Profile failures (none listed on any pose).
- [ ] **Step 8: Check in `flake-report.py`**, run it with `--since 2026-10-12`, and check its counts match the Findings table (106 PR runs, 26 needing a rerun).
- [ ] **Step 9: Commit** (after sign-off): "Summarize retried and failed tests on every test job".

## Phase 2: Unit tests

### Task 4: Keep the unit-test host app off the network

**Files:**
- Create: `DionysusPlayer/Core/Support/TestHostDetection.swift` (compiled into iOS and tvOS: add to the `DionysusTV` target's `includes` in `project.yml`)
- Modify: `DionysusPlayer/App/DionysusPlayerApp.swift` (the `.task` that calls `appState.start()`, and the scene-phase probe)
- Modify: the tvOS app's equivalent `start()` call site in `DionysusTV/` (find it with `grep -rn "appState.start()" DionysusTV`)
- Test: `DionysusPlayerTests/Core/Support/TestHostDetectionTests.swift` (shared with tvOS via `includes`)
- Modify: `TESTING.md` ("How network calls are faked")

**Interfaces:**
- Produces: `enum TestHostDetection { static func isUnitTestHost(environment: [String: String]) -> Bool; static var isUnitTestHost: Bool }`. True when `XCTestConfigurationFilePath` is set (the app is hosting an `.xctest` bundle). UI tests launch the app as a separate process without it, so they are unaffected.

- [ ] **Step 1: Write the failing tests:** `test_withXCTestConfigurationPath_isUnitTestHost` (env `["XCTestConfigurationFilePath": "/x.xctestconfiguration"]` → true), `test_withoutIt_isNotUnitTestHost` (`[:]` → false), `test_uiTestModeAlone_isNotUnitTestHost` (`["UITestMode": "YES"]` → false), `test_thisProcess_isAUnitTestHost` (`TestHostDetection.isUnitTestHost == true`).
- [ ] **Step 2: Run** `xcodebuild test … -only-testing:DionysusPlayerTests/TestHostDetectionTests`. Expected: compile failure.
- [ ] **Step 3: Implement**, and guard both apps' `start()` call (and the foreground reachability probe) with `guard !TestHostDetection.isUnitTestHost`. Leave `init()` unchanged so `TVAppLaunchTests` still sees what launch sets up.
- [ ] **Step 4: Run** the full `UnitTests` and `TVUnitTests` plans. Expected: all pass.
- [ ] **Step 5: Verify the original failure is gone:** run `UITests-Smoke` on the iPhone 17 Simulator, then straight after (no keychain reset) `UnitTests` three times. Expected: 3/3 green (before: the open-issues memory records repeated failures in this order).
- [ ] **Step 6:** `xcodegen generate`, update TESTING.md (the host app no longer starts a session under unit tests, and why), **commit** after sign-off: "Keep the unit-test host app from starting a session".

### Task 5: Stop one test's requests reaching another's mock

**Files:**
- Modify: `DionysusPlayerTests/Support/MockURLProtocol.swift`
- Test: `DionysusPlayerTests/Support/MockURLProtocolTests.swift` (create; add to the tvOS `includes`)
- Modify: the tests that register `MockURLProtocol` process-wide (`grep -rln "registerClass(MockURLProtocol" DionysusPlayerTests DionysusTVTests`, 8 files): set `MockURLProtocol.acceptsUnmarkedRequests = true` in their `setUp`

**Interfaces:**
- Produces: `static var generation: Int` (bumped by `reset()`); `makeSession()` stamps each request with header `X-MockURLProtocol-Generation: <generation at creation>`; `nonisolated(unsafe) static var acceptsUnmarkedRequests: Bool` (default false, reset by `reset()`); `struct StaleRequest: Error`. A request whose header names an older generation, or that has no header while `acceptsUnmarkedRequests` is false, fails with `StaleRequest` and is **not** recorded in `lastRequest` and never reaches `requestHandler`.

- [ ] **Step 1: Write the failing tests:** `test_aSessionFromBeforeReset_neverReachesTheCurrentHandler` (make a session, `reset()`, set a handler that `XCTFail`s, send on the old session, expect `StaleRequest` and `lastRequest == nil`); `test_anUnmarkedRequest_isRefusedByDefault` (a session configured with `protocolClasses = [MockURLProtocol.self]` but without the header); `test_anUnmarkedRequest_reachesTheHandlerWhenAccepted`; `test_aCurrentSession_reachesTheHandler`.
- [ ] **Step 2: Run** them. Expected: fail.
- [ ] **Step 3: Implement.** Session-stamping via `URLSessionConfiguration.httpAdditionalHeaders`.
- [ ] **Step 4: Run** the full `UnitTests` and `TVUnitTests`. Expected: all pass; a test that now fails with `StaleRequest` was depending on a leak: fix the test, never the assertion.
- [ ] **Step 5: Shake out order dependence:** run each plan with `-test-iterations 3 -run-tests-until-failure` once. Expected: green.
- [ ] **Step 6: Update** TESTING.md's "How network calls are faked" (generations, opting in for `URLSession.shared`), and remove the "Shared `MockURLProtocol.requestHandler` leaks" entry from the open-issues memory once merged. **Commit** after sign-off: "Isolate MockURLProtocol per test".

### Task 6: Replace timing guesses in unit tests with state waits

**Files:**
- Modify: `DionysusPlayerTests/Support/AsyncTestHelpers.swift` (`waitUntil` default timeout 2 → 5 s: a passing condition returns as soon as it holds, so only failures wait longer, and 2 s was tight on a loaded runner)
- Modify: `DionysusPlayerTests/Core/Downloads/DownloadManagerTests.swift` (`waitForRetry()` and its callers)
- Modify: `DionysusPlayerTests/Features/ServerSetup/ServerSetupViewModelTests.swift` (the 0.5 s bound near the `ContinuousClock` at line ~533)
- Audit and modify as needed (36 `Task.sleep`/`Thread.sleep`/`usleep` in unit tests): `DionysusTVTests/TVScrubThumbnailLoaderTests.swift` (8), `TVPlaybackSessionTests.swift` (6), `TVPlayerCommandRunnerTests.swift` (4), `DionysusPlayerTests/Shared/Components/ToastCenterTests.swift` (4), `PlayerViewModelTests.swift` (3), and the single uses listed by `grep -rln -E "Task\.sleep|Thread\.sleep|usleep" DionysusPlayerTests DionysusTVTests`
- Modify: `TESTING.md` ("Adding a unit test": a rule about sleeps)

**Interfaces:**
- Consumes: `waitUntil(timeout:_:)` (existing).

- [ ] **Step 1: Reproduce the DownloadManager flake:** `xcodebuild test -only-testing:DionysusPlayerTests/DownloadManagerTests/test_retryableFailure_exhaustedBudget_failsWithAWrittenMessage -test-iterations 200 -run-tests-until-failure` on the iPhone 17 Simulator. Record whether and when it fails (CI showed `.downloading` instead of `.failed`).
- [ ] **Step 2: Replace** each `await waitForRetry()` with `try await waitUntil { store.item(itemID: "item-1")?.status == <the state the next step needs> }` and delete `waitForRetry()`.
- [ ] **Step 3: Run** step 1's command again. Expected: 200/200.
- [ ] **Step 4: ServerSetupViewModel bound:** the test is asserting "neither waits nor retries". Assert that on the request count and on the absence of the retry delay (inject the delay, or bound it at 2 s with a comment that the retry it guards against waits ≥ 5 s); check the injected value in `ServerSetupViewModel` before choosing.
- [ ] **Step 5: Audit each remaining sleep:** keep a sleep only when it *is* the behaviour under test and the test injects a short duration; otherwise wait on state. For `TVPlayerCommandRunnerTests.test_audioOffsetCommands_reachTheController` (once saw 40 where 20 was expected) run it with `-test-iterations 300 -run-tests-until-failure` first and fix what that shows.
- [ ] **Step 6: Run** `UnitTests` and `TVUnitTests` with `-test-iterations 3 -run-tests-until-failure`. Expected: green.
- [ ] **Step 7: Docs, then commit** after sign-off: "Wait on state, not time, in unit tests".

### Task 7: A nightly flake hunt for unit tests

**Files:**
- Modify: `.github/workflows/nightly-ui-tests.yml` (new job `unit-flake-hunt`)

- [ ] **Step 1: Add the job:** on `xcode-27`, `UnitTests` on iPhone 16 / iOS 27.0 and `TVUnitTests` on Apple TV 4K / tvOS 27.0, each with `-test-iterations 5 -run-tests-until-failure` and random order (`-test-execution-ordering random` if `xcodebuild -help` on 27.1 lists it; otherwise a copy of each plan with `"testExecutionOrdering": "random"` used only here). `continue-on-error: true`, so it reports without turning the nightly red. Task 3's summary step reports what failed.
- [ ] **Step 2: Verify** by dispatching the nightly on the branch: the job runs in under 45 min and its summary lists any failure.
- [ ] **Step 3: Commit** after sign-off: "Hunt for order-dependent and flaky unit tests nightly". When it has been green for 14 nights in a row, propose random order for the PR plans too.

## Phase 3: UI tests

### Task 8: Fix the Duo's empty-library failure

**Files:**
- Modify: `DionysusPlayerUITests/Journeys/HarnessTests.swift` (`testEmptyLibraryScenarioIsServed`)
- Modify: `DionysusPlayerUITests/Screens/` (`TabBar`, file found with `grep -rln "struct TabBar"`), only if step 1 shows the fallback is wrong
- Possibly modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` and Home's empty-state view

- [ ] **Step 1: Read the real tree.** Boot the iPhone Duo Simulator closed (Scripts/duo-pose), run the test alone with a temporary `print(app.debugDescription)` after launch. Find where Home's tab button is: it may not be under `app.toolbars`, or the empty Home may add another unidentified toolbar button ahead of it.
- [ ] **Step 2: Fix the cause** step 1 finds. If the Home tab can't be found reliably on the Duo, the test's own intent is "signed in, past the splash, no items": give Home's empty state an identifier `A11yID.Home.emptyState = "home.emptyState"` (if it has none) and assert on that instead of the tab bar.
- [ ] **Step 3: Check it fails** with the stub's `emptyLibrary` scenario broken (serve items): the test must go red.
- [ ] **Step 4: Run** the test with `-test-iterations 20` in closed and open poses locally. Expected: 20/20 each. Then iPhone 17 once.
- [ ] **Step 5: Commit** after sign-off: "Find the empty Home reliably on the iPhone Duo".

### Task 9: Make the slow-logo journeys independent of timing

**Files:**
- Modify: `DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift` (`slowLogoImage` handling around line 66, `slowLogoImageDelay` around line 1225)
- Modify: `DionysusPlayer/Core/Networking/RemoteImageLoader.swift` only through `UITestHarness` (no change to production behaviour)
- Modify: `DionysusPlayerUITests/Journeys/HeroLogoFallbackUITests.swift`

**Interfaces:**
- Produces: under `slowLogoImage`, each `Logo` request is held for `slowLogoImageDelay` measured from **that request**, and the loader's cache is bypassed for logo URLs in that scenario, so the view being watched always makes its own request and starts its own clock.

- [ ] **Step 1: Confirm the cause** from one failed Duo xcresult (`gh run download` from the 2026-11-02 PR run's Duo closed leg): check in the recording whether Home showed a logo before the detail page opened (the shared-clock case).
- [ ] **Step 2: Implement** the per-request hold (it may already be per request; then the fix is only the cache bypass) and the cache bypass under the harness.
- [ ] **Step 3: Update `slowLogoImageDelay`'s doc comment**: the window is now bounded on one side only.
- [ ] **Step 4: Run** both tests with `-test-iterations 20` on the Duo closed and tabletop, and on iPhone 17. Expected: 20/20.
- [ ] **Step 5: Commit** after sign-off: "Hold each slow logo from its own request".

### Task 10: Replace fixed sleeps in the journeys

**Files:**
- Modify: `DionysusTVUITests/LoadingJourneyTests.swift`, `PlayerJourneyTests.swift`, `CollectionDetailJourneyTests.swift`, `CollectionGridJourneyTests.swift`, `PlayerAccessibleTransportJourneyTests.swift`, `PlayerSegmentJourneyTests.swift`, `PlayerScrubJourneyTests.swift`, `ProfileJourneyTests.swift`, `OnboardingJourneyTests.swift`
- Modify: `DionysusPlayerUITests/Journeys/AddToPlaylistJourneyTests.swift:418`
- Modify: `DionysusTVUITests/Support/TVUITestCase.swift` (a helper if two or more journeys need the same wait)
- Modify: `TESTING.md` ("Writing a journey": a rule on sleeps)

- [ ] **Step 1: Classify each of the 19 sleeps:** (a) waiting for something to appear or change → replace with `awaitExistence`/an `XCTNSPredicateExpectation`; (b) proving something does *not* happen within a time (a fade that shouldn't occur, a countdown that hasn't finished) → keep, but name the duration as a constant with a comment saying what it proves; (c) letting the app clock run (the 12 s in `PlayerSegmentJourneyTests`) → wait on the element the clock produces, with that duration plus margin as the timeout. `UITestCase.awaitStableFrame`'s 0.25 s poll and `OnboardingJourneyTests`' poll loop are polls, not guesses: leave them.
- [ ] **Step 2: Convert** the (a) and (c) cases, one file at a time.
- [ ] **Step 3: For each converted class,** run it with `-test-iterations 10` on the tvOS 27 Simulator (and iPhone 17 for AddToPlaylist), after a local warm-up as TESTING.md says. Expected: 10/10, and the class's runtime no longer than before.
- [ ] **Step 4: Check one converted wait fails** when the thing it waits for is broken.
- [ ] **Step 5: Docs, then commit** after sign-off: "Wait on state, not time, in the journeys".

## Phase 4: Workflow hygiene and policy

### Task 11: Cache package checkouts and skip redundant installs

**Files:**
- Modify: `.github/actions/setup-ios-project/action.yml`
- Modify: `.github/actions/build-and-test/action.yml` and `pr-checks.yml`'s direct `xcodebuild` calls (`-clonedSourcePackagesDirPath .build/SourcePackages`)

- [ ] **Step 1: Cache** `.build/SourcePackages` with `actions/cache` (SHA-pinned), key `spm-${{ runner.os }}-xcode-27.1-${{ hashFiles('Packages/**/Package.swift', 'project.yml') }}` and **no restore-keys**: a partial match would read an older checkout, which is the "enables traits on package … that declares no traits" failure CLAUDE.md warns about. The pin is `exact:`, so the key moving with `Package.swift` is the whole of the invalidation.
- [ ] **Step 2: Install only what's missing:** skip `brew install xcbeautify xcodegen` for any tool already on `PATH` at the version the image ships; print both versions.
- [ ] **Step 3: Verify** on a draft PR: a second push restores the cache, "Resolve Package Graph" drops from minutes to seconds, and the AetherEngine version printed is still the pinned one (7.54.0 today).
- [ ] **Step 4: Update** CLAUDE.md's "Pinning AetherEngine" sentence that says every CI run resolves cold (the pin rule still holds; the cache is keyed on it). **Commit** after sign-off: "Cache Swift package checkouts in CI".

### Task 12: A written flake policy and a weekly report

**Files:**
- Modify: `TESTING.md` (new section "Flaky tests", before "Checked by hand")
- Create: `.github/workflows/flake-report.yml`

- [ ] **Step 1: Write the policy** in TESTING.md, short:
  - **What counts:** a test that fails and then passes with no code change. A test failing every attempt is broken, not flaky.
  - **First response:** read the job's summary (Task 3), then `--log-failed` for an infrastructure signature (Task 2's list) before suspecting the change. Rerun with `gh run rerun <id> --failed`, never the whole run.
  - **Reproduce** with `-test-iterations 50 -run-tests-until-failure` on one test before changing it.
  - **Quarantine** (from the PR gate only): add the test to the smoke plan's `skippedTests`, plus a row in a "Quarantined" table here (test, date, signature, issue). It keeps running nightly and in the full plan. At most **3** at once, each for at most **14 days**; it comes out with a root-cause fix, not after a quiet streak (a 1% flake passes 20 runs in a row 82% of the time).
  - **Never** add a sleep or lengthen a timeout without a measured reason in a comment.
- [ ] **Step 2: Add `flake-report.yml`:** weekly (`cron: "0 6 * * 1"`) and `workflow_dispatch`, on `ubuntu-latest`, `permissions: actions: read`, runs `Scripts/ci/flake-report.py --since <7 days ago>` and writes it to the step summary. Nothing is posted outside the run page.
- [ ] **Step 3: Verify** by dispatching it on the branch: the summary shows the last seven days' table.
- [ ] **Step 4: Commit** after sign-off: "Write down the flake policy and report flakes weekly".

## Order, measurement and done

- Ship Tasks 1 to 3 first, as one PR each; they target about half the reruns. Then 4 to 7 (unit), 8 to 10 (UI), 11 and 12.
- After each PR merges, run `Scripts/ci/flake-report.py --since <merge date>` once the next ~15 PR runs are in. **Done** when, over two consecutive weeks, PR checks pass first time in ≥ 90% of runs and the nightly in ≥ 80%, with every retried test visible on its job summary.

## Considered and not planned

- **Parallel UI testing** (`-parallel-testing-enabled YES`): clones the Simulator per worker; on a shared 3-core runner that adds the load that causes these failures, and the Duo's pose is per device. Revisit for unit tests only if their job grows past 15 minutes (11 to 14 today).
- **A self-hosted runner on the Mac mini** (the open-issues memory's unapproved fallback for tvOS): the repository runs PR code, and the Mac mini also holds the Jellyfin server and signing material. Not without a separate security decision.
- **More retries** (raising iOS `maximumTestRepetitions` past 2): it would hide the same flakes the plan wants visible. Task 2 retries only the cases a test retry can't reach.
- **Fewer required checks:** cuts reruns by removing coverage. Revisit only if Phase 1 doesn't move the numbers.

## Sources

- Apple, WWDC21 "Diagnose unreliable code with test repetitions": https://developer.apple.com/videos/play/wwdc2021/10296/
- Apple, WWDC20 "Get your test results faster" (execution time allowance): https://developer.apple.com/videos/play/wwdc2020/10221/
- actions/runner-images issue on UI tests failing on hosted runners after boot: https://www.github.com/actions/runner-images/issues/9591
- fastlane issue #6968 ("Early unexpected exit … never finished bootstrapping"): https://github.com/fastlane/fastlane/issues/6968
- Apple Developer Forums, Xcode Cloud bootstrap errors: https://developer.apple.com/forums/thread/729449
- `-collect-test-diagnostics` precedence over the test plan: https://developer.apple.com/forums/thread/698054
- Quarantine policy (owner, expiry, cap; report first-attempt failures): https://oneuptime.com/blog/post/2026-07-28-quarantine-flaky-tests/view and https://testdino.com/blog/flaky-test-github-actions
- xcodebuild flags verified against `xcodebuild -help` on Xcode 27.1 (2026-11-03).
