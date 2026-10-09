# Dionysus for Apple TV — Milestone 5: Accessibility

Status: design agreed in conversation with Benjamin on 2026-10-08; awaiting his review of this document.
Parent spec: `docs/superpowers/specs/2026-09-29-tvos-app-design.md` (milestone 5).
Player spec: `docs/superpowers/specs/2026-10-06-tvos-player-features-design.md` (the input model this milestone extends).

## Goal

Ship the Apple TV app accessible. Two parts: VoiceOver in the player, which M4's own input model leaves out, and an accessibility pass over every other page.

**Success** is a VoiceOver user who can, on the Apple TV alone: sign in, browse Home and a library, **search for a title and open a result**, open a detail page, play the title, pause, skip, scrub, change audio and subtitles, skip an intro, take or close Next Up, and leave the player, with everything read sensibly along the way. Checked by journeys and audits where XCUITest can see it, and by a manual VoiceOver run on the tvOS 26.5 Simulator and on the Bedroom Apple TV where it can't.

## Decisions (Benjamin, 2026-10-08)

| Area | Decision |
|---|---|
| Player | An **accessible transport mode**, like iOS's: extra buttons, and the transport doesn't hide. Not AVKit's own transport (no software route, no sidecar subtitles or libass, a different product) and not VoiceOver actions on the custom-input player (VoiceOver takes the presses it relies on). |
| Review method | Each page is reviewed with the existing **`apple-design-skill`** (its HIG accessibility audit), not a new project skill, alongside a manual VoiceOver walk and the structural audit. |
| Search | Part of the success measure. |
| Settings in scope | VoiceOver and Switch Control, Reduce Motion, Reduce Transparency, Increase Contrast, Bold Text. tvOS has no Dynamic Type. Contrast stays out of the automated audit, as on iOS. |

## Background

