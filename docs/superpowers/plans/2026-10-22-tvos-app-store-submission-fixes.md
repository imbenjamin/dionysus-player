# Apple TV 1.2.0 Submission Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear the three findings likely to get the Apple TV app rejected
(H1–H3), plus the two listing fixes beside them (M1–M2), then submit.

**Architecture:** One code change on both apps (the Spatial Audio heading,
with its explanation moved to a page of its own); the rest is App Store Connect metadata, the documented
`develop → stable` release flow, and a rehearsal of the reviewer's path
on the Simulator.

**Tech Stack:** SwiftUI (iOS and tvOS), String Catalog, App Store Connect API
(hand-rolled ES256 JWT, memory `asc-api-direct-queries`), `release.yml`.

**Spec:** `docs/superpowers/specs/2026-10-22-tvos-app-store-review.md`

## Global Constraints

- Benjamin signs off before every commit, and before every App Store Connect write (he switches to manual mode for those; announce each write first).
- Never run `devicectl` against a physical Apple TV or iPhone without asking. The Simulator is fine.
- PRs go to `develop` and merge with `--merge`, never squash.
- Copy goes through `Localizable.xcstrings`, synced by an Xcode.app build in the same PR (memory `automate-xcstrings-catalog-sync`).
- Before handing back, sign the Simulators in to SavareseHillFlix as Ben again (memory `restore-simulator-login-on-handback`).
- The final tag goes on `stable`'s merge commit, never on beta.1's commit (`VERSIONING.md`, "A final release can't be tagged on its prerelease's commit").

## Review Focus

- The reviewer types `demo.jellyfin.org/stable` without `https://`: the HTTP 302 must land on HTTPS and connect (`probe` → `correctingScheme`). Task 2, step 3.
- The reviewer answers Don't Allow to the Local Network prompt: Enter Server Address must still connect. Task 2, step 2.
- The reviewer presses Menu on the Quick Connect screen: it must close back to Who's Watching?, not leave the app. Task 2, step 4.
- The demo server refuses a request mid-review (shared-account 401s): relaunching and signing in again must recover. Task 2, step 6.
- The review device runs tvOS 26.x (the floor is 26.0): the sign-in path must work there too. Task 2, step 7.
- A VoiceOver user on the Apple TV opens About Spatial Audio: Menu must return focus to its row, not the top of Profile. Task 1, step 4.

---

### Task 1: Spatial Audio: no "(beta)", a short footer, and an "About Spatial Audio" page (H3)

"(beta)" stood for AetherEngine #850 (with Spatial Audio on, 4K TrueHD
remuxes stall on the A15 Apple TV). Benjamin chose (2026-10-23): the heading
becomes "Spatial Audio", the footer shrinks to one sentence, and the full
explanation, the stall warning included, moves to a page of its own. On iOS
it's a **Learn More…** button in the footer that opens a sheet. On tvOS
(no popovers, and focus never reaches a footer) it's an **About Spatial
Audio** row at the end of the section that opens a full-screen cover, like
License and Privacy Policy. Neither the heading nor the page says "beta",
"experimental" or "known issue" (2.2).

**Exact copy** (one catalog key per string, shared by both apps):

- Heading: `Spatial Audio`
- Footer (both apps): `Keeps the height channels of Dolby TrueHD Atmos and DTS:X tracks, for a receiver with height speakers or for AirPods.`
- iOS link: `Learn More…` · tvOS row: `About Spatial Audio` · page title (both): `About Spatial Audio`
- Page, four paragraphs in this order:
  1. `Dolby TrueHD and DTS-HD Master Audio can't be sent to a receiver or AirPods as they are, so Dolby Atmos and DTS:X tracks usually play as 5.1 and lose their height channels. With Spatial Audio on, Dionysus decodes the height channels and re-encodes them as Spatial Audio.`
  2. `A receiver or soundbar shows the result as Dolby Atmos, DTS:X tracks included, and AirPods play it as Spatial Audio. The audio is re-encoded, so it isn't lossless.`
  3. `Choose the speaker layout that matches your setup. 7.1.4 is the default and is recommended for AirPods. DTS:X offers 7.1.4 and 9.1.6.`
  4. `Re-encoding takes a lot of processing power: on some devices, a 4K title with one of these tracks can pause to buffer. If that happens, turn Spatial Audio off for that format.`

