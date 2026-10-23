# Apple TV 1.2.0: App Review and HIG audit

Done 2026-10-22, before the first Apple TV submission. Checked against the
App Store Review Guidelines (as of June 2026) and the tvOS HIG, using the
code on `develop` (`7119c04`), `DionysusTV/CLAUDE.md`, the generated
`Info-tvOS.plist` and entitlements, the brand-assets set, the store listing
(`docs/store/tvos-listing.md`, screenshots in `store-screenshots/appstore-appletv/`)
and what App Store Connect holds for the `TV_OS` 1.2.0 version (read through
the API, not changed).

Fix plan for the high-priority findings:
`docs/superpowers/plans/2026-10-22-tvos-app-store-submission-fixes.md`.

## High: likely to cause a rejection

**H1. The review notes don't tell the reviewer how to get in on an Apple TV
(2.1, Information Needed).** The `TV_OS` version's notes are a copy of the
iOS version's. They give the server and "No password", but on the Apple TV
choosing `demo` opens a **Quick Connect code screen**, not a password field:
the demo server reports `HasPassword: true` and has Quick Connect on
(checked 2026-10-22), so `TVSignInRoute` sends the reviewer to a code they
can't approve. To get in they have to find "Use Password Instead", leave the
field empty and press Sign In. The notes don't say so. They also spend three
paragraphs on Downloads, which the Apple TV app doesn't have, and say the app
has "no discovery feature" while it scans the local network as soon as Find
Your Server appears (a Local Network prompt the reviewer will see). A
reviewer who can't sign in, or who sees notes describing a different app,
answers with "Information Needed".

**H2. The build planned for submission is a beta (2.2, Beta Testing), and
the privacy-policy URL serves the iOS-only policy (5.1.1(i)).** The handoff
named the beta.1 build (861) as the candidate. Its Profile footer reads
"Dionysus Player 1.2.0-beta.1" (`AppVersionInfo.footerText`, from the tag),
and 2.2 says betas belong in TestFlight. Separately, the app's privacy-policy
URL is `…/blob/stable/PRIVACY.md`. `stable` last changed `PRIVACY.md` on
2026-09-01. Everything the policy says about the Apple TV (remembered
accounts, Follow Apple TV Users, the Top Shelf session copy in the shared
keychain) is on `develop` only, so the published policy doesn't describe
the app under review. `VERSIONING.md`'s release flow already fixes both:
promote `develop` to `stable` and tag `v1.2.0` on the merge commit.

**H3. A setting is labelled "(beta)" (2.2).** Profile's section is headed
"Spatial Audio (beta)" on both apps (`TVProfileView.swift:273`,
`ProfileView.swift:507`). Apple rejects under 2.2 for features labelled beta
in a store build. The label was a deliberate call (Benjamin, 2026-10-22,
`Core/Playback/CLAUDE.md`) because of AetherEngine #850: with Spatial Audio
on, the A15 Apple TV stalls on 4K TrueHD remuxes. The caveat needs another
form; dropping it silently isn't the fix.

## Medium: metadata accuracy, worth fixing in the same pass

- **M1. The subtitle says "Your media, online and offline"** (2.3.1). The
  subtitle is set once for the whole app, so the Apple TV page shows it too,
  and the Apple TV has no offline playback. Rarely enforced, but it's an
  inaccurate claim on the page under review. Changing it changes iOS's page
  too. It can be edited only while App Info is editable, and right now the
  App Info state is `WAITING_FOR_REVIEW`: iOS 1.1.0 is waiting for review.
- **M2. The description ends "We know the app still has a few gaps…"**
  ("MORE TO COME"). It invites the reviewer to treat the app as incomplete
  (2.1/2.2), and it adds nothing a buyer needs.

## Low, and HIG polish (not blocking)

