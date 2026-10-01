# Dionysus for Apple TV — design

Status: approved design (prototype signed off 2026-09-29), spike complete.
Prototype canvas: https://claude.ai/artifact/Wjp3J4eh4VGqMmmR7ntAKL (private).
Spike branch: `spike/tvos-poc` (throwaway, never merged).

## Goal

A native tvOS app with a TV-specific UI on the iOS app's shared core. It should match commercial-grade apps (the Apple TV app, Disney+, Netflix) and Jellyfin/Plex clients, stay close to the HIG, keep the iOS app's UX, information architecture and branding, and treat **Infuse as the gold standard for playback**: smooth, responsive scrubbing, frame-rate and dynamic-range matching, fast startup, and honest format reporting.

## Decisions

| Area | Decision |
|---|---|
| Deployment floor | tvOS 26.0. AetherEngine allows 18, but 26 gives Liquid Glass and the tvOS 26 sidebar with no `#available` forks. Swiftfin and Sodalite also target 26. |
| Bundle ID | `com.imbenjamin.dionysusplayer`, the same as iOS (Universal Purchase). |
| Code sharing | A separate `DionysusTV` target compiles the iOS app's `Core/`, `App/AppState.swift`, selected `Shared/` files and every `Features/**/*ViewModel.swift`. TV views live under `DionysusTV/`. |
| Downloads | Absent on tvOS. `Core/Downloads` isn't compiled; shared code guards its download paths with the `DOWNLOADS` Swift compilation condition, which only the iOS app and its unit tests define. |
| Navigation | A left sidebar (`TabView` + `.sidebarAdaptable`) with **Home, Search, the user's libraries, and Profile**. More than 5 libraries fold into one expandable **Libraries** entry. Profile is the only way to Settings. |
| Profiles | Follow the tvOS user ("Runs as Current User", `com.apple.developer.user-management`). Each tvOS user keeps their own Jellyfin sign-in. |
| Appearance | Dark only. Onboarding is always dark, in the iPad landscape composition: brand pane on the left, task on the right. |
| Player host | AetherEngine's recommended tvOS pattern, which Sodalite uses: an `AVPlayerViewController` subclass with AVKit's chrome and gestures switched off, our own SwiftUI transport, `AetherPlayerView` in `contentOverlayView` **only on the software route**, presented with UIKit `present(_:animated:)`, never `fullScreenCover`. |
| Priorities | Core app and playback, **HDR included**, come first. Now Playing / Control Center is deferred to a later milestone. |

## Screens

These are the canvas screens (numbers as on the canvas), with the design calls recorded against them:

1. Welcome: the iOS feature lines, with the Downloads line replaced by one about Apple TV profiles.
2. Find Your Server: scanning starts automatically. The first found server takes default focus.
3. Who's Watching?: circular user lockups.
4. Quick Connect: the primary sign-in route. "Use Password" is secondary, using the Continuity Keyboard.
5. Home: a full-bleed hero, then rails in the iOS order.
6. Sidebar: Home, Search, the libraries and Profile. 6b shows the Libraries group used when there are more than 5.
7–8. Movie and show detail: Play/Resume, Restart, Watched (**eye icon**, never a tick), Favorite, and More.
9. Collection grid: the five cascading filter pills plus an **alphabet jump bar**.
10. Search: the system `.searchable` layout, with Recent Searches.
11. Profile (settings): the iOS sections minus Downloads, 3D Depth Effects and Theme, plus Switch User.
12–15. Player:
    - The **content logo (title text fallback) top-left over a dark fade**; episodes add "S1:E3 · Title".
    - A glass transport with chapter ticks and trickplay.
    - The **chapter/format row**, including the HDR format label.
    - Swipe down for the Info / Chapters / Audio / Subtitles / Stats tabs.
    - Skip Intro/Credits.
    - A compact Next Up card: thumbnail, seconds countdown plus bar, episode and title, Play Now / Close.

Tiles carry iOS's corner badges (`PosterCard.watchStatusOverlay`): a heart top-left, an eye top-right, and a progress bar while an item is part-watched.

