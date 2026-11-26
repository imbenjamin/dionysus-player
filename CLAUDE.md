# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Dionysus Player is a native Jellyfin client for iPhone, iPad and Apple TV.
It talks to a Jellyfin server over the plain
REST/JSON API (https://api.jellyfin.org/) and plays media through
AetherEngine, a third-party FFmpeg + VideoToolbox engine (HDR10, HDR10+,
Dolby Vision), pulled in as a Swift Package.

Releases are tagged from `stable` (v1.0.0 was the first, 2026-09-07); see
`VERSIONING.md`. Direct play of HDR video with passthrough audio is verified
on device; treat other paths (transcoding, other HDR formats, other devices,
seeking edge cases) as unverified until checked.

**The deployment floor is iOS 18** (raised from 17 on 2026-09-23 for
AetherEngine 7.x, whose 7.0.0 raised its own floor). iOS 17 devices keep
v1.0.0. Read AetherEngine's floor from `Package.swift` at the tag, never from
its release notes, which have disagreed with it.

**Both apps build with Xcode 27.1 in every CI job** (GitHub's `xcode-27`
image) **and with Xcode 27.2 (27B52) on the Mac.** Locally the iOS
Simulators run iOS 27.2 (the iPhone Duo has its own 27.2 runtime) and 18.6,
the Apple TV ones tvOS 27.2 and 26.5; CI's are iOS 27.2, the Duo's 27.1,
18.6, tvOS 27.0 and (nightly smoke, allowed to fail) tvOS 26.5. So a break
that shows only in CI may be 27.1-only: CI is the gate. CI's OS versions
are pinned, never "the newest": the required check names carry them, so
changing one means updating both rulesets in the same change. AetherEngine
builds only with Xcode 27, so no job can go back to an older image. CI also
tests the iOS 18.6 floor (full plan only) and the iPhone Duo
on iOS 27.1 in each pose, set through Device Hub by `Scripts/duo-pose/`
(`TESTING.md`, "Where they run in CI").

**Where the rest of the guidance lives.** Claude Code loads a folder's own
`CLAUDE.md` when working in it:

- `DionysusTV/CLAUDE.md`: the Apple TV app (shell, focus, pages, VoiceOver,
  accounts, the player, HDR on the Apple TV).
- `DionysusPlayer/Core/Playback/CLAUDE.md` (also loaded from
  `Features/Player/`): playback, Picture in Picture, Now Playing and
  subtitles (libass, timing, geometry, fonts).
- `TESTING.md`: the test suites, the UI-test harness and its scenarios, CI.
- `VERSIONING.md` (releases, signing), `DOWNLOADS.md` (the download ladder),
  `PRIVACY.md`, and design specs and plans under `docs/superpowers/`.

A folder's `CLAUDE.md` inside a target's sources must be excluded in
`project.yml` (`"**/CLAUDE.md"`), or XcodeGen bundles it into the app as a
resource, and two in one target fail the build.

### The Apple TV target, in brief

`DionysusTV` is a separate tvOS target (floor **tvOS 26.0**, same bundle ID as
iOS for Universal Purchase) with its own UI under `DionysusTV/`. It compiles
the iOS app's `Core/`, `App/AppState.swift`, a short list of `Shared/` files
and every `Features/**/*ViewModel.swift`; `project.yml`'s `includes` on the
target is the list. Two rules bind shared code:

- **Downloads don't exist on tvOS**: `Core/Downloads` isn't compiled, and
  shared code guards its download paths with `#if DOWNLOADS`, a compilation
  condition only `DionysusPlayer` and `DionysusPlayerTests` define. Shared code
  that names a Downloads type must sit inside that guard, or the tvOS build
  breaks.
- **A shared view model's change ships on both platforms.** Several tvOS
  decisions live in shared code (Home's hero asks for `ImageTypes=Backdrop`,
  `AssetDetailViewModel.loadIfNeeded()` loads in a task of its own); check
  `DionysusTV/CLAUDE.md` before changing a shared view model's behaviour.

Scheme `DionysusTV`; its unit tests (`DionysusTVTests`, plan `TVUnitTests`)
reuse the shared test files. It embeds `DionysusTVTopShelf`, the Top Shelf
extension, which compiles `DionysusTV/TopShelf` and a UI-free slice of
`Core/` (its `sources` in `project.yml`); see `DionysusTV/CLAUDE.md`,
"Top Shelf". Design and milestones:
`docs/superpowers/specs/2026-09-29-tvos-app-design.md`.

## Commands

The Xcode project is generated from `project.yml` by XcodeGen and not
committed, so project structure is a readable diff. **Whenever `project.yml`
or the set of source files changes, regenerate it:**

```sh
xcodegen generate
open DionysusPlayer.xcodeproj   # scheme DionysusPlayer (iOS) or DionysusTV
```

Tests (see `TESTING.md` for the plans, the harness and CI):

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'            # UnitTests
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -testPlan UITests-Smoke -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -testPlan TVUnitTests -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)'
```

The Apple TV destination is the 4th generation on tvOS 27.2 locally: Xcode 27.2
won't resolve the 3rd generation, whose Simulator is on tvOS 27.0. CI keeps the
3rd generation (`TESTING.md`, "Running the tests").

Plans live in `TestPlans/`: `UnitTests` (the iOS scheme's default),
`UITests-Smoke` (the PR gate), `UITests-Full`, and on tvOS `TVUnitTests`,
`TVUITests-Smoke` and `TVUITests`. Required check names embed the device and
OS, so changing either means updating both rulesets in the same change
(`TESTING.md`, "Where they run in CI").

### Pinning AetherEngine

**The app reaches AetherEngine through a local package,
`Packages/AetherEngineWithObjectAudio`, and its `Package.swift` is where the
engine is pinned**, with `exact:`, never a `from:` range. The package exists to
switch on AetherEngine's `TrueHDObjectAudio` and `DTSXObjectAudio` traits
(TrueHD Atmos and DTS:X as Spatial Audio; off by default since 7.39.0), which
XcodeGen can't set: 2.45.4 drops a `traits:` key silently. It re-exports the
engine, so `import AetherEngine` works as before. `Package.resolved` is
gitignored with the generated project, so CI caches the package checkouts
(`.build/SourcePackages`, in `setup-ios-project`) keyed on every
`Packages/**/Package.swift` and `project.yml`'s `packages:` block, with no
`restore-keys`. Only the nightly on `develop` writes it (about 0.93 GB, beside
the 8.8 GB iOS 18.6 runtime in a 10 GB quota); every other run restores. After
a pin change, runs are cold until the next nightly. A cold resolve after
changing the pin can fail with "enables traits on package … that declares no
traits": a cached older checkout was read; resolve into fresh DerivedData.

The weekly "Bump AetherEngine" workflow (`aetherengine-bump.yml`) opens a PR
bumping the pin to the newest release in the current major, which goes
through `pr-checks.yml` like any PR. It never proposes a major bump: that is
where AetherEngine's API may break, and it is a deliberate manual edit.

The version shown in Playback Stats comes from the engine itself
(`AetherEngine.version`, read through `AetherEngineVersion` in
`Core/Playback/`), so nothing needs regenerating after a bump.

### App version (SemVer)

The app's version follows SemVer, grounded in git tags and wired into
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` as far as Apple's numeric
fields allow; Profile's footer shows it (`AppVersionInfo`, from a checked-in
`AppVersion.swift` that `Scripts/update-version.sh` refreshes). See
`VERSIONING.md` for the tag convention and the alpha/beta/final flow.

