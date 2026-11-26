# Deep links: how each link behaves

Loaded when working in `Core/DeepLinks/`. The root `CLAUDE.md`, "Deep
links", has the rules; `TESTING.md`, "Deep links for debugging and tests",
lists every link and parameter. This file is how the apps carry them out.

- `DeepLink` parses and builds (pure, shared with the Top Shelf extension);
  `DeepLinkRouter` decides against the session. A link arriving signed out is
  held through sign-in, for 10 minutes at most; one for another server or
  user is refused with a toast (`Toast.notice`), never switched to.
- Each app's root holds the pending link (`RootView`, `TVRootView`);
  `MainTabView` / `TVMainView` apply it. On iOS `DeepLinkNavigation.plan`
  maps a destination to tabs and stacks; a title's page goes on Home's stack.
- **A play link pushes the page and cues it** (`DeepLinkPlaybackCue`): the
  page plays what its own Play would (`AssetDetailViewModel.linkPlaybackRequest`,
  which the Apple TV uses too) with its own player, so the queue, Next Up and
  the refresh on close are the page's usual ones. A playlist queues the rest;
  a collection plays its first title alone; `?playlist=` plays a member from
  the playlist's page; a downloaded title, with `?offline=1` or while
  offline, plays from its download's page (a cue says which, as both pages
  share the item id).
- **A link's start, version, tracks and Playback Stats apply to its one
  session** (`PlaybackLinkOverrides`, through `PlaybackRequest` to
  `PlayerViewModel`): checked once the title has loaded, never written to
  track memory or the version preference, and whatever the title lacks (or
  the link couldn't read) is said in one toast while the rest plays as Play
  would. Tracks are Jellyfin's `MediaStream.Index`, mapped to engine ids as
  the Atmos hint and the ASS sidecars are.
- **A library link finds the library among the user's before anything
  moves** (`DeepLinkLibrary`: the rail's query, seeded with the link's sort
  and facets; music isn't browsable, so not found), then pushes its grid on
  Home's stack. **Profile pages** (`DeepLink.ProfilePage`) open as a pane
  with any sub-page pushed in the split layout, and in the one list as a
  scroll to the section, a push, or the Account sheet. **Quick Connect's
  code is filled in, never submitted**: approving signs a device in.
- **An item link's `season=` and `section=` wait for the page to load**
  (`DeepLinkPageCue` on iOS, `TVLinkedItemOptions` held per pushed page on
  the Apple TV): a show opens on the season (id or number), and the page
  scrolls to the section (Cast & Crew and Details are tabs it opens) or, on
  the Apple TV, focuses its first item, held until it settles since the
  page's own claim and the shell's handoff land after it. What the page
  lacks is said in one toast; the Apple TV's pages have no chapters.
- **DEBUG builds only: `mode`, `bitrate` and `server?url=`.** A play
  link's `mode=direct|transcode` and `bitrate=<bps>` replace Profile's
  Streaming and Max Bitrate for that one session, retries included
  (`PlaybackLinkOverrides.streaming`); a bitrate alone negotiates
  (Allow Transcoding), and with `mode=direct` it's ignored and said.
  `server?url=` fills server setup's address and opens the field, past the
  welcome, connecting to nothing; it's applied by the root (`RootView`,
  `TVRootView`) and only while no server is set up, since a link never
  forgets one. Release builds don't parse any of the three.
- **A link arriving mid-playback closes the player through
  `PlayerCloseRequest`**, which runs its close button's teardown and reports
  the stop; dismissing the cover from outside would skip that.
- `XCUIApplication.open` relaunches the app with the link (a cold launch), so
  journeys that need the warm path open links with
  `XCUIDevice.shared.system.open` (`DeepLinkJourneyTests`).
  `Scripts/deeplink.sh '<link>' [udid]` opens one on a Simulator by hand.