tvOS VoiceOver follows the focus engine: there is no free cursor as on iOS. A swipe moves focus and VoiceOver reads what has it. The player deliberately has nothing focusable (M4: the host's recognizers take every press and `TVPlayerInputModel` decides what it means), so with VoiceOver on there is nothing to land on, and VoiceOver keeps some presses for itself. Nothing in `DionysusTV` reads VoiceOver's state today.

## Part 1: the player's accessible transport

### When it's on

Whenever VoiceOver or Switch Control is running (`UIAccessibility.isVoiceOverRunning || isSwitchControlRunning`, observed through their status notifications), switching live if either is turned on or off mid-playback. XCUITest can't run VoiceOver, so `-UITestAccessibleTransport YES` forces the mode under the UI-test harness (`UITestConfiguration`), as `-UITestDisableControlAutoHide` does for iOS's auto-hide.

### What it looks like

- **The transport never fades by itself**, as iOS's controls don't under VoiceOver; the person hides it (Benjamin, 2026-10-08). Menu closes the panel, then hides the controls, then leaves the player. Hidden, nothing is on screen but the picture and one invisible "Show Player Controls" button holding focus (iOS's VoiceOver name); Select, Up or Down brings the controls back with Play/Pause focused, while Left and Right skip 10s and leave them hidden. Hidden while paused stays hidden, so Menu still reaches Close. Up from the scrubber always lands on Play/Pause, never on whichever icon sits above the knob.
- **The icon row gains four buttons**: back 10s, Play/Pause, forward 10s on its left (`gobackward.10`, `play.fill`/`pause.fill`, `goforward.10`, the glyphs both players share), and Info (`info.circle`, which the remote reaches with Down today) before today's icons: Chapters (when the title has them), Audio, Subtitles, Stats (when its setting is on).
- **The scrubber is one adjustable element**: label the title, value the position and duration worded out ("12 minutes 30 seconds of 1 hour 52 minutes"), increment and decrement step 10s, iOS's `PlayerControlsOverlay` skip step. No scanning in this mode.
- **The swipe-down panel** opens from Chapters, Audio, Subtitles and Info. Its tabs and rows are focusable buttons; the chosen track and current chapter carry `.isSelected`. Menu closes it.
- **Skip Intro/Credits and Next Up** are focusable buttons. Their arrival is announced ("Skip Intro available"; Next Up's title once, never each countdown second). Next Up's Play Now and Close are both focusable buttons (Close is the card's own, M4).
- **Announcements**: play, pause, each 10s skip and a track change post one short announcement. The mid-screen flashes stay as they are.

### How it's built

- `TVPlayerInputModel` gains an `accessibleTransport` flag. While it's set, the reducer ignores the host's recognizer inputs (no swipe gate, no hold scanning, no Select on the drawn focus) and the fade never runs.
- The overlay's controls become ordinary focusable SwiftUI buttons in that mode, each sending the same commands through `TVPlayerCommandRunner`. `PlayerViewModel` and the engine don't change.
- **Measured (2026-10-08, tvOS 26.5 Simulator, VoiceOver on, keyboard-driven remote):** every press (Select, arrows, Up/Down, Menu, the keyboard's Play/Pause) still reached the host's press handlers and recognizers, exactly as with VoiceOver off; so in this mode the recognizers must stand down, or Select fires both our toggle and the focused button. A focusable SwiftUI button in the overlay host takes focus inside the `AVPlayerViewController` once the overlay is interactive and preferred for focus. The Simulator's keyboard path may not match the Siri Remote under VoiceOver, so which presses VoiceOver keeps for itself on hardware is checked in the device pass.
- **First task is a measurement** on the tvOS 26.5 Simulator with VoiceOver on: which remote presses still reach the host's recognizers (Play/Pause in particular), and whether a focusable SwiftUI button inside the `AVPlayerViewController` host takes VoiceOver focus. The result decides whether the remote's Play/Pause still toggles in this mode or only the on-screen button does, and is recorded here and in CLAUDE.md.

## Part 2: the pass over the app

### Method, per page

1. Review with `apple-design-skill`'s HIG accessibility audit and a manual VoiceOver walk on the tvOS 26.5 Simulator (the floor). Findings go in the ledger with the fix or the reason it stays.
2. Fix.
3. Pin the fix. XCUITest can't run VoiceOver, so journeys assert what it would read: labels, values, traits, element order in the tree, and nothing decorative in it.

`AccessibilityAuditTests` grows to every screen it doesn't reach yet: Welcome, Find Your Server, sign-in, the Quick Connect code, Who's Watching?, the open sidebar, a box set, a playlist, a See All grid, Full Details, Recent Searches, the confirmation dialogs, and the player in accessible-transport mode. The audit types and suppressions stay as they are.

### What the pass is expected to find

These are the expected issues, to confirm or rule out per page; the pass is not limited to them.

- **Focus moved by the app.** `tvClaimsFocus`, the claims that hold the rail until they land, `tvMenuReturnsToLanding` and the shell's three-second fallback all move focus by themselves, some repeatedly until it holds. Under VoiceOver each move is spoken. Where a claim re-asserts, VoiceOver must not repeat or jump; this is the area most likely to need real code.
- **Sidebar**: announced as "Sidebar" when it opens; each row says which page it opens; the collapsed rail's single enabled row reads sensibly.
- **Home**: the hero's timer stops under VoiceOver (`TVHeroPager.timerRuns`), as iOS's does; the invisible paging guard right of More Info isn't reachable by VoiceOver, and the hero offers a "Next" accessibility action instead; rail headings carry the header trait.
- **Detail pages**: a logo reads as the title; cast tiles, which do nothing on Select, lose the button trait; season tabs read their selection; Play and badges landing late don't make VoiceOver re-read the header.
- **Library grid**: the UIKit `TVPosterView` cells read title, year and badges; the filter and sort pills read their value ("Genre, Comedy"); the alphabet index is usable.
- **Search**: results announce their count when they land; Recent Searches and Clear read correctly. The keyboard is the system's.
- **Onboarding**: the Quick Connect code is read digit by digit; discovery announces a found server; Who's Watching? lockups read the account and server.
- **Profile**: rows read label and value; pickers and confirmations read their choices.

### Display settings

- **Reduce Motion**: find what's still unguarded (crossfades, the hero's dot fill, the countdown bar).
- **Reduce Transparency**: opaque fallbacks for the glass rail, panels, pills and the player's chrome.
- **Increase Contrast**: secondary text over artwork.
- **Bold Text**: nothing clips or truncates that didn't before.

Checked by screenshot on the Simulator with each setting on, and shown to Benjamin before tests, as for any visual change.

## Testing

- Reducer unit tests for `accessibleTransport`: recognizer inputs ignored, no fade, commands from the buttons.
- Player journeys under `-UITestAccessibleTransport YES`: each button acts, the scrubber adjusts by 10s, the panel opens and changes a track, Skip and Next Up (Play Now and Close) can be operated, Menu closes in order.
- Per page: journeys pinning labels, values, traits and order for what the pass changed; the audit over the new screens.
- Manual: a VoiceOver run of the success journey on the tvOS 26.5 Simulator per PR, and once on the Bedroom Apple TV in the last PR (with Benjamin's OK before deploying).

## PRs

1. Player accessible transport (Part 1).
2. Shell and Home.
3. Detail pages and the library grid.
4. Search and Profile.
5. Onboarding.
6. Display settings, the device pass on Bedroom, closing docs (CLAUDE.md, TESTING.md, the parent spec's milestone line).

## Out of scope

- Contrast, Dynamic Type and text-clipping audit types in the automated audit (as on iOS).
- iOS accessibility changes, except where a shared view model or string changes for tvOS.
- Audio descriptions and closed-caption styling beyond what the subtitle tracks already offer.
- Now Playing and Top Shelf (M6).