`stable` is the branch final `vX.Y.Z` releases are tagged from. It moves
forward only through the `develop → stable` promotion PR
(`promote-to-stable.yml`) and is never branched from or committed to
directly. `develop` is the default branch and where all work happens.

**Cutting a release is one annotated tag push.** `release.yml` stamps the
version from the tag and, for both apps in parallel, builds, tests, archives,
signs and uploads to App Store Connect (TestFlight); it publishes the GitHub
Release once both have. Nothing needs stamping
beforehand; before adding a "stamp before tagging" step, read
`VERSIONING.md`'s "Why there is no longer a release-prep PR". Three things
the workflow doesn't show:

- **The annotated tag's message is the release notes**: the GitHub Release
  body and TestFlight's "What to Test". A lightweight tag gives an empty
  summary.
- **`Config/Version.xcconfig` and `AppVersion.swift` lag between releases**
  on purpose: CI stamps the shipped build, and the checked-in copies report
  off-tag metadata (`0.8.0-alpha.1+12.gabc1234`). Don't "fix" them.
- **The archive and the export both sign manually**, with the distribution
  certificate and a provisioning profile named by string (each shipped
  target's Release config in `project.yml`, and `Config/ExportOptions.plist`
  or `Config/ExportOptions-tvOS.plist`; three profiles, listed in
  `VERSIONING.md`).
  Automatic export fails with a cloud-signing permission error, and automatic
  archiving made a new development certificate per run. Both expire
  2027-08-30; see `VERSIONING.md`'s "Signing setup".

## UI verification