## Spike findings (evidence on an Apple TV 4K, 3rd gen, tvOS 27)

**Proven**

- The shared core runs unchanged on tvOS, with the seams above; iOS unit tests stay green (1,156 tests).
- UDP discovery, sign-in and Keychain restore work on the device.
- Home scrolls smoothly and card focus works.
- Playback works on the native route (H.264, HEVC HDR10/HDR10+/DV) and the software route (AV1), and the frame-rate switch happens.
- Remote presses reach our code with AVKit's gestures switched off.
- Startup takes 0.7–1.9s, 3–4s with a TV mode switch, and 0.3s on the software route.

**Bugs the real build must avoid**

- **The engine's view must be hidden on the native route.** Left in place, it covers AVKit's video: sound, no picture.
- **Home's first load can be cancelled** by a tab rebuild, which leaves `.loading` behind so `loadIfNeeded()` then skips it.
- **Default focus needs explicit `defaultFocus`**, and plain `.borderless` avatar buttons show no focus.
- **A series in the hero needs its Play to resolve an episode.**

**Open**

- **HDR output.** The TV stays in SDR (EDR headroom 1.00), and the engine reports "source HDR10, display SDR", in both host modes, with both Match Content settings on. Infuse shows HDR on the same box. `AVDisplayManager.isDisplayCriteriaMatchingEnabled` read inconsistently across runs.
- **Now Playing** appears in neither host mode (deferred).
- **Per-user profiles.** The spike built without the User Management capability, so tvOS ran it as the default user for everyone. Milestone 2 adds the entitlement, shares the server configuration across users and keeps each user's sign-in separate. On the device (2026-09-30) the separation works, but tvOS often launches the app in the wrong user's container: a known system bug (Firecore's "User Switching Broken (tvOS 26.4)" thread), recurring on tvOS 27. The app therefore also remembers the accounts signed in on this Apple TV and switches between them in one press (M2 plan, Task 7).
- **Session loss after a reinstall: explained and fixed.** The server configuration lived in `UserDefaults`, which a reinstall erases, while the credentials survived in the Keychain. It now lives in the Keychain too; a reinstall on the Simulator returns straight to Home (2026-09-30).

**Design finding:** the tvOS 26 `TabView` sidebar collapses to a "‹ Home" pill, not the icon rail in the prototype, and its open list looks nothing like screens 6 and 6b. Reviewed and rejected by Benjamin on 2026-09-30: the sidebar is a custom component matching the prototype, with Profile pinned at the top (M2 plan, Task 6b). Refined on 2026-10-01: the collapsed rail is on every signed-in page, each library is a page beside it rather than a full-screen one, and Left or Menu opens the rail on the current page's row. M3's details page will sit beside the rail too, with Menu popping it first.

## Non-goals (for now)

Downloads/offline, music (still suppressed app-wide), Top Shelf, and PiP on the software route (tvOS AVKit doesn't support it).

## Milestones

1. Foundation and core playback, including HDR: `docs/superpowers/plans/2026-09-29-tvos-foundation-and-playback.md`
2. Onboarding, shell and profiles: onboarding, the sidebar with libraries, per-tvOS-user sessions, in-app account switching and the Follow Apple TV Users setting: `docs/superpowers/plans/2026-09-30-tvos-onboarding-shell-and-profiles.md` (in progress; PRs #278, #279, #280 for the icon, and the sidebar next).
3. Browse: Home, detail pages, collection grid with alphabet bar, Search, Profile/Settings. As on iOS, every tile on Home, a collection grid or Search opens a detail page, never playback directly; M2's library grid playing movies and episodes on Select is a stopgap until then (Benjamin, 2026-09-30).
4. Playback features: tracks, libass subtitles, skip segments, Next Up, trickplay, stats, the swipe-down tabs.
5. Now Playing, Top Shelf, release pipeline (tvOS archive and upload), store assets, docs.

Each later milestone gets its own plan when it starts.
