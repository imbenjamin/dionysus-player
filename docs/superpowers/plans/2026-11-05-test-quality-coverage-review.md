# Test quality and coverage review: plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A ranked report of where the unit and UI tests are weaker than they look, on every device type, from which Benjamin picks what to fix.

**Architecture:** Measure first, then read. Nine local test runs with code coverage on (unit and UI, iOS and tvOS, iPhone, iPad and the Duo in each pose) give, for each line of app code, which runs reach it. A static scan and a hand reading of the tests then judge whether what runs is actually checked. The journeys are mapped against the screens and flows, the smoke plans against recent fixes, and the flake follow-ups are rechecked. Every gap becomes one ranked finding in a single report. **No product, test or CI code changes**: the deliverable is the report.

**Tech Stack:** xcodebuild with `-enableCodeCoverage YES`, `xcrun xccov`, `xcrun xcresulttool`, Python 3 (stdlib only, scripts kept in the scratchpad), `gh`, git.

**Spec:** this section and "Scope" below, agreed with Benjamin on 2026-11-05 in conversation. There is no separate design document.

## Scope (agreed 2026-11-05)

- **Why:** a health check. No incident prompted it; Benjamin wants to know where the tests are weaker than they look before something gets through.
- **Deliverable:** a report first, no fixes. It ranks the gaps; Benjamin picks which to fix, and each fix he picks becomes its own plan and PR later.
- **Devices:** iPhone, iPad, iPhone Duo (closed, open, book, tabletop), Apple TV, the Top Shelf extension, and the iOS 18.6 and tvOS 26 floors.
- **What it covers:**
  1. Measured coverage per target, and the code no test reaches, with playback, networking and the shared view models looked at first.
  2. Journey gaps: screens and flows with no UI journey, the Apple TV screens and the Duo fold layouts included (CLAUDE.md: a change to a view needs a journey).
  3. Test quality: tests that assert nothing, tests that only check a mock, near-duplicates, and checks that something exists where a value should be compared.
  4. The smoke plans: do `UITests-Smoke` and `TVUITests-Smoke` still cover the riskiest paths, given the full plans run only nightly?
  5. Flake follow-ups left from the 2026-11-03 work (listed in Task 6) and the Playback settings audit's `swipeUp`.
- **Each finding says** how likely the gap is to hide a real bug and roughly what fixing it costs (the rubric in Task 0).

## Global Constraints

