# tvOS M6: Now Playing, Top Shelf and release

Milestone 6 of `docs/superpowers/specs/2026-09-29-tvos-app-design.md`. Agreed
with Benjamin on 2026-10-14.

## Goal

Ship the Apple TV app: into TestFlight, then the App Store, under Universal
Purchase, through the same one-tag-push flow as iOS (`VERSIONING.md`). Done
means a tag produces both builds, and the TV app goes to review with working
Now Playing, a content-rich Top Shelf and its own store assets. iOS's
behaviour doesn't change, apart from the one shared Now Playing addition below.

Order (Benjamin): Now Playing, then Top Shelf, then the release pipeline, then
store assets. Top Shelf is in the MVP, so the parent spec's Non-goals line
for it goes.

## 1. Now Playing

**Found on the Bedroom Apple TV (2026-10-14):** tvOS 27's Control Center shows
no Now Playing tile for a video app at all, Infuse included. Now Playing
surfaces on a paired iPhone (Lock Screen card, Apple TV Remote). Before M6 ours
showed nothing there beyond a title stamped too late.

**Approach (Sodalite's, approved by Benjamin as a reversible change):** AVKit
owns Now Playing. The engine stays `ownsNowPlayingSession: false` (an app
`MPNowPlayingSession` conflicts with AVKit's, CoreMediaErrorDomain -16046, and
`updatesNowPlayingInfoCenter` doesn't exist on tvOS). `setNowPlayingInfo`
stages title, second line and artwork as the item's `externalMetadata`
through the engine before `load()` (`NowPlayingMetadata`), replacing the
host's title-only stamp. AVKit publishes while the player is still waiting to
play and not again, which froze the iPhone's progress bar, so the metadata is
staged again each time playback settles into `.playing`
(`AVKitNowPlayingRepublisher`). Result on device: title, year · runtime (or
`S1:E4 · Name`), artwork, play/pause, ±10s and scrubbing, with a moving bar,
matching Infuse.

**The software route** (AV1, VP9, legacy sources) has no AVPlayer, so no Now
Playing. Not addressed in M6: Sodalite found manual `MPNowPlayingInfoCenter`
writes crash beside AVKit, those titles are rare, and nothing on Bedroom
exercises the route. Left as a known gap.

**Tests:** unit tests for the metadata items and the republisher; the iPhone
card checked by hand on Bedroom.

## 2. Top Shelf

### The extension

A TV Services extension, `DionysusTVTopShelf`
(`com.imbenjamin.dionysusplayer.topshelf`), embedded in `DionysusTV`. It
compiles the networking client, the models and the session/keychain stores,
never AetherEngine or UI, to stay inside an extension's memory limit. It
fetches live (Benjamin, 2026-10-14, over an app-written snapshot that goes
stale whenever something is watched elsewhere).

**It reads a session the app mirrors for it, the last-used profile's**
(Benjamin, 2026-10-14, after the spike below). The extension can't see the
current Apple TV profile's keychain, so the app copies what the extension
needs (server URL and id, user id, token, and the app's Jellyfin device id)
into one item in the user-independent keychain (`KeychainStore` scope
`.allUsers`) whenever it is used: on launch and foreground with a session, on
sign-in, Quick Connect and account switch, and deletes it on sign-out. The
shelf therefore shows whoever last used Dionysus; after a profile switch it
shows the previous person's rows until Dionysus is opened. The device id
travels with the token because a token presented with another device id risks
Jellyfin rebinding or revoking the session, and `DeviceIdentity` lives in the
app's own `UserDefaults`, which the extension can't read.

### Step 0: spike findings (2026-10-14)

A throwaway extension, on the tvOS 27 Simulator and on Bedroom (tvOS 27) with
two Apple TV profiles: Ben (the default) and Tara, each signed in to Dionysus
as themselves.

- **The extension reads the default profile's keychain, not the current
  one's.** On Tara's profile a provably fresh run read Ben's
  `server.credentials`, both with and without
  `runs-as-current-user-with-user-independent-keychain` on the extension.
  `TVUserManager.currentUserIdentifier` is deprecated since tvOS 16 ("no
  longer supported"), so nothing tells the extension who is watching.
  Sodalite's extension assumes per-user reads; nothing in its issues shows a
  multi-profile check.
- **The user-independent keychain is shared:** the server configuration the
  app writes there reads fine from the extension, with both listing
  `$(AppIdentifierPrefix)com.imbenjamin.dionysusplayer` in
  `keychain-access-groups`. Items written before the group existed are found.
- **The app's `UserDefaults` aren't visible** (`device.identifier` reads nil):
  the extension has its own container.
- **The Simulator can't answer per-user questions:** it has no profile at all
  and refuses additional ones ("not supported on the simulator").
- **Build traps:** Xcode links a `tv-app-extension` with `-e _TVExtensionMain`;
  the `TVTopShelfContentProvider` API needs `OTHER_LDFLAGS: -e
  _NSExtensionMain` (as Sodalite), or the extension exits at launch and the
  shelf shows the static image. The `async` `loadTopShelfContent()` override
  doesn't compile under Swift 6 (non-Sendable return); the completion-handler
  override does.
- **Layout:** neither carousel style draws any text over a third-party
  shelf on tvOS 27, full screen or not: `.details` shows the bare image,
  `.actions` adds only Play and More Info (Simulator, 2026-10-14). So the art
  has to say what the title is (Content, below).
- **Corrected 2026-10-14:** the spike's "a `file://` image from the
  extension's own temporary directory doesn't show on device" is unproven:
  that render drew with UIKit, which is what killed the extension on Bedroom
  (see Content). Use the App Group, as Sodalite does, until a device check
  says otherwise.

### Content

`TVTopShelfCarouselContent(style: .actions)`: its Play and More Info buttons
are the two deep links (below), and neither style draws text on tvOS 27. No
preview video (it needs a stream URL the system fetches without auth, and few
libraries have trailers).

- **Items** (Benjamin, 2026-10-14): the **first 3 Continue Watching** items
  (`MediaTypes=Video`, as Home), then Next Up episodes not already shown, then
  Recently Added to fill the remaining places, up to 10 in all (Apple's
  guidance checked during planning). A show appears once; a title with no
  backdrop anywhere up its chain is left out.
- **The art says what it is** (Benjamin, 2026-10-14): the extension draws the
  title's logo (an episode's show's; the name in bold when there is none),
  the context line ("Continue Watching", "Next Up · S2:E4 · Episode title",
  "Recently Added") and, for Continue Watching, the time left ("1h 45m
  remaining", Home's form, instead of a progress bar) over the backdrop. The
  block sits left of centre, clear of full screen's left arrow and Play/More
  Info and above the compact shelf's dock. Summary, genres, year, running
  time, cast and media options are still set on the item, though tvOS 27
  doesn't draw them.
- **Drawing within the extension's limits** (Bedroom, 2026-10-14): about
  21MB free before the backdrop downloads, 17MB after. A UIKit render died
  at its first draw every time, so the renderer is Core Graphics and Core
  Text only, draws at 1280 wide (1920 died every time; Benjamin judged 1280
  sharp enough), one item at a time within a 6s budget, and writes JPEGs to
  the App Group (`group.com.imbenjamin.dionysusplayer`), cached by what's
  drawn. An item not drawn in time keeps its plain backdrop for that load; one
  whose render killed the extension keeps it from then on, and the load after
  a death draws nothing new. Verified on Bedroom 2026-10-14.
- **Signed out, server unreachable or any error:** no content, so tvOS shows
  the static Top Shelf image. Requests use a short timeout.

**Kept fresh:** besides tvOS's own schedule, the app calls
`TVTopShelfContentProvider.topShelfContentDidChange()` when a playback
session ends, on sign-in, sign-out and account switch, and when Watched is
toggled.

### Deep links

A `dionysus` URL scheme, tvOS only:

- `dionysus://item/<id>?server=<serverID>` (the display action, selecting the
  backdrop): drops the current path and pushes the title's detail page over
  Home.
- `dionysus://play/<id>?server=<serverID>` (the play action, Play/Pause on
  the remote): the same, then plays from the resume point over the page, as
  the hero's Play does, so Menu lands on the detail page (Benjamin,
  2026-10-14). Selecting a tile still never starts playback.
- A link for another server, or arriving signed out, opens the app as usual
  and is ignored. A play link while a player is up closes it (reporting the
  stop) and starts the new one. On a cold launch the link waits until the
  session is restored.

### Tests

- **Unit:** a pure `TopShelfContentBuilder` (DTOs to item descriptions:
  order, the 3-item cap, de-duplication, fill, context text, media options),
  the link parser and the router (server check, waiting for the session).
- **UI journeys:** `XCUIApplication.open(url)` against the stub server: an
  item link lands on the detail page; a play link opens the player and Menu
  returns to the page.
- **By hand:** the shelf on the Simulator, then on Bedroom.

## 3. Interim device pass

Before any release work (Benjamin, 2026-10-14): on the Bedroom Apple TV, Now
Playing (Siri Remote, the TV button's Control Center) on the native and, if a
title allows, software route, Next Up changing the card, and the Top Shelf:
content follows the last-used profile (and switches once Dionysus is opened on another), both actions from a cold and a warm app, refresh
after watching. Fixes land before the pipeline PR.

## 4. Release pipeline

**Signing:** two new manually named profiles, as iOS's:
"Dionysus tvOS App Store" (tvOS, `com.imbenjamin.dionysusplayer`) and
"Dionysus Top Shelf App Store" (tvOS, the extension's new App ID with
keychain sharing). Each target's Release config names its profile in
`project.yml`; `Config/ExportOptions-tvOS.plist` names both, with iOS's
load-bearing keys (`manageAppVersionAndBuildNumber` false, symbols uploaded).
A capability added to the shared App ID invalidates the iOS profile
(`VERSIONING.md`), so it is re-saved in the same pass.

**Portal chores**, done through the App Store Connect API (Benjamin,
2026-10-14), each announced before it runs: add the tvOS platform to the app
record, create the extension's App ID, create both profiles, re-save the iOS
profile.

**`release.yml`:**

- The UI-test gate adds tvOS smoke beside iOS.
- A new `tvos-release` job runs beside the iOS one on the same stamped tag:
  `TVUnitTests`, archive `DionysusTV` (extension embedded), export, upload
  with `app-type: appletvos`, artifacts and dSYMs. Missing credentials skip
  with a warning, as iOS.
- The GitHub Release moves to a final `publish` job needing both, so GitHub
  shows a release only when both platforms shipped. An upload can't be
  undone: if iOS lands and tvOS fails, re-run the tvOS job (the shared build
  number is counted per platform in App Store Connect).

**`pr-checks.yml`:** the unsigned Release build adds `DionysusTV`, so a
Release-only break (extension not embedded, a stray `#if DEBUG`) fails on the
PR. A new required check name means updating both rulesets in the same change
(`TESTING.md`); adding the tvOS build as a step of the existing "Release
configuration compiles" job avoids that.

**First run:** an alpha tag (`v1.1.0-alpha.N` or the next free one) proves
the pipeline into TestFlight before any final release.

## 5. Store assets and listing

**Screenshots:** an Apple TV set at 1920×1080 in
`store-screenshots/appstore-appletv/`, captured on the tvOS Simulator against
the demo server and rendered by the existing pipeline: brand gradient and
headline as the iOS sets, the capture scaled in, no device frame (`gen.py`
gains a TV layout). About seven slides: Home's hero, a movie page, a show page
with season tabs, the player with the swipe-down panel (Info, since the demo
server has one track and no chapters), Search, Who's Watching?, and the Top
Shelf on the tvOS Home Screen. HDR and Dolby Vision appear only as captions
about real capability, never faked.

**Listing:** the tvOS version page's description, keywords and promotional
text, drafted from iOS's with its iOS-only lines (downloads, Picture in
Picture) replaced by the TV's (Top Shelf, Apple TV profiles, Siri Remote
scrubbing), shown to Benjamin before anything is uploaded. Age rating and App
Privacy are shared and unchanged.

**Privacy and notices:** the extension talks only to the user's own server
and stores nothing new; `PRIVACY.md` gains a line that Top Shelf shows your
Continue Watching. `THIRD-PARTY-NOTICES` is unchanged (no new library).

## Docs

`DionysusTV/CLAUDE.md` (Now Playing, the extension and its session access,
deep links), `DionysusPlayer/Core/Playback/CLAUDE.md` (Now Playing on both
platforms), `VERSIONING.md` (profiles, the tvOS job, `publish`), `TESTING.md`
(CI), the root `CLAUDE.md` (store screenshots, release), this milestone's line
in the parent spec marked done.

## Pull requests

1. Now Playing.
2. Top Shelf spike: findings only, recorded here.
3. Top Shelf extension and deep links.
4. Interim device pass on Bedroom, with its fixes.
5. Release pipeline, then the alpha tag.
6. Store assets and listing.
7. Final device pass and the whole-milestone review, fixes in a follow-up PR.

## Not in M6

The logo in the Top Shelf; preview videos; sectioned Top Shelf content (rows of
posters); any change on iOS beyond the software-route Now Playing fallback, if
the diagnosis calls for it.