**The regression net is the XCUITest suites** (`DionysusPlayerUITests`,
`DionysusTVUITests`), driving the real app against an in-process stub server
and a fake playback engine; `TESTING.md` covers the harness, launch
arguments, scenarios and selector rules. **If a change touches a view, add or
update a journey** rather than checking once by hand. Two rules that each
cost a debugging session, both documented in `A11yID`: never select on an
accessibility *label* (labels are localized), and never put an identifier on
a screen-root container (it can overwrite every descendant's own).

**Accessibility is gated too.** `AccessibilityAuditTests` runs
`performAccessibilityAudit()` over every screen on the structural audit types
(unlabeled controls, labels that aren't human-readable, wrong traits, hit
regions). A decorative `Image(systemName:)` without
`.accessibilityHidden(true)` fails it, since VoiceOver would read the SF
Symbol's name. Contrast, Dynamic Type and text clipping are deliberately not
gated (`TESTING.md`, "Accessibility audits").

**A view that changes under VoiceOver reads `@VoiceOverEnabled`**, never
`@Environment(\.accessibilityVoiceOverEnabled)`: XCUITest can't turn
VoiceOver on, and the wrapper is what `-UITestSimulateVoiceOver` sets, so
`VoiceOverJourneyTests` can reach the controls that only mount under it.

**To reach a screen, open a `dionysus://` link rather than tapping through
to it**: `Scripts/deeplink.sh 'item/<id>?section=cast'` on the booted
Simulator, iOS or Apple TV, signed in or not (a link waits through
sign-in). A page, a library's filtered grid, a Profile page, a show's
season or playback at a time, version, track, with Playback Stats open (and,
in DEBUG builds, Direct Play or a bitrate cap) are each one link; the list
is `TESTING.md`, "Deep links for debugging and tests". Journeys can open
their page the same way when the path there isn't what they test.

For exploratory checks (a new design, something a journey can't express),
prefer the `ios-simulator-skill` over coordinate taps: it drives the
Simulator through `idb`'s accessibility tree. It needs `idb-companion`
(`brew tap facebook/fb && brew install idb-companion`) and the `idb` client
installed with `pipx install --python $(which python3.12) fb-idb` (pipx's
newer default Python fails with an `asyncio.get_event_loop()` error). Start
with `idb_companion --udid <udid> &`, then `idb connect <udid>`. It works on
Login, Home, Search, Profile, detail pages and the Player (XCUITest drives
the player's controls too, under the harness's fake engine); avoid automating
over a real AetherEngine session, whose surface repaints continuously.

Boot one Simulator only when a step needs it, never several at once, and
shut it down (`xcrun simctl shutdown <udid>`) when the task is done: several
booted together saturate the Mac. Reuse an existing Simulator; never create
one without asking. Use the iPhone 17 unless the check needs the iPhone Duo.

## Architecture

The app is a linear state machine at the top, with feature modules beneath
that share one MVVM shape.

### App-level flow (`App/`)

`AppState` is the single source of truth for where the user is, driven by a
`Phase` enum: `.serverSetup` → `.login` → `.main`. It owns the
`JellyfinAPIClient`, one per configured server (made in `completeServerSetup`,
remade on `start()`). `RootView` shows `MainTabView` once in `.main` with the
session restored, and `OnboardingFlowView` otherwise. `ServerSessionStore`
(`Core/Persistence/`) splits storage by sensitivity: server config in
`UserDefaults` (in the shared keychain on tvOS), credentials and the token in
the Keychain (`KeychainStore`). `AppState.start()` restores the server, then
tries a silent sign-in before falling back to the login screen.

### Welcome, server setup and sign-in (`Features/Onboarding/`)

`OnboardingFlowView` hosts four stages (the splash while
`AppState.isRestoringSession`, the first-run `WelcomeView`, server setup,
sign-in) and owns what they share so nothing cuts between them: the brand
background, the glyph's matched-geometry namespace, an always-dark
appearance scoped to the flow, the composition and the orientation lock.
Shared pieces are in `Shared/Components/Onboarding/`.

- **The composition is chosen from the window, never the device**
  (`OnboardingLayout.resolve`): compact unless the size class is regular *and*
  the window is at least 600pt wide; then regular, or landscape for a window
  wider than tall and at least 900pt. The size is the whole window, safe
  areas included: a foldable's vertical status bar otherwise took enough off
  its 951pt inner screen to miss the threshold. `OnboardingLayoutTests` pins
  every measured device size.
- **Portrait-only on a phone-sized screen**: shorter side under 600pt
  (`RotationLock.isPhoneSized`), keyed on the screen, not the idiom, because a
  foldable iPhone is both (outer 466pt, inner 669pt held landscape). **The
  lock asks the scene to rotate only from sideways**
  (`RotationLock.needsRotationToPortrait`): a `requestGeometryUpdate(.portrait)`
  made while already upright outlived the lock, so unfolding left the inner
  screen sideways, onboarding and the signed-in app alike, until a relaunch.
- **The welcome shows once** (`ServerSessionStore.hasCompletedWelcome`): "Get
  Started", or having ever configured a server. `clearAll()` leaves it set,
  so changing server never replays it. UI tests skip it with
  `-onboarding.welcomeCompleted YES`.
- **`HasPassword: true` doesn't mean a password is needed.** Sign-in lists
  `/Users/Public` (unauthenticated, as Jellyfin's own login page does), and
  the demo server reports `demo` as `HasPassword: true` while accepting an
  empty password. So only `false` signs in on one tap; anyone else is asked,
  and an empty password is still submitted. An empty list (every user hidden)
  falls back to a username/password form.
- **Server branding has two traps.** `/Branding/Configuration`'s
  `LoginDisclaimer` is HTML (`LoginDisclaimer.plainText(from:)` strips it).
  `/Branding/Splashscreen` is off by default (404) and ignores `maxWidth`,
  serving the admin's original (4MB on the demo server), so it is fetched only
  when `SplashscreenEnabled`, as JPEG, and downscaled.

The splash is sized to a measured 134pt, and `LaunchScreen.storyboard`'s
157pt glyph frame matches it (its SVG's artwork fills 1068/1253 of its
viewBox). Ambient motion (the drifting background, the scan radar) stops
under Reduce Motion and under the UI-test harness
(`UITestHarness.freezesAmbientMotion`), where a view that redraws
continuously keeps the accessibility tree moving.

### Networking (`Core/Networking/`)

`JellyfinAPIClient` is an `actor`: every call is async and serialized
through it, and it holds the token set after authentication. It's a
hand-written wrapper over Jellyfin's REST API (no generated SDK), scoped to
what the app needs: server info, auth, browsing and search, playback info,
progress reporting, and (for Playback Stats only) the server's own
session/transcode state via `/Sessions`.

**A 401 on a token-bearing request re-authenticates by itself.** `sendRaw`
remembers the last credentials that succeeded and, on a 401, signs in again
and retries with backoff (`reauthBackoffSchedule`) before giving up as
`.notAuthenticated`; a shared server can invalidate a token for reasons
outside the app. Concurrent 401s share one re-authentication, and a 401 on a
token another request has already replaced retries with the new one. A wrong
password at first sign-in isn't affected (`authenticate` is sent with
`requiresAuth: false`). `AppState.signOut()` clears the remembered
credentials, so a request still in flight can't sign the signed-out user back
in.

**Sign-in, discovery and certificate trust are in
`DionysusPlayer/Core/Networking/CLAUDE.md`**: Quick Connect (a session with
no password, so a mid-session 401 can't recover), UDP discovery (unicast to
the subnet, never broadcast), trusting a server's unverifiable certificate
(#466) and the discovered-server HTTP fallback. Two rules bind any change
here: **every new `URLSession` takes `ServerTrustDelegate`, and a task passes
`ServerTrustDelegate.forTasks(on: session)`, never `.shared`** (a session
without it fails against a trusted server while sign-in works), and a
refused certificate is **`.performDefaultHandling`, never `.cancel`**, so it
surfaces as the usual `URLError`.

**An HTTP error never shows the response body.** `JellyfinAPIError.http`
reads "Something went wrong (HTTP 404)." whatever came back: a server, or a
proxy in front of it, can answer with a whole HTML page. A detail page whose
item answers 404 (deleted since it was listed, most often a recent search)
shows "This Title Can't Be Found" with no retry (`LoadState.notFound`) and
drops the item from search history; `SearchViewModel` follows the change
through `SearchHistoryStore.didChange`.

`ImageURLBuilder` is deliberately not actor-isolated: a struct snapshotted
via `client.makeImageURLBuilder()`, so views build image URLs synchronously.

**Live playback negotiates with the server by default.**
`StreamPreferenceStore.decisionMode` (Profile → Streaming) chooses between
**Allow Transcoding** (the default since 2026-08-28:
`DeviceProfileBuilder.build(maxStreamingBitrate:)` sends a real
`DeviceProfile` on `/PlaybackInfo`, and `PlayerViewModel.start()` branches on
whether the answer carries a `transcodingUrl`) and **Direct Play Always**
(`streamURL(itemID:mediaSourceID:container:)`, `Static=true`, no profile; AetherEngine decodes whatever
comes back). A server transcode goes to AetherEngine's `nativeRemoteHLS`
bypass (`load(..., isRemoteHLS: true)`, straight to AVPlayer), and its target
is fragmented MP4 (H.264 or HEVC), never MPEG-TS: Apple's HLS spec doesn't
support HEVC in MPEG-TS on AVPlayer (`hlsTranscode`'s doc comment).
`PlaybackStats.route` shows which AetherEngine pipeline actually served a
session (`.remoteBypass`, `.loopback`…), which `playbackBackend` alone can't
tell apart.

**Downloads always transcode** (`downloadStreamURL(...)`: `Static=false`,
HEVC/MP4, capped to the chosen tier), so the app both direct-plays and
transcodes, in different places. **Read `DOWNLOADS.md` before changing any
number in `DownloadTypes.swift`**: the ladder comes from one bits-per-pixel
rule, which `DownloadTypesTests` asserts, not per-rung choices.

### Image loading & placeholders

`RemoteImageLoader` (`Core/Networking/`) is the single choke point for every
network image: an actor with its own `URLSession`, retry with backoff,
a byte-cost-limited `NSCache` and in-flight de-duplication, built for a burst
of requests against a self-hosted server on first launch.
`image(for:maxAttempts:retryBaseDelay:)` takes per-call overrides, which
`AsyncRemoteImage.RetryPatience`/`LogoImageView`'s `retryPatience`
(`.standard`/`.extended`) use to give a screen's one hero backdrop and logo a
longer budget without multiplying the initial burst. `AsyncRemoteImage`
(network) and `LocalFileImage` (`file://` artwork, decoded synchronously with
ImageIO and kept off the loader, whose retry assumes an `HTTPURLResponse`)
are the two view wrappers; `LogoImageView` adds the fade-in and text fallback
logos need, its fallback showing from the start of the load and crossfading
to the logo (Reduce Motion aware).

Every one renders `MediaPlaceholderBox` (`Shared/Components/`) while loading
or failed: a content-type SF Symbol (`BaseItemKind.placeholderSystemImage`:
`film`, `tv`, `person.fill`…) tinted `.dionysusHighlight`, never a spinner or
blank box. The glyph shimmers (the `SwiftUI-Shimmer` package's `.shimmering()`, on the
glyph only) while the
fetch is outstanding and settles once it has failed or there's nothing to
fetch (`isSettled`; Reduce Motion aware). **A new image site passes a
`placeholderSystemImage` that matches its content.** On tvOS the glyph
scales with its tile (`MediaPlaceholderBox.tvGlyphSize`, about a fifth of the
shorter side, at least 28pt), since a fixed 28pt was
too small to read across a room. The Apple TV grid draws the same box over
its UIKit posters (`TVPosterOverlay`).

### Playback (`Core/Playback/`)

`PlaybackEngine` is a protocol wrapping AetherEngine, so feature code never
depends on it directly: `AetherPlaybackEngine` is the adapter,
`PreviewPlaybackEngine` (`#if DEBUG`) the fake for previews and UI tests.
**When changing playback behaviour, change the protocol and both
conformers**; `PlayerViewModel` only talks to the protocol. Picture in
Picture, Now Playing, stop reporting, the whole subtitle pipeline and Night
Mode (its schedule, what it trades, the dimming layer) are in
`DionysusPlayer/Core/Playback/CLAUDE.md`.

### Features (`Features/*`)

Each feature folder is a vertical slice: a SwiftUI `View` and an
`@Observable @MainActor` view model that owns a `JellyfinAPIClient` and
exposes a `LoadState`-style enum (`idle`/`loading`/`loaded`/`failed`). **View
models take an already-resolved `client` and `userID`** (see
`HomeViewModel.init`), never `AppState`.

What Home's rails select is a placeholder per the view models' doc comments;
don't over-invest in curation without checking whether it's being redesigned.
The Recently Added rails ask `/Items/Latest` of the first Movies and TV Shows
library only, and are skipped when there is none: unscoped, Latest answers
from every library, music and books included.

`CollectionGridView`/`CollectionGridViewModel` (the Movies, Shows and
Collections grids) combine a server-side sort (field and direction,
refetched on change; Date Added on a grid of shows is its newest episode's,
`DateLastContentAdded`, not the show's own `DateCreated`) with client-side filtering over five facets: Genre,
Studio (labelled "Network" for Series queries; Jellyfin keeps a show's network
in `Studios`), Decade, Watched and Favorites. Favorites and Watched are
`Optional` selections, so they can filter *out* too. **The facets cascade**:
each facet's options come from `items` with every *other* active facet applied,
never itself (`matchingItems`), so no combination offered can funnel to zero
results. A new facet follows the same "exclude yourself, apply the rest"
shape.

### Versions (#289)

**A title can have several Jellyfin versions (`MediaSources`: 4K and 1080p,
a Director's Cut), and whether a play asks which is decided by the title's
resume point, never by the button**. Resume and Restart
are one title in two starts, so asking on one and not the other read as
arbitrary. The rule is `MediaVersionChoice`, the pure part, and
`MediaVersionResolver`, which applies it to a session:

- Fewer than two versions never asks. With a resume point and a remembered
  version still listed (`MediaVersionPreferenceStore`), Resume and Restart both
  play it silently; with a resume point and nothing remembered (or the pick
  gone) it asks once and remembers the answer. With no resume point, Play asks
  and marks the remembered one "(Last Played)". Row plays (episode, collection
  and playlist rows, the Apple TV's hero) follow the same rule.
- **Auto-advance never makes the user wait for nothing.** A single version
  plays; otherwise the remembered pick; otherwise the item just played's own
  label ("4K HDR10") if the next one has it; otherwise it asks. A version it
  carries on is remembered as if chosen, on both platforms, so a later Resume
  of that episode doesn't ask about the version it was watched in. On iOS the
  question waits on the page once the player closes; on the Apple TV it is
  shown over the player, where Menu closes the player.
- **`dionysus://` play links never ask**: they exist for tests and debugging,
  so `source=`, else the remembered pick, else the server's default. The Top
  Shelf's play links carry `from=topshelf` and follow the page's rule on the
  Apple TV; iOS ignores it (`AssetDetailViewModel.linkVersionDecision`).
- **iOS asks with a `confirmationDialog`** (`VersionChoiceDialog`); the Apple
  TV with a full-screen page, since a tvOS dialog's buttons can't be given
  identifiers and its focus can't be placed (`DionysusTV/CLAUDE.md`, "Versions
  (#289)"). Playback Stats' Version row and a download's Details show which
  version a session or file is.
- **Downloads ask differently** (iOS; `DOWNLOADS.md`): a single download always
  asks with two or more versions, before the audio prompt; a season scans
  every episode first and asks once if they share the same versions, else per
  episode. A download isn't a resume, so neither saves a playback preference.
  A collection's bulk download doesn't exist yet (#468).

### Deleting a season

**A season with no folder of its own can't be deleted as a unit, by anyone.**
Jellyfin's `BaseItem.CanDelete()` is `IsFileProtocol`, and a show whose
episodes sit loose in its folder (no `Season NN/`) gets made-up seasons:
`LocationType: Virtual`, no path, `CanDelete: false` even for an admin,
`DELETE /Items/{season}` refused. A real library was shaped like this
(checked on Jellyfin 12.2). So for such a season the Delete menu fetches its
episodes with `CanDelete` (`AssetDetailViewModel.loadSeasonDeletability`),
offers Delete Season when every episode with a file is deletable, and deletes
them one at a time, stopping at the first failure with "Deleted N of M".
`LibraryManager.DeleteItem` leaves the emptied season listed until a library
scan, so the page drops it itself. A season with a folder is one request.

**All Watched deletes a show's watched episodes** (#437; iOS and Apple TV),
last in the Delete submenu below its own divider.
`AssetDetailViewModel.loadWatchedEpisodes()` reads the whole show's episodes
with `CanDelete` as the page loads and after playback, a Watched toggle or a
deletion. Watched is `Played`; a resume point isn't, and a missing episode
(`Virtual`) counts in neither number. It's offered only when every watched
episode is deletable. The confirmation gives both counts and says the
episodes go **for all users** (Watched is per user, the file isn't), and
exactly the episodes it counted are deleted, through the folderless season's
one-at-a-time path. Seasons it empties leave the page, and emptying the show
pops off it. Both menus work from `AssetActionTargets.deleteRequests`.
**Either one-at-a-time deletion can stop partway** (#491):
`PartialDeletionError` says "Deleted N of M", carries the ids that went (iOS
removes just their downloads when asked to) and the page is settled as a
full run would leave it, except that a page whose own subject went pops only
once the alert is closed. With nothing left, the confirmation says "No
episodes will remain", never that the show will be removed: missing episodes
or a kept folder can leave it listed.

### Transient confirmations (`Shared/Components/Toast.swift`)

`ToastCenter.shared.post(Toast(message:))` shows a brief self-dismissing
capsule, rendered by one `ToastHost` overlay in `MainTabView` (on the Apple
TV, `TVMainView`) so it outlives whatever raised it (adding to a playlist
dismisses its own sheet in the same frame). **Use it for "that worked" on an action whose own UI has already
gone**, not as a notification channel: only a tap or its timer dismisses it,
and a second post replaces the first. A haptic may go with it, never instead
of it. Posting also makes a VoiceOver announcement.

### Playlist editing, and what Jellyfin actually gates

The app adds items to a playlist (`AssetActionsButton` →
`AddToPlaylistSheet`; on the Apple TV, More Actions →
`TVAddToPlaylistPage`, both on `AddToPlaylistViewModel`) and removes them
(`PlaylistItemList`'s long-press menu, iOS only). From `PlaylistsController.cs`/`PlaylistManager.cs`, cross-checked with
`jellyfin-web`:

- **Creating a playlist has no permission gate.** `POST /Playlists` is
  `[Authorize]` only (`EnableCollectionManagement` governs collections), so
  "Add to Playlist" always shows and the toolbar's `ellipsis` overflow is
  never empty. Don't add a check. (The overflow is drawn for everyone, since
  `CanDelete` arrives only with the full item, and swapping a bar button for a
  menu on iOS 26 blanks the toolbar group; see `AssetActionsButton`.)
- **Adding to and removing from an existing playlist share one gate**: owner,
  or a share with `CanEdit`, refused as a clean 403. Nothing exposes
  `OwnerUserId` and there's no bulk query, so it's one
  `GET /Playlists/{id}/Users/{me}` per playlist, as `jellyfin-web` does;
  `editablePlaylists` caps the concurrency and fails soft per check.
- **Posting a Series or Season id adds every episode beneath it** in one
  request (`Playlist.GetPlaylistItems` expands folders). "Add the whole show"
  sends the show's own id, never a client-side list of episodes.

`CreatePlaylistDto.IsPublic` defaults to **`true`** server-side, so
`CreatePlaylistRequest.isPublic` is non-optional and always encoded;
omitting it publishes the playlist to every user. New playlists are private,
as in `jellyfin-web`.

### iPhone Duo: the fold

The foldable's fold is read from the `.division` reserved region (iOS 27.1,
gated: the floor is 18) through `ActiveFold` (`Shared/Components/`), which
rounds it to whole points. **Read it from a view whose position doesn't
depend on it**: a view moved by the fold it measures loops (measured: 98% CPU
on a black screen), so read it on the outer frame, after any padding it
drives. Six layouts use it:

- **The player** (`PlayerFoldLayout`; `Core/Playback/CLAUDE.md`): tabletop
  puts the picture above the fold and every control below; book pose moves
  the transport to the trailing page.
- **Detail pages, held wide** (`DetailBookSpread`), partly folded *or* fully
  open and flat: the poster fills the leading page (`MediaItem.posterImageURL`,
  the series poster for an episode, no logo), or the backdrop with the logo
  when there's no poster; the content scrolls on the trailing page, and
  `HeroHeaderView` steps aside. Held tall the page keeps its hero. Favourite
  and Watched sit in the vertical side bar there (`.duoVerticalPreferred()`
  on their toolbar item), stacked, rather than floating over the content.
- **Centred states** (`.centredClearOfTheFold()`: Search's empty, loading,
  offline and error states, Home's, and the empty Downloads tab): on the
  trailing page in book pose, in the top half in tabletop, Apple's
  "displacement". Lists and grids scroll through the fold and never move.
- **Home's hero** (`HeroFoldLayout`), in tabletop only: it ends at the fold
  and the rows start their usual spacing past it, so the fold sits in the gap.
  Ended at the fold alone, the library row moved up onto it.
- **Sign-in** (`OnboardingFoldSplit`, in `OnboardingScreen`): the header
  ("Who's Watching?", the server line) on one side of the fold and the user
  picker on the other: leading and trailing pages held wide, above and below
  held tall. Read with inactive folds too, like the detail spread, so it
  lines up with the crease open and flat as well. Centred, a tile straddled
  the fold in book and "Change Server" sat on it in tabletop.
- **The collection grids' filter pills and posters**, in book pose only:
  a pill that would cross the fold starts past it (`FoldGapHStack`), and the
  columns split around it (`PosterGridMetrics(…, foldGap:)`), every poster
  the trailing page's width, so the gutter at the fold is wider than the
  rest (the side bar narrows that page). Open and flat both go back to the
  plain row and grid: content may cross a flat fold. Favorites and a column
  of posters straddled it.

**Regular width doesn't mean an iPad's top bar.** The inner display is
regular width, but its tab bar sits at the bottom held tall and at the foot of
the vertical side bar held wide (`tabBarPlacement` reads `.bottomBar` for
both; an iPad, `.topBar`). Anything that assumes the bar floats over the
content at the top asks `tabBarPlacement`, as Home's hero tint does
(`TabBarTintModel.isBarOverHero`). Where the bars are vertical the status bar
is in the side bar too, so the hero's top shade (`HeroScrollEdgeScrim`) is
left out there, and so is its forced dark bar scheme: a scheme colours the
whole side bar, only part of which is over the hero, so the system's glass
picks per item instead. Every other bar keeps both.
Heroes' backdrops reach past the horizontal safe area (the side bar's column
on the closed Duo) while logos stay centred inside it
(`BackdropLogoOverlay.backdrop`); Home's page dots and VoiceOver's
Previous/Next move in from the side bar's edge
(`clearOfTheVerticalBar(safeArea:)`, given `HomeView`'s safe area, since the
hero's own reads 0 at the sides).

**Every toolbar button has a symbol and a title, and shows its title on a
horizontal bar**: `Button("Select", systemImage: "checkmark.circle", …)`
with `.toolbarTitleUnlessVertical()`. Held wide, the Duo's bars merge into the
vertical side bar, which shows symbols only; a text-only item (or one styled
`.titleOnly` everywhere) stays behind in a horizontal bar of its own
(measured, 2026-10-27). Elsewhere the words stay, since "Select" or "Cancel"
says more than a glyph.

### Navigation (`Shared/Navigation/`)

One `AppRoute` enum (`collection`, `assetDetail`, `downloadedAsset`,
`downloadedShow`, `downloadedSeason`) is the `navigationDestination(for:)`
type across `MainTabView`'s four tabs. Home, Search and Downloads each own a
`NavigationStack`; Profile owns its own container, a `NavigationSplitView` on
iPad and the Duo's inner display held wide (`SettingsLayout.usesSplitLayout`:
both size classes regular *and* at least 700pt wide, so the 669pt inner
display held tall gets the one list). A new destination is a case in
`AppRoute` and a branch in `AppRouteDestinationView`, not a per-feature
navigation type.

### Deep links (`Core/DeepLinks/`, #406)

`dionysus://` links open any place, title or playback, on both apps, for
debugging and UI tests (`xcrun simctl openurl booted 'dionysus://play/<id>'`).
**They're an API-only capability: nothing in the app makes, copies or shares
one**, and they navigate and play, never change data.
Every link, parameter and fallback is listed in `TESTING.md`, "Deep links
for debugging and tests"; the Top Shelf's links are two of them and must
keep parsing. **A new destination or parameter updates that table in the
same change**, with a parser test and a journey per platform.

- `DeepLink` parses and builds (pure, shared with the Top Shelf extension);
  `DeepLinkRouter` decides against the session. How each kind of link behaves
  is in `DionysusPlayer/Core/DeepLinks/CLAUDE.md`.
- **A link arriving mid-playback closes the player through
  `PlayerCloseRequest`**, which runs its close button's teardown and reports
  the stop; dismissing the cover from outside would skip that.
- **Quick Connect's code is filled in, never submitted**: approving signs a
  device in. **`mode`, `bitrate` and `server?url=` are DEBUG-only**; Release
  builds don't parse them.
- `Scripts/deeplink.sh '<link>' [udid]` opens one on a Simulator by hand;
  journeys that need the warm path use `XCUIDevice.shared.system.open`
  (`XCUIApplication.open` cold-launches).

### Models (`Core/Models/`)

Jellyfin DTOs (`JellyfinModels.swift`) are mapped into lighter app models
(`MediaItem`, `MediaCollectionRail`), usually through `init(dto:images:)`,
rather than reaching views.

**`BaseItemDto`/`MediaItem` equality is structural, and must stay that
way.** SwiftUI prefers a stored property's own `==` when deciding whether a
view changed, and `MediaItem` is the stored property of nearly every view
(`ForEach(rail.items)` diffs `[MediaItem]`). An id-only `==` tells SwiftUI
nothing under a stable id changed, which is false for `userData` after
playback and for `mediaSources`/`people` when the full fetch replaces a
preloaded item. The symptom is a view frozen on stale data while every layer
below holds the right value; it reads as a timing bug and cost six `.id(...)`
workarounds before the cause was found. `hash(into:)` stays id-only (the
legal direction). See `MediaItem.==`'s doc comment.

### Localization

User-facing strings go through a String Catalog
(`DionysusPlayer/Resources/Localizable.xcstrings`); only English is populated,
and a vendor can add languages later with no code change.

- In SwiftUI views, write plain literals to `Text`/`Button`/`Label`/
  `Section`/`.navigationTitle`, whose `LocalizedStringKey` overload Xcode
  extracts. That doesn't apply to a computed `String` (`Text(foo ?? "Bar")`)
  or a custom view's `String` parameter.
- Everywhere else (view models, errors, model display strings, those
  `String`-typed cases), wrap the literal in `String(localized: "...")`.

Server or user content (titles, library and people names) and technical terms
or formatted data (codec and HDR names, timecodes, "S1:E4", the app's name)
stay plain; see `MediaItem.swift` and `PlayerControlsOverlay.swift`.

**The catalog is populated only by an Xcode.app build (Cmd+B)**, not by
`xcodebuild`, so CI can never catch a missing string. **Sync it in the same
PR that adds the strings**: open the project in Xcode, build once, and commit
the `Localizable.xcstrings` diff with the change.

## Privacy policy maintenance

`PRIVACY.md` (repo root) is the App Store privacy policy, also shown in-app
from Profile → Privacy Policy (`DionysusPlayer/Resources/PRIVACY.md` is a
symlink to it, as `LICENSE` is). It was written by auditing what the app
actually collects, stores and sends, and nothing checks it against the code.
**Update it in the same PR** as any change that adds a stored identifier, a
permission (`NS*UsageDescription`), an SDK or dependency, or a network
destination other than the user's Jellyfin server.

`PrivacyPolicyView` renders it with a small hand-written Markdown renderer
(headers, bold, italic, links, bullets). If a second Markdown document is
bundled, or one needs nested lists, code blocks or tables, switch to a real
Markdown library (e.g. MarkdownUI).

**The privacy manifests are per target**: iOS's
`DionysusPlayer/Resources/PrivacyInfo.xcprivacy`, the Apple TV app's
`DionysusTV/Resources/PrivacyInfo.xcprivacy` and the Top Shelf extension's
`DionysusTVTopShelf/PrivacyInfo.xcprivacy`. A required-reason API
(UserDefaults, disk space, `systemUptime`, file timestamps…) newly used in a
target's code needs an entry in that target's manifest, in the same PR.

**`THIRD-PARTY-NOTICES`** (repo root, symlinked into `Resources/` like
`LICENSE`) holds the notices of every library that ships in the app
(2026-10-13): AetherEngine and what it brings (FFmpeg, dav1d, zimg, libzvbi,
libdovi, LibTrueHD), the native libraries swift-libass vendors and the Swift
packages. A library's notices give where it comes from, its version and its
licence text; the LGPL-2.1 text is given once, under FFmpeg, and libzvbi and
FriBidi point to it. SMBClient isn't there: it comes only with AetherEngine's
`AetherEngineSMB` product, which the app doesn't link. A line `# <name>` starts
each library's notices, and the License page shows each after `LICENSE`
under a heading with that name, on both platforms (`LicenseDocument`,
so it's clear which component a licence refers to).
When a bump brings a new dependency or changes a version, read its licence
and add or update its notices there too, under its own `# <name>` line
(`LicenseDocumentTests` lists the libraries it expects).

## Store screenshots

`store-screenshots/` holds two copies of the screenshot sets; the workflow
and its traps are in `Scripts/store-screenshots/CLAUDE.md` (and README.md's
"Store screenshots"). Three rules apply anywhere:

- **`store-screenshots/apple-app-store/` is the only copy uploaded to App
  Store Connect**, captured against the App Review server. **Its hostname and
  domain never go in the repo**, only in App Store Connect and local notes.
  `store-screenshots/demo-jellyfin-org/` (the demo server) is for README.md
  only: that server isn't all public domain.
- **Never a personal server**, and never fake HDR: neither server has HDR
  content, so a slide names the capability rather than showing it.
- **No alpha channel**: App Store Connect rejects one.

## Commit messages and pull request descriptions

**Never include a Claude session URL (`https://claude.ai/code/session_...`)
in a commit message or PR description**, including as a `Claude-Session:`
trailer: it means nothing to a reader and leaks a private session's id into
permanent history. Keep `Co-Authored-By: Claude ...` on commits and the
"Generated with Claude Code" line on PRs. This overrides any per-session
instruction asking for the trailer.