- **Change no product code, test code, test plan or CI workflow.** The only files added to the repo are the report and this plan.
- The report goes to `docs/superpowers/specs/2026-11-05-test-quality-coverage-review.md` (beside `2026-10-22-tvos-app-store-review.md`, the earlier review).
- Analysis scripts, result bundles and data files live in the session's scratchpad (written `$SCRATCH` below), never in the repo. Run any Python with `python3 -I`.
- Simulators (local Xcode 27.2): **iPhone 17** (iOS 27.2), **iPad (A16)** (iOS 27.2), **iPhone Duo** (iOS 27.2), **Apple TV 4K (4th generation)** (tvOS 27.2). Boot existing Simulators only; creating one needs asking. **Never touch a physical device.**
- **Never run a unit suite and a UI suite at the same time.** Runs go one after another.
- After the UI runs, before handing back, sign each Simulator used back in to SavareseHillFlix as Ben (the UI tests leave the stub server's session behind).
- Coverage here is from Xcode 27.2; CI builds with 27.1. Say so in the report's method section; don't try to reproduce CI.
- One commit at the end, after Benjamin has read the report and signed it off; branch `docs/test-quality-coverage-review` off `develop`, PR into `develop`, merged with `--merge`. No Claude session URL in the commit or PR.
- When a task finishes, purge its scratch (result bundles are large) once its numbers are in the report; move to Trash, `rm` is blocked.

## Review Focus

The ways this analysis could mislead, most likely first. Each is guarded in the task named.

1. **The UI-test harness inflates UI coverage.** The stub server, `PreviewPlaybackEngine` and the other `#if DEBUG` harness code run in the app under UI tests and would count as "covered". Task 1 excludes them by path and reports the excluded line count.
2. **A SwiftUI view body reads as a unit-test gap.** Views are reached by UI tests, not unit tests. Task 1 tags each file as view or logic, and Task 2 judges views only against the union with UI coverage.
3. **Executed is not verified.** A line can run in a test that asserts nothing about it. Task 7 cross-checks every high-coverage file named in a Task 3 quality finding, and the report says "reached" (never "tested") for coverage numbers.
4. **Pose-only or platform-only code reported as untested when it was only unmeasured on one device.** Task 2 calls a line untested only when no run reaches it, and gives per-device numbers separately. Code that no local run can reach (the iOS 18.6 and tvOS 26 pre-branches) is listed as "not measured", not "untested".
5. **Shared code counted twice.** `Core/` and the shared view models compile into both apps. Task 2 joins runs by source path, so a shared file has one row with an iOS and a tvOS column.

---

## Task 0: Branch, report skeleton and rubric

**Files:**
- Create: `docs/superpowers/specs/2026-11-05-test-quality-coverage-review.md`

**Interfaces:**
- Produces: the report's section headings (below) and the finding format, which every later task fills.

- [ ] **Step 1:** `git switch develop && git pull && git switch -c docs/test-quality-coverage-review`. Leave the untracked `docs/superpowers/plans/2026-10-30-iphone-duo-store-listing.md` alone.
- [ ] **Step 2: Write the skeleton** with these sections, each holding a one-line "to fill (Task N)" placeholder:
  1. Summary: the ten highest-ranked findings (Task 7)
  2. How it was measured (Tasks 1, 2)
  3. Coverage by target and area (Task 1)
  4. Code no test reaches (Task 2)
  5. Devices, poses and floors (Task 2)
  6. Journey and audit gaps (Task 4)
  7. Test quality (Task 3)
  8. The smoke plans (Task 5)
  9. Flake follow-ups (Task 6)
  10. All findings (Task 7)
- [ ] **Step 3: Write the rubric and finding format** into "How it was measured":
  - **Finding:** `TQ-NN` · title · area · devices · evidence (file:line, numbers, run ids) · risk · cost · suggested fix (one or two sentences, no code).
  - **Risk:** **High**: a regression here would reach users with no test failing, *and* the code is on playback, sign-in/session, downloads or navigation, or changed in the last 60 days (`git log --since=2026-09-06`). **Medium**: either one of those. **Low**: neither, or the risk is cosmetic.
  - **Cost:** **S**: under half a day, tests in one file, no harness change. **M**: a new journey, or tests across several files. **L**: needs a new harness capability (a stub-server scenario, a fake-engine behaviour, a new launch argument) or CI changes.
- [ ] **Step 4: Check:** the file renders as Markdown with ten numbered `##` sections. Don't commit.

## Task 1: Measured coverage (nine runs)

**Files:**
- Modify: the report's sections 2 and 3
- Scratch: `$SCRATCH/cov/<run>.xcresult`, `$SCRATCH/cov/<run>.json`, `$SCRATCH/cov/runs.md` (durations and failures)

**Interfaces:**
- Produces: for each run, `$SCRATCH/cov/<run>.xcresult` and a per-file JSON from `xcrun xccov view --report --json`; run names `ios-unit`, `tv-unit`, `ios-ui-iphone`, `ios-ui-ipad`, `ios-ui-duo-closed`, `ios-ui-duo-open`, `ios-ui-duo-book`, `ios-ui-duo-tabletop`, `tv-ui`. Task 2 reads the `.xcresult` bundles.

- [ ] **Step 1: Regenerate the project:** `xcodegen generate`. Expected: "Created project at …".
- [ ] **Step 2: Unit runs, one after the other**, each with `-enableCodeCoverage YES -resultBundlePath $SCRATCH/cov/<run>.xcresult`:
  - `ios-unit`: `-scheme DionysusPlayer -testPlan UnitTests -destination 'platform=iOS Simulator,name=iPhone 17'`
  - `tv-unit`: `-scheme DionysusTV -testPlan TVUnitTests -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)'`
  Expected: `** TEST SUCCEEDED **` or a list of failures. A failing test doesn't stop the review: record it in `runs.md` with its message (it may itself be a finding). Record each run's wall time.
- [ ] **Step 3: Confirm coverage was collected:** `xcrun xccov view --report --only-targets $SCRATCH/cov/ios-unit.xcresult`. Expected: rows for `DionysusPlayer.app` with a non-zero percentage (and, for `tv-unit`, `DionysusTV.app` and, if the tests load it, `DionysusTVTopShelf.appex`). If the Top Shelf extension has no row, note in `runs.md` that its code is measured only through the files `DionysusTVTests` compiles directly, and find out which (`project.yml`).
- [ ] **Step 4: UI runs, one after the other**, same flags, `-testPlan UITests-Full` (iOS) or `TVUITests` (tvOS):
  - `ios-ui-iphone`: iPhone 17. `ios-ui-ipad`: `name=iPad (A16),OS=27.2`.
  - The four Duo runs: `name=iPhone Duo`. Before each, set the pose with `Scripts/duo-pose/set-duo-pose.sh 12AC1AA8-6CFA-4524-A05A-F56B387B013A <closed|open|book|tabletop>` (TESTING.md, "Where they run in CI": needs Accessibility access for the terminal, the Duo selected in Device Hub, the Mac awake under `caffeinate -d`), and pass `TEST_RUNNER_DUO_POSE=<pose>` to xcodebuild. Check the pose script's output says the pose took before running.
  - `tv-ui`: Apple TV 4K (4th generation), the whole `TVUITests` plan unsharded.
  Before the first, look up the full plan's duration per device on the last green nightly (`gh run list --workflow nightly-ui-tests.yml --branch develop --status success -L 1`, then `gh run view <id>`) and write the expected total in `runs.md`. **If the expected total is over six hours, stop and ask Benjamin which runs to drop** before starting.
- [ ] **Step 5: Export per-file reports:** `xcrun xccov view --report --json <run>.xcresult > <run>.json` for all nine.
- [ ] **Step 6: Tag every app source file** (`DionysusPlayer/`, `DionysusTV/`, `DionysusTVTopShelf/`) with:
  - **kind**: `view` (declares a `View`, `UIViewController` or `UIView` type and no other type of substance) or `logic`.
  - **harness**: true if the whole file is inside `#if DEBUG` or exists only for UI tests or previews (`PreviewPlaybackEngine`, the stub server and the other harness files `TESTING.md` "The launch-argument harness" and "The stub server" name). Harness files are excluded from every percentage; report their line count once.
  - **area**: the first two path components below the target (`Core/Playback`, `Features/Player`, `DionysusTV/Browse`…).
  Write the tagging script as `$SCRATCH/scripts/tag_sources.py`; output `$SCRATCH/cov/sources.csv` with `path,target,kind,harness,area,lines`.
- [ ] **Step 7: Fill section 2** (the runs, their commands, durations, failures, the exclusions, the 27.2-vs-27.1 caveat) **and section 3**: one table per target of line coverage per area, unit and UI separately, logic and view separately. Name the playback, networking and shared view model numbers first.
- [ ] **Step 8: Check:** every number in section 3 can be traced to a row of a `<run>.json`; harness files appear in no percentage.

## Task 2: Code no test reaches, by device

**Files:**
- Modify: the report's sections 4 and 5
- Scratch: `$SCRATCH/scripts/cov_union.py`, `$SCRATCH/cov/union.csv`, `$SCRATCH/cov/hotspots.csv`

**Interfaces:**
- Consumes: the nine `.xcresult` bundles and `sources.csv` from Task 1.
- Produces: `union.csv` (`path,kind,area,executable,reached_by_<run>…,reached_any`) and `hotspots.csv`, read by Tasks 3 and 7.

- [ ] **Step 1: Build the line-level union.** `cov_union.py` reads each bundle's line data (`xcrun xccov view --archive --json <run>.xcresult`, or per file with `--file` if the whole archive is too large), joins by source path, and for each file counts executable lines reached by each run and by any run. Harness files are left out.
- [ ] **Step 2: Check the union** against Task 1: for each run, the union's reached-line total for that run's targets is within 1% of `xccov`'s own line count. If not, fix the script before going on.
- [ ] **Step 3: Hotspots:** join `union.csv` with churn since 2026-09-06 (`git log --since=2026-09-06 --format= --numstat -- DionysusPlayer DionysusTV DionysusTVTopShelf`, lines added plus deleted per file). `hotspots.csv` lists logic files with at least 20 unreached lines, sorted by unreached lines × churn.
- [ ] **Step 4: Read the top 25 hotspots** and, for each, the unreached functions (`xcrun xccov view --report --functions-for-file <name> <bundle>`). Say in one line what the unreached code does and whether a unit test or a journey would reach it more cheaply.
- [ ] **Step 5: Device and pose code.** For each of these, report which runs reach it and which branches no run reaches:
  - The six Duo fold layouts in CLAUDE.md ("iPhone Duo: the fold": `PlayerFoldLayout`, `DetailBookSpread`, `.centredClearOfTheFold()`, `HeroFoldLayout`, `OnboardingFoldSplit`, `FoldGapHStack`/`PosterGridMetrics(…, foldGap:)`), `ActiveFold`, `RotationLock`, `OnboardingLayout.resolve`, `SettingsLayout.usesSplitLayout`, and `tabBarPlacement` checks.
  - iPad-only paths (split layouts, `.topBar` placement).
  - `#if os(tvOS)` / `#if os(iOS)` and `#if DOWNLOADS` blocks in shared code.
  - **The floors:** list every `#available`/`#unavailable` check in the three targets (26 sites in 13 files on 2026-11-05) and, for each, whether its fallback branch has any test. No local run covers iOS 18.6 or tvOS 26; CI's 18.6 runs are the full UI plan only, and the tvOS 26.5 floor job is an allowed failure that fails on `develop` too. Mark these "not measured" and say what would measure them.
  - **Top Shelf:** what `DionysusTVTests` reaches of `DionysusTV/TopShelf` and `DionysusTVTopShelf`, and what nothing can reach (the extension's own entry point).
- [ ] **Step 6: Fill sections 4 and 5.** Section 4: the top hotspots with Step 4's notes, and the totals of unreached logic lines per area. Section 5: one subsection per device type (iPhone, iPad, Duo by pose, Apple TV, Top Shelf, floors), each ending with its candidate findings.
- [ ] **Step 7: Check:** no line in sections 4 or 5 calls code "untested" that some run reaches (Review Focus 4); every floor item says "not measured".

## Task 3: Test quality

**Files:**
- Modify: the report's section 7
- Scratch: `$SCRATCH/scripts/scan_tests.py`, `$SCRATCH/quality/flags.csv`, `$SCRATCH/quality/sample.md`

**Interfaces:**
- Consumes: `union.csv` (Task 2), to tell which flagged tests sit on well-covered code.
- Produces: `flags.csv` (`file,line,test,flag,confirmed`), read by Task 7.

- [ ] **Step 1: Write the static scan** over `DionysusPlayerTests`, `DionysusTVTests`, `DionysusPlayerUITests`, `DionysusTVUITests` (1,487, 395, 146 and 244 `func test` on 2026-11-05; check whether any file uses Swift Testing's `@Test`/`#expect` and handle both). One row per test per flag:
  - `no-assert`: no `XCTAssert*`, `XCTFail`, `#expect`, `#require`, `XCTUnwrap`, `wait(for:)`/`waitForExistence` result checked, or a helper the test file defines that asserts (follow one level of helper calls in the same file and in the target's shared helpers).
  - `existence-only`: every assertion is `XCTAssertNotNil`, `XCTAssertTrue(x.exists)`, `waitForExistence` or `#expect(x != nil)`, with no compared value.
  - `mock-only`: every assertion is on a mock or spy's recorded calls or counts (a type named `Mock*`, `Spy*`, `Fake*`, `Stub*`, or `MockURLProtocol`'s recorded requests), none on the subject's own output or state.
  - `sleep`: `sleep(`, `usleep(`, `Thread.sleep`, `Task.sleep` or `RunLoop…run(until:` in a test or its file's helpers.
  - `skipped`: `XCTSkip`, `throw XCTSkip`, `.disabled`, or listed in a plan's `skippedTests`.
  - `near-duplicate`: the body, with identifiers and literals normalised, matches another test's at 90% or more (difflib ratio), in the same target.
- [ ] **Step 2: Random-plan drift:** compare `UnitTests` with `UnitTests-Random` and `TVUnitTests` with `TVUnitTests-Random` (targets, selected and skipped tests, options other than order). Any difference is a finding.
- [ ] **Step 3: Read by hand** every flag in `Core/Playback`, `Core/Networking`, `Core/Downloads`, the shared view models and the player journeys, plus a random 30 of the rest (`random.seed(20261105)`). Mark each `confirmed` (it really is weak), `false-positive` (with why) or `fine-as-is` (weak by the rule, but right for what it pins, for example an existence check on a screen that only has to appear). Write the reading to `sample.md`.
- [ ] **Step 4: Fill section 7:** counts per flag and target, the false-positive rate from the random sample, the confirmed weak tests grouped into findings (one finding per pattern per area, not per test), random-plan drift, and the confirmed `sleep`s with what each should wait on instead.
- [ ] **Step 5: Check:** every finding in section 7 cites at least one `file:line` that was read by hand.

## Task 4: Journey and audit gaps

**Files:**
- Modify: the report's section 6
- Scratch: `$SCRATCH/journeys/screens.csv`

**Interfaces:**
- Consumes: section 5's device notes (Task 2).
- Produces: `screens.csv` (`platform,screen,entry_point,journeys,audited,devices_reached`), read by Task 5.

- [ ] **Step 1: List the screens and flows.** iOS: every screen-level view under `DionysusPlayer/Features/*` and `Shared/` reachable from `MainTabView` or `OnboardingFlowView`, every sheet, menu and confirmation dialog, and every `AppRoute` case. Apple TV: every page under `DionysusTV/Shell`, `Browse`, `Onboarding`, `Player`, and the player panel's tabs. Note each flow's entry point.
- [ ] **Step 2: Map each to journeys.** Use `TESTING.md`'s "Where each thing is tested" tables, then grep the UI test targets for the screen's `A11yID` identifiers and screen helpers (`Screens.swift`, the TV equivalents) to confirm a journey actually reaches it and asserts on it.
- [ ] **Step 3: Accessibility audits.** For each screen, does `AccessibilityAuditTests` audit it, on which platform, and is the audit scoped to all of the screen? Include the Playback settings audit's `app.swipeUp()` (`DionysusPlayerUITests` `AccessibilityAuditTests`, about line 305), which on the fold probably audits only the top of the list; the fix noted for it is `ProfileScreen.scrollSettings()`.
- [ ] **Step 4: Devices.** From Task 2's runs, mark which devices reach each screen. Flag every Duo fold layout with no journey that asserts its layout in the pose it applies to (`UITestCase.duoPose`), and every iPad split layout with no iPad assertion.
- [ ] **Step 5: "Checked by hand."** For each item in `TESTING.md`'s "Checked by hand", say whether the harness could now reach it (fake engine, stub-server scenario, launch argument) and at what cost; only the ones it could become findings.
- [ ] **Step 6: Fill section 6:** the screens with no journey, the screens journeys open but assert nothing about, audit gaps, device gaps, and the hand-checked items that could be automated.
- [ ] **Step 7: Check:** every "no journey" claim was confirmed by grep for both its identifiers and its screen helper.

## Task 5: The smoke plans

**Files:**
- Modify: the report's section 8
- Scratch: `$SCRATCH/smoke/fixes.csv`, `$SCRATCH/smoke/nightly.csv`

**Interfaces:**
- Consumes: `screens.csv` (Task 4).

- [ ] **Step 1: What smoke runs:** list `UITests-Smoke`'s seven tests and `TVUITests-Smoke`'s selection, and the screens and flows they pass through (from `screens.csv`).
- [ ] **Step 2: Recent fixes:** every commit on `develop` since 2026-09-06 that fixes a user-facing bug (`git log --since=2026-09-06 --first-parent develop` merge commits, read their PRs' titles and bodies with `gh pr view`). For each: area, platform, whether a smoke test passes through the broken path, whether the full plan does, whether a unit test now pins it. Write `fixes.csv`.
- [ ] **Step 3: Regressions caught only at night:** every `nightly-ui-tests.yml` run on `develop` since 2026-10-12 that failed, with the failing tests. Separate real regressions (the test failed until a fix landed) from flakes (passed on the next nightly with no related change), using the weekly flake report where it covers the dates. For each real one, would smoke have caught it at PR time? Write `nightly.csv`.
- [ ] **Step 4: Fill section 8:** what smoke covers, the risky paths it misses ranked by Step 2 and 3's evidence, and any smoke test that no longer pulls its weight. Give each proposed addition its likely cost in PR-check minutes (from the full plan's per-test durations in a recent nightly's `.xcresult`, or the job logs).

## Task 6: Flake follow-ups

**Files:**
- Modify: the report's section 9

- [ ] **Step 1: For each item, check whether it still happens** since #427 merged (2026-11-05: the PR checks, nightlies and the weekly flake report from then on; if there are fewer than three nightlies since, say so):
  - tvOS: Select on a just-focused tile not opening detail (`openDetailFromFocusedTile`); `openMovies`' Down-to-Search miss; the one-off `test_failedDetail`; the VoiceOver announcement after a post-playback pop (to be checked on the Apple TV: list it as owed, don't check it on a device).
  - iOS: the iPhone 17 Add to Playlist sheet one-off; Duo `testEmptyLibraryScenarioIsServed` and the slow-logo retries; the tvOS 26.5 floor failures.
  - CI: the flake report counts only failed jobs (it misses flakes a retry absorbed, and allowed failures); random-plan copies can drift (Task 3 Step 2 measures it); the flake-hunt job has no step budget; `--limit 200` truncation.
- [ ] **Step 2: Fill section 9:** one row per item: still seen (with run ids) or not seen since, and a candidate finding for each that still matters.

## Task 7: Rank, write the summary, hand over

**Files:**
- Modify: the report's sections 1 and 10

- [ ] **Step 1: Collect every candidate finding** from sections 4 to 9 into section 10's table, numbered `TQ-01` onward, with the Task 0 format. Merge duplicates (the same gap found by coverage and by the journey map is one finding citing both).
- [ ] **Step 2: Cross-check executed versus verified** (Review Focus 3): for each file with 80% or more reached lines that holds a test flagged and confirmed in Task 3, add a line to that finding saying the coverage figure overstates it.
- [ ] **Step 3: Rank:** High before Medium before Low; within a risk level, cheaper first. Section 1 is the top ten, one line each, plus three sentences on the overall picture (where the tests are strong, where they're weakest, the single most worthwhile fix).
- [ ] **Step 4: Self-check the report:** every finding has evidence that can be traced; no section still says "to fill"; no claim says "tested" where the evidence is coverage alone; floors say "not measured".
- [ ] **Step 5: Hand back:** restore the Simulators' sign-in (Global Constraints), purge scratch result bundles, and send Benjamin the report's path with the top ten in chat. **Wait for his sign-off before committing.**
- [ ] **Step 6: After sign-off:** commit the report and this plan (`git add docs/superpowers/specs/2026-11-05-test-quality-coverage-review.md docs/superpowers/plans/2026-11-05-test-quality-coverage-review.md`), push, open the PR into `develop` (summary: what was measured, how many findings by risk), and merge with `--merge` once checks pass and he approves.
- [ ] **Step 7: Memory:** update `test-quality-coverage-review-queued.md` to say the report is done, where it is, and that Benjamin is choosing fixes.