- **No tvOS launch screen.** iOS has `LaunchScreen.storyboard`; the Apple TV
  target has neither a launch image nor a storyboard, so launch shows black
  until the first frame. The HIG asks for a launch screen that looks like the
  first screen. Upload validation accepts this (builds 797–861 are `VALID`).
- **Play/Pause on a focused title doesn't play it** (HIG, Remotes). Select
  opens a detail page and Play is one press further on, which is fine;
  Play/Pause on a tile or a detail page's header could start playback the way
  the TV app's does.
- **Playback Stats uses 18pt and 22pt text** (`TVStatsPanel.swift:47,58`),
  below tvOS's 23pt Caption 2 (HIG). The panel is off by default in Release.
- **`LocalNetworkPermission` reads `_NSURLErrorNWPathKey`** from an error's
  `userInfo`. It's a dictionary key, not a private symbol or selector, so
  App Review's static analysis has nothing to match; if the key disappears
  the function returns `false`.
- **Age rating 4+, content rights "doesn't use third-party content".** The
  same answers passed review on iOS, and the notes explain the
  user-owned-server model. Leave them.
- **Keywords include `apple tv`**, which is the platform and earns nothing.
  Harmless.
- **The player screenshot's headline is "Plays what others can't"**, a
  comparative claim, and its subtitle names Dolby Vision, HDR10+, Atmos and
  DTS:X over an SDR frame. Both are allowed: the frame isn't faked
  (root `CLAUDE.md`, "Store screenshots").

## Checked and fine

- **Menu at the root leaves the app** (HIG; a common Apple TV rejection).
  On a page, Menu opens the sidebar; Menu with the sidebar open has no
  handler, so tvOS leaves the app. Onboarding screens have no handler either,
  and sign-in covers close on Menu.
- **Siri Remote only** (2.4.3): no game controller or keyboard needed. Quick
  Connect is first, with a password route always one press away.
- **Icons and Top Shelf** (HIG): layered App Store icon (1280×768) and small
  icon (400×240 @1x/@2x), each with an opaque back layer; Top Shelf Image
  1920×720 and Wide 2320×720 at @1x/@2x; dynamic Top Shelf through the
  extension, no ads.
- **Privacy** (5.1): the policy is in the app (Profile → Privacy Policy) and
  in App Store Connect. The Local Network purpose string is specific and is
  asked for in context (Find Your Server). There's no tracking, ads, analytics
  or third-party SDK, so no ATT. Each target has a privacy manifest
  (UserDefaults, SystemBootTime). `ITSAppUsesNonExemptEncryption` is `false`
  (HTTPS only).
- **Accounts** (5.1.1(v), 4.8): the app creates no accounts (they come from
  the user's own server), so neither in-app deletion nor Sign in with Apple
  applies. Sign Out forgets the account on the Apple TV.
- **Payments** (3.1): none.
- **Software requirements** (2.5): no private APIs or selectors found; the
  UI-test harness and stub server are `#if DEBUG`; no background modes.
  `NSAllowsArbitraryLoads` is explained in the notes.
- **Entitlements**: `user-management` (runs-as-current-user) and the keychain
  group are in the App Store profiles; every Apple TV build since 797 is
  `VALID`, minimum tvOS 26.0.
- **IPv6** (2.5.5): discovery is IPv4-only, so on the review network
  (IPv6-only with NAT64) it finds nothing and the list stays empty; a typed
  hostname goes through `URLSession` and works. `http://demo.jellyfin.org`
  redirects to HTTPS, and `probe` keeps the scheme it landed on.
- **Crashes** (2.1): no crash submissions from TestFlight testers.
- **Age-rating questionnaire**: answered, including the social-media
  questions that became mandatory in September 2026.
- **Accessibility** (HIG): VoiceOver, Switch Control (the accessible
  transport), Reduce Motion, Reduce Transparency, Increase Contrast and Bold
  Text were all handled in M5 (`DionysusTV/CLAUDE.md`, "Accessibility").