**Files:**
- Create: `DionysusPlayer/Core/Playback/SpatialAudioHelp.swift` (the page's text, compiled by both apps through `Core/`)
- Create: `DionysusPlayer/Features/Profile/SpatialAudioHelpView.swift` (iOS sheet)
- Modify: `DionysusPlayer/Features/Profile/ProfileView.swift:497-512` (`spatialAudioSection`: heading, footer, button, sheet)
- Modify: `DionysusTV/Shell/Profile/TVProfileView.swift:22` (`Cover`), `:166-169` (cover content), `:273` (heading), `:292-328` (`spatialAudioRows`: row and footer), `:64` (the focus-order list the About rows are in)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift:379-382` and `:601-604` (new ids beside the Spatial Audio ones)
- Modify: `DionysusPlayer/Resources/Localizable.xcstrings` (Xcode sync; the old heading and footer keys go stale)
- Modify: `DionysusPlayer/Core/Playback/CLAUDE.md:139-146` (the "(beta)" bullet: where the warning lives now, and that paragraph 4 comes out once #850 is verified fixed on the Living Room box)
- Modify: `DionysusTV/CLAUDE.md`, "Profile and settings", Spatial Audio bullet (the About row and its cover)
- Test: `DionysusPlayerTests/Core/Playback/SpatialAudioHelpTests.swift` (new), `DionysusPlayerUITests/Journeys/ProfileJourneyTests.swift`, `DionysusPlayerUITests/Journeys/AccessibilityAuditTests.swift`, `DionysusTVUITests/ProfileJourneyTests.swift`, `DionysusTVUITests/AccessibilityAuditTests.swift`

**Interfaces:**
- Produces: `enum SpatialAudioHelp { static var paragraphs: [String] }`, each built with `String(localized:)`.
- Produces: `A11yID.Profile.spatialAudioLearnMore`, `A11yID.Profile.spatialAudioHelp` (the page's text block, never the sheet's root), `A11yID.Profile.spatialAudioHelpDone`; `A11yID.TV.Profile.spatialAudioAbout`.
- Consumes: `TVTextPageView(title:paragraphs:)` and `TVSettingsRow` via `row(_:opensPage:id:action:)` (existing).

- [ ] **Step 1: Write the failing unit test** `SpatialAudioHelpTests` (in the tvOS test target too, through `project.yml`'s `Core/Playback/**` include):
  - `test_paragraphs_areTheFourInOrder`: `SpatialAudioHelp.paragraphs.count == 4`; `[0]` has prefix `"Dolby TrueHD and DTS-HD Master Audio"`, `[3]` has prefix `"Re-encoding takes a lot of processing power"`.
  - `test_paragraphs_neverCallTheFeatureABeta`: no paragraph contains, case-insensitively, `"beta"`, `"experimental"` or `"known issue"`.
- [ ] **Step 2:** Run `xcodebuild test … -scheme DionysusPlayer -only-testing:DionysusPlayerTests/SpatialAudioHelpTests`. Expected: FAIL, `SpatialAudioHelp` not found.
- [ ] **Step 3:** Create `SpatialAudioHelp.swift` with the four paragraphs above, then `xcodegen generate`. Run the test again. Expected: PASS.
- [ ] **Step 4: Write the failing UI journeys.**
  - iOS `ProfileJourneyTests.testSpatialAudioLearnMoreOpensAndCloses`: on Profile, tap `spatialAudioLearnMore`; `spatialAudioHelp` exists; tap `spatialAudioHelpDone`; `spatialAudioLearnMore` is hittable again.
  - tvOS `ProfileJourneyTests.test_spatialAudioAbout_opens_andMenuReturns`, after `test_privacyPolicy_opens_andMenuReturns`'s shape: move focus to `spatialAudioAbout`, Select, the page shows, Menu, and focus is back on `spatialAudioAbout`.
  - Audits: iOS `testSpatialAudioHelpHasNoAccessibilityIssues` (sheet open); tvOS `test_profileSpatialAudioAbout` (cover open), beside `test_profileTextPage`.
  Run the four. Expected: FAIL, ids not found.
- [ ] **Step 5: iOS.** In `spatialAudioSection`, the header is `Text("Spatial Audio")`, the footer is the one-sentence footer followed by `Button("Learn More…")`, styled to the footer (`.readableSettingsFooter()`, footnote, accent tint), which sets `@State showsSpatialAudioHelp`. `.sheet(isPresented:)` presents `SpatialAudioHelpView`: a `NavigationStack` titled "About Spatial Audio", the paragraphs in a `ScrollView`, and a Done button (`.confirmationAction`). A large-detent sheet on both iPhone and iPad.
- [ ] **Step 6: tvOS.** Heading `"Spatial Audio"`. Add `Cover.spatialAudioHelp`; its content is `TVTextPageView(title: "About Spatial Audio", paragraphs: SpatialAudioHelp.paragraphs.map { AttributedString($0) })`. In `spatialAudioRows`, after the layout rows: `row("About Spatial Audio", opensPage: true, id: A11yID.TV.Profile.spatialAudioAbout) { cover = .spatialAudioHelp }`, then the short footer. Add the id to the list at `:64` in section order.
- [ ] **Step 7:** `xcodegen generate`, then sync the catalog with an Xcode.app build. Expected diff: the new keys added, "Spatial Audio (beta)" and the long footer stale. `grep -rn "Spatial Audio (beta)" --exclude-dir=.git .` then matches only the stale catalog entry.
- [ ] **Step 8:** Screenshot, on the iPhone 17 and tvOS 27 Simulators: the Spatial Audio section, and the page open. Send them to Benjamin and wait for his OK before running tests (memory `show-visual-changes-before-tests`).
- [ ] **Step 9:** Run the four journeys and two audits from step 4. Expected: PASS. Then, one after another: `TVUnitTests`, `TVUITests` (warm-up journey first), iOS `UnitTests`, iOS `UITests-Smoke`, and `xcodebuild build -configuration Release -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO`. Expected: all pass, BUILD SUCCEEDED.
- [ ] **Step 10:** Update the two `CLAUDE.md` files, commit (after sign-off) on `fix/spatial-audio-help` from `develop`, open the PR, merge with `--merge` once CI is green.

### Task 2: Rehearse the reviewer's path on the Simulator (H1)

Walk `docs/store/tvos-review-notes.md` exactly as written, on a fresh install
of `develop` with Task 1 in it. Every label the notes name must be on screen
as written.

**Files:**
- Modify: `docs/store/tvos-review-notes.md` (only where the rehearsal disagrees with it)

- [ ] **Step 1:** On the tvOS 27 Simulator (`47399BA1-…`), uninstall Dionysus and run `xcrun simctl keychain 47399BA1-8F7A-45F6-9E8C-747034CE1DC7 reset`. The server configuration lives in the shared keychain and survives a reinstall, so without the reset it isn't a first launch. Build and install `develop`.
- [ ] **Step 2:** Launch, choose Get Started, answer **Don't Allow** to the Local Network prompt. Expected: the list stays empty and Enter Server Address still opens the field.
- [ ] **Step 3:** Type `demo.jellyfin.org/stable` (no scheme) and choose Connect. Expected: Who's Watching? lists `demo`. Then repeat from step 1 with `https://demo.jellyfin.org/stable`, answering Allow.
- [ ] **Step 4:** Choose `demo`. Expected: the Quick Connect screen. Press Menu: expected, back on Who's Watching?. Choose `demo` again, then Use Password Instead, leave the field empty, Sign In. Expected: Home loads with the demo library.
- [ ] **Step 5:** Play a title for 30 seconds, swipe down (Info/Audio/Subtitles), Menu out. Open Profile and check that the footer reads `Dionysus Player <version>` and that Privacy Policy opens. Back on Home with focus on the hero, press Menu twice. Expected: the first opens the sidebar, the second goes to the tvOS Home Screen.
- [ ] **Step 6:** Relaunch. Expected: signed straight back in as `demo`, no prompt.
- [ ] **Step 7:** Repeat steps 1–4 on the tvOS 26.5 Simulator (`90E06237-…`).
- [ ] **Step 8:** Correct the notes wherever the screens disagree. Then sign both Simulators back in to SavareseHillFlix as Ben.

### Task 3: Correct the listing and the review notes in App Store Connect (H1, M1, M2)

**Files:**
- Modify: `docs/store/tvos-listing.md` (drop "MORE TO COME"; record the subtitle if it changes)
- Create: `docs/store/tvos-review-notes.md` (written by this audit; in the PR as the record)

- [ ] **Step 1:** Remove the "MORE TO COME" heading and paragraph from the description in `docs/store/tvos-listing.md`.
- [ ] **Step 2 (Benjamin):** Decide the subtitle (M1). It's shared with iOS and can be edited only while App Info is editable; it reads `WAITING_FOR_REVIEW` now, because iOS 1.1.0 is waiting for review. A platform-neutral subtitle (30 characters at most), or leave it for this round.
- [ ] **Step 3:** Commit both docs (after sign-off) and open a docs PR to `develop`.
- [ ] **Step 4 (manual mode):** PATCH `/v1/appStoreReviewDetails/cd922680-ca5d-4d9c-ac79-a87ab3249980` with `notes` set to the text between the rules in `tvos-review-notes.md` (keep `demoAccountName: demo`, `demoAccountRequired: true`). Read it back. Expected: identical text, under 4,000 characters (2,500 or so now).
- [ ] **Step 5 (manual mode):** PATCH `/v1/appStoreVersionLocalizations/e1e7066c-561d-49ad-8ecc-bce9301154dd` with the new `description`. Read it back.

### Task 4: Ship v1.2.0 from `stable` (H2)

**Decision first (Benjamin):** the `v1.2.0` tag builds both apps, so it also
makes iOS 1.2.0 final (uploaded, not submitted) and publishes the GitHub
Release. The alternative, submitting beta.1 (build 861), shows "1.2.0-beta.1"
in Profile and serves the iOS-only privacy policy.

- [ ] **Step 1:** `gh workflow run promote-to-stable.yml`; wait for the `develop → stable` PR's checks; merge with `--merge`.
- [ ] **Step 2:** Check the published policy: `curl -s https://raw.githubusercontent.com/imbenjamin/dionysus-player/stable/PRIVACY.md | grep -c "Top Shelf"`. Expected: 1 or more.
- [ ] **Step 3:** `git checkout stable && git pull`, then `git tag -a v1.2.0` on the merge commit with release notes written per `VERSIONING.md` ("Release notes"; no prerelease disclaimer), and `git push origin v1.2.0`.
- [ ] **Step 4:** Watch `release.yml` (about 75 minutes; rerun a flaked UI leg with `gh run rerun <id> --failed`). Expected: both uploads succeed, Release published.
- [ ] **Step 5:** Query `/v1/builds?filter[app]=6803951723&filter[preReleaseVersion.platform]=TV_OS&sort=-uploadedDate&limit=1`. Expected: build number above 861, `processingState: VALID`.

### Task 5: Attach the build and submit (Benjamin)

- [ ] **Step 1 (manual mode):** PATCH `/v1/appStoreVersions/b29d48b5-3cc8-4792-931c-769708d2b6b2/relationships/build` with the Task 4 build, or attach it in the App Store Connect UI.
- [ ] **Step 2:** In App Store Connect, check the `TV_OS` 1.2.0 page: build attached, seven Apple TV screenshots, notes from Task 3, release type (currently "after approval"). Answer the export-compliance question if asked (`ITSAppUsesNonExemptEncryption` is `false`, so it shouldn't be).
- [ ] **Step 3:** Benjamin submits for review.
- [ ] **Step 4:** Update memory `tvos-app-direction` and `open-issues-and-follow-ups` with the submission and the low/HIG items in the spec that were left for later.
