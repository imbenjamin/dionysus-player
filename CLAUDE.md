# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Dionysus Player is a native iOS/iPadOS client for Jellyfin media servers (tvOS/macOS
planned later). It talks to a Jellyfin server over the plain REST/JSON API
(https://api.jellyfin.org/) and plays media via AetherEngine, a third-party
FFmpeg + VideoToolbox playback engine (HDR10/HDR10+/Dolby Vision support), pulled
in as a Swift Package.

**Status: builds clean, playback verified on a physical device.** This was
originally scaffolded without a macOS/Xcode toolchain and expected to need
fixes in `AetherPlaybackEngine.swift`, but as of 2026-08-07 (Xcode 26.5, iOS
26.5 Simulator) `xcodebuild build` for the `DionysusPlayer` scheme succeeds
end-to-end — package resolution (AetherEngine + its FFmpegBuild/SMBClient/
LibDovi dependencies), compilation, and linking all complete with no errors,
and the `DionysusPlayerTests` suite (see `TESTING.md`) passes.
As of 2026-08-12, real playback on a physical device (iPhone 17,1, iOS 26.6)
was confirmed via the "stats for nerds" overlay: Dolby Vision (Profile 8)
source decoded in hardware through VideoToolbox HEVC, EAC3 audio
stream-copied to a 7.1 output, and buffered-duration/size stats updating
live. That covers direct-play HDR video + passthrough audio on one device;
still treat other paths (transcoding, non-Dolby-Vision HDR formats, other
devices, seeking/scrubbing edge cases) as unverified until separately
checked.

**v1.0.0** was tagged from `stable` and submitted for Apple App Review on
2026-09-07 — the app's first final (non-alpha/beta) release. See
`VERSIONING.md` for the tag/promotion mechanics.

**The deployment floor is iOS 18**, raised from 17 on 2026-09-23 to move
AetherEngine from 6.x to 7.x — 7.0.0 raised its own platform floor to iOS 18
and renamed no public symbols, so the floor was the whole cost. v1.0.0 still
supports iOS 17; iOS 17 devices keep that build and stop receiving updates.
Read AetherEngine's floor from `Package.swift` at the tag, never from its
release notes — 7.13.0's notes said "iOS 17" while its manifest said 18.

### tvOS app (in progress)

`DionysusTV` is a separate tvOS target (floor **tvOS 26.0**, same bundle ID as
iOS for Universal Purchase) with its own UI under `DionysusTV/`. It compiles
the iOS app's `Core/`, `App/AppState.swift`, a short list of `Shared/` files
and every `Features/**/*ViewModel.swift` — `project.yml`'s `includes` on the
target is the list. **Downloads don't exist on tvOS**: `Core/Downloads` isn't
compiled, and shared code guards its download paths with `#if DOWNLOADS`, a
compilation condition only `DionysusPlayer` and `DionysusPlayerTests` define.
Shared code that names a Downloads type must sit inside that guard, or the
tvOS build breaks. **The tvOS icon can't be `dionysus.icon`**: actool compiles
no tvOS icon from an Icon Composer file and wants an "App Icon & Top Shelf
Image" brand-assets set instead. That set (`DionysusTV/Resources/TVAssets.xcassets`)
is rendered from `dionysus.icon`'s gradient and glyph by
`Scripts/render-tvos-app-icon.py` (ImageMagick), so re-run it and commit the
result whenever the iOS icon changes. Scheme `DionysusTV`; its unit tests (`DionysusTVTests`,
plan `TVUnitTests`) reuse the shared test files. Design, decisions and
milestones: `docs/superpowers/specs/2026-09-29-tvos-app-design.md`.

**The shell is a custom sidebar, not tvOS's `TabView` one** (`TVMainView`,
`TVSidebar`), because the system sidebar looks nothing like the prototype
(screens 5, 6 and 6b). Collapsed, it's a glass icon rail on the left of
**every signed-in page** (not onboarding, not the player), except Search,
where it slides off the left edge (below). Open (whenever one
of its rows has focus), it's a 520pt glass panel of pill rows, with the page
pushed right and the screen dimmed. Profile is pinned at the top (avatar,
name, server; VoiceOver reads "Profile & Settings"), then Home, Search and
the libraries, which above five sit under one "Libraries" row that starts
open and closes in place
(`TVSidebarLayout.rows(libraries:librariesExpanded:)`). A library load that failed at launch is tried again
whenever the rail takes focus. Library icons come
from Jellyfin's `CollectionType`, the admin's "Content type", never the name.
**Every row but the Libraries group is a top-level page** (Benjamin,
2026-10-01): Profile, Home, Search and each library. Left from a page's
leftmost item, or Menu on a page, opens the rail on that page's row; Menu
with it open has no handler, so tvOS leaves the app. Choosing a row opens its
page, collapses the rail and puts focus on the page's first item. Where the
shell is and which rows can take focus is `TVShellNavigation`, unit-tested.
Every page sits in `TVPageScaffold`: the shell draws the plum glow once
beneath every page (a page drawing its own faded in with it, showing the
window's black for a frame), a page's own background fills the screen behind
the rail, and its content starts right of the
rail (`TVShellMetrics.contentInset`) and is clipped there, except on Home
(`layout: .besideRailScrollingUnder`, Benjamin, 2026-10-05): its rails,
scrolled right, keep drawing under the glass rail instead of vanishing at its
edge, while each rail's first tile still starts at the inset. Lifting the
clip alone wasn't enough: a rail's row ended at the inset, so the lazy stack
tore down a tile scrolled past it once scrolling stopped. Widening the row to
the screen's edge kept tiles built but let tvOS scroll the focused tile under
the sidebar (a content margin and safe-area padding both tried, measured). So
Home's rows keep their bounds and build every tile at once
(`TVRail.buildsEveryTile`, an `HStack`): a rail's ~16 tiles load their
artwork together rather than as they come into view. The clip is visual
only, so no journey can see it; check it by screenshot. The gap beside the
rail is 56pt, what a focused control's shape needs on its left: at 40pt the
system's focus platter around a plain button was sliced off at the clip. Four focus facts
cost a debugging session each:
- **Collapsed, only the page's own row is enabled**
  (`TVShellNavigation.focusableRows`). The rail's focus section spans the
  screen's height, so Left from any height lands on that row, never on the
  nearest one. A folded library's row isn't drawn collapsed, so the Libraries
  row stands in and focus moves on to the library once the panel opens.
- **Each page claims focus itself** (`tvClaimsFocus`): the first item on
  arrival and on each handoff from the sidebar, the remembered one when
  rebuilt after the player. Never with `.defaultFocus`: on Profile it pulled
  every later move back to Switch User, so Change Server couldn't be reached.
- **Handing focus from the sidebar to a page needs the focus system asked.**
  Choosing a row holds the whole rail disabled and calls
  `UIFocusSystem.requestFocusUpdate(to:)` on the window's root; disabling a
  SwiftUI view alone never moved focus. This is what reaches Search's
  keyboard, a UIKit control SwiftUI can't focus. The rail stays held until
  the page reports it has claimed focus (`tvPageClaimedFocus`), also on a
  fresh shell, where tvOS's first focus pass would otherwise open the rail.
  After three seconds with focus nowhere (an empty library), focus goes to
  the page's row, since Menu reaches nothing while nothing has focus. The
  same goes for focus left elsewhere in the rail: holding it sometimes pushes
  focus off the chosen row onto Profile's.
- **Right out of the sidebar returns to the item the page last had**
  (`tvRailReturn`). tvOS by itself picks whatever sits nearest the row it
  leaves, and on Home that is the hero's Play, level with Home's row, however
  far down the rails focus had been. The shell bumps it when focus leaves the
  rail without a row being chosen; the page takes what it had when the rail
  opened, since tvOS's own move lands, and is remembered, first.
- **Each page's content is a focus section**, so Right from any row enters
  it; Profile's buttons are mid-screen, level with no row. Left from
  Search's keyboard stays in the keyboard (it keeps the press at its edge);
  Menu still opens the rail there.

**Only the page on show is built, and the player is laid over it**
(Benjamin, 2026-10-01, since the app is image heavy). Choosing another page
tears the old one down; the shell owns Home's, Search's and each library's
view model, and each page remembers which item had focus, so a page chosen
again comes back as it was. The player is the exception: `TVPlayerPresenter`
presents it over the page, which stays alive beneath, so leaving the player is
immediate, with the scroll position and focus where they were. It refuses a
second player while one is anywhere in the presented chain
(`TVPlayerPresenter.canPresent(over:)`): a second Select on the hero's Play,
landing after its Next Up lookup, stacked two (M3 review). It used to tear
the shell down (`TVPageStack`, removed): the rebuilt page then asked a lazy
grid to focus a tile it hadn't built, and anything below the first screen came
back at the top.

**Home is `TVHomeView` on the shared `HomeViewModel`**: the hero over a
full-bleed backdrop, then the rails in iOS's order with See All tiles. There
is no Libraries rail (Benjamin, 2026-10-05): the sidebar lists every library.
Every tile's caption is always shown. What isn't guessable:
- **The hero's timer runs only when everything allows it**
  (`TVHeroPager.timerRuns`): more than one item, Auto Carousel on, no Reduce
  Motion, not under the UI-test harness, the hero focused, Home on show, and
  no page turned by hand this visit. It waits ten seconds (Benjamin,
  2026-10-04; iOS's hero uses five).
- **Paging by hand is forward only, and wraps** (Benjamin, 2026-10-04): an
  invisible focus guard right of More Info turns the page when it takes focus
  and hands focus back; after the last item it goes to the first, as the
  timer does. There is no guard left of Play, so Left there always opens the
  rail.
- **The current page dot fills over the interval while the timer runs**, as
  iOS's does, and is solid white while it's stopped (Benjamin, 2026-10-04).
  Each start fills from empty, as the timer counts a full interval.
- **The hero holds only titles with a backdrop of their own**: the random
  fetch asks the server for `ImageTypes=Backdrop` (Benjamin, 2026-10-04),
  on iOS too, since `HomeViewModel` is shared. A title without one made an
  empty-looking hero. The logo crossfades between items with the backdrop
  (`TVHeldImage` keys each picture's view, so old and new overlap; redrawn
  in place, a cached logo swapped at once).
- **Play on a series plays an episode** (`TVHeroPlayTarget`): its Next Up,
  or its first episode for a show never started. A series id itself doesn't
  play.
- **Leaving the player started from the hero lands on the title's detail
  page** (Benjamin, 2026-10-04), pushed over Home so Menu goes back to the
  hero (`tvOpenDetailBeneathPlayer`). It's pushed beneath the player once
  that is up, and counts as not on show until the player closes: tvOS puts
  focus where it likes as the player goes (the synopsis), so the page claims
  Play the way one coming back on show does. Full-screen presentation takes
  the page out of the window, which cancels its `.task`; that's why
  `AssetDetailViewModel.loadIfNeeded()` runs its load in a task of its own,
  as `HomeViewModel`'s does. Cancelled, a show's episode lookups failed
  quietly and it loaded with no Play.
- **More rails load for as long as the spinner below them is built**, in a
  loop, not once when it appears (Benjamin saw it spin for good,
  2026-10-05). A batch whose candidates were all too thin to make a rail, or
  one that added rails without moving the spinner out of the lazy stack, or
  an appearance mid-load, left nothing to ask for the next batch: logged on
  the LAN server, one batch, then nothing through 20 presses. Each batch runs
  in a task of its own, since cancelled with the spinner its requests failed
  and its candidates were dropped as too thin. iOS's `ScrollBottomObserver`
  exists because a row's appearance isn't a reliable trigger there either.
- **Rails are keyed by title, in focus ids and in `ForEach`.** A rail's id is
  new with every refresh, and Home refreshes when it comes back on show:
  keyed by id the rails were rebuilt, each scrolled back to its start, and
  focus couldn't return to a See All at a rail's end.
- The hero's height is the detail pages' (`TVDetailMetrics.headerHeight`), so
  Play lands without a nudge, and the page returns to its top when focus goes
  back up (`tvDetailLanding`). The backdrop fades out once focus is below the
  hero, leaving the shell's plum glow behind the rails, and fades back in when
  focus returns (Benjamin, 2026-10-04).

**Detail pages and See All grids are pushed onto a path inside the shell**
(`TVShellNavigation.path`), with the rail beside them; every tile opens a
detail page, never playback. Menu pops the path before it opens the rail, and
choosing a rail row drops it. The root page, the top page and the two beneath
the top stay built (`TVPageKeepAlive`, Benjamin, 2026-10-01), hidden and
disabled, so Menu returns to a page exactly as it was; anything deeper is torn
down and rebuilt from its view model, which the shell keeps per path entry.
Three things about it aren't guessable:
- **Pushing and popping hold the rail** (`holdRail()`). The tile that had
  focus is disabled as its page is covered, and tvOS otherwise hands focus to
  the rail, the only thing left, and opens it.
- **A page coming back on show must claim its item more than once.** As the
  page is enabled again tvOS focuses its first item, and a claim made in the
  same pass is dropped, so `tvClaimsFocus` fixes the target when the page is
  covered and sets it until it holds (`tvPageIsOnShow`). Search does the same
  by hand, since its default focus is the system keyboard.
- **A hidden page claims nothing and remembers nothing** (the
  `tvPageIsOnShow` guards), or a covered page would answer for the page above
  it. A page refreshes its data when it comes back on show, without tearing
  down its views.

**A library's page and a See All grid are `TVCollectionGridView`**, on the
shared `CollectionGridViewModel`: a title and count, the five cascading filter
pills on the left with iOS's symbols (filled or struck while a filter is on),
Reset while any is set, the sort pill anchored at the right, and six columns
of posters with their captions always shown (Benjamin, 2026-10-02). What isn't
guessable:
- **The posters are a UIKit collection view** (`TVPosterCollection`), for the
  system's alphabet index: the column at the right edge while scrolling fast
  (`indexTitles(for:)`, offered only while sorted by title, letters from
  `TVAlphabetIndex`, Z→A with "#" last when the sort is descending, so the
  bar runs the way the grid does; Benjamin, 2026-10-05). SwiftUI has no way to ask for it on tvOS: its
  `sectionIndexLabel` is for `List` only. A hand-drawn letter column came
  first; Benjamin asked for the native one (2026-10-02).
- **Each cell is the system's `TVPosterView`, not the app's SwiftUI tile.**
  Hosted in a cell, the SwiftUI tile held focus where UIKit couldn't see or
  move it: Up from the top row went nowhere, and releasing the index after
  scrubbing left nothing focused with every button dead (Benjamin,
  2026-10-03). The poster is a UIKit view, so the collection view, the index
  and the SwiftUI header move focus between them the ordinary way. Badges and
  the loading glyph are SwiftUI hosted in the artwork's `overlayContentView`,
  so they lift with it. Its caption is the system's own labels restyled as
  the app's (`TVCaptionedPosterView`, Benjamin, 2026-10-03): semibold caption
  over a secondary caption2, one line each, laid along the leading edge by a
  footer subclass (`TVLeadingCaptionFooter`), since the system centres each
  label on its own text. The style is put back on every focus change.
  **A cached image is set a pass later, as a fetched one is**
  (`TVPosterCell.show`). Set while the cell was still being configured, the
  poster kept its artwork at full size instead of inset for its lift, so the
  focused poster ran over its caption, which stayed put: on every return to
  a grid whose artwork was cached (Benjamin saw it about half the time).
- **Focus is put on a poster through SwiftUI, not UIKit.** A focus update
  requested of a cell while SwiftUI holds focus in the header was refused
  every time (logged). So the grid is the page's default in its focus scope
  (`prefersDefaultFocus`), `TVPosterCollectionView.preferredFocusEnvironments`
  points at the target cell, and `resetFocus` is what asks, followed by a
  focus update from the window's root as the shell does: on arrival, on a
  handoff from the sidebar, and back on show, held until it sticks. The reset
  alone left focus on the rail one opening in four (measured). Focus
  inside the grid is remembered from the collection view's own updates.
- **The header (title, pills, open list) is SwiftUI drawn over the grid**,
  offset by the grid's scroll, not inside it: inside a cell its pills and
  their list would be another SwiftUI hierarchy from the page's focus state.
  A pill taking focus scrolls the grid back to its top.
- **The pills aren't SwiftUI `Menu`s** (`TVDropdownPill`, `TVDropdownList`).
  A tvOS `Menu` gives focus back to its button about 1.3 seconds after a
  choice: measured from the focus system's own updates, nothing has focus in
  between, and a request made sooner is ignored. Ours closes with focus on
  the pill in the next frame (Benjamin, 2026-10-02). The open list is laid
  over the page from the pill's bounds, not hung from the pill, since the
  pill row is a focus section and a section confines movement to its own
  frame (Down from the list's first row went nowhere); and focus is held on
  the pill for a moment after a choice, because the grid reloads under it.
  Menu closes an open list; so does focus leaving it. A pill's text is one line,
  cut short with an ellipsis past 260pt (`TVDropdownPill.maxTitleWidth`): a
  chosen studio wrapped to two lines (Benjamin, 2026-10-03).
- **Reset appears only while a filter is set**, as on iOS, and clears them
  all in one press; focus then goes to the first pill, since Reset removes
  itself.
- **A cell answers `canBecomeFocused` itself (false).** Left to UIKit, the
  answer came from the collection view, which can reload its data to find the
  cell; asked while a See All grid was being popped with a poster focused,
  that reload reused the focused cell and UIKit's focus system aborted the
  app. A list change is reloaded at once (`reloadData` then
  `layoutIfNeeded`), never left for UIKit's next pass.
- **The grid reloads when it comes back on show** (a detail page may have
  changed a poster's badges) and keeps its place: the same titles redraw
  where they are. A title that drops out (marked watched in a grid filtered
  to Unwatched) hands focus to the tile that took its place. Focus placement
  looks its target up by id on every attempt: an index path kept across that
  reload was past the end, and `scrollToItem` raised on it, aborting the app
  (M3 review). A list changing under a focused tile is a refresh and keeps
  the scroll position; one changed from the header (a filter, a sort) starts
  at the top.

Tiles speak their badges as an accessibility value ("Watched", "Favorite"),
since the badges are drawn, not read.

**On a detail page Down walks a row at a time** (Benjamin, 2026-10-02): the
actions, Cast & Crew, More Like This, Details. Cast tiles take focus though
Select does nothing (there is no person page). The action row's focus section
spans the page's width (`TVDetailActions`): hugging its buttons, Up from a
cast member right of Favorite found nothing above and did nothing. Details is a summary; Select
opens the full list over the page (`TVFullDetailsView`): iOS's Details tab
rows and every audio and subtitle track, per version, in focusable sections,
since a tvOS scroll view moves only with focus. The backdrop blurs and dims
once focus is below the header, so the rails read against it.

**While focus is in a detail page's header, the page sits at its top**
(Benjamin, 2026-10-02): back from the rails it returns there, and focusing the
synopsis doesn't scroll it higher (`TVMovieDetailView.restoreLanding`). Three
measured facts behind it:
- **The header's height is what makes the top the landing position.** Too
  tall and Play sits too low for tvOS, which nudges the page down as it takes
  focus: 60pt at 860, 16pt at 800, 4pt at 784, none at 776 (measured from a
  screen recording, frame by frame). With any nudge the page visibly settles
  a second after opening, and "the start" is no longer the top. Measure
  before changing `headerHeight`.
- **The header holds space for what arrives late.** A tile hands the page a
  lighter copy of the item; badges, credits and sometimes the overview come
  with the full fetch, which from a cold server is seconds later. Those rows
  keep their space while loading and the text rows always reserve their full
  line count, so the logo doesn't jump when they land.
- **tvOS's own focus scroll can start after ours and win**, at no fixed delay
  (a timed second attempt worked from one row down and failed from three), so
  the page is also sent back whenever a scroll comes to rest
  (`onScrollPhaseChange`) while focus is in the header.
- **`ScrollPosition` measures from the inset top**, the raw content offset
  from the safe-area margin above it: `contentOffset.y + contentInsets.top` is
  zero at the top, and scrolling to the raw offset sat 60pt high.

**Shows, box sets and playlists have their own pages** (`TVDetailPage`
chooses by kind), all on `AssetDetailViewModel`. The header behaviour above is
shared: `tvDetailLanding` and `TVDetailMetrics.headerHeight`. What isn't
guessable:
- **A show's episodes live in `TVSeasonEpisodesModel`**, a season at a time.
  iOS keeps them in a view; here the shell rebuilds pages.
- **Play is drawn before the show's episode is known**
  (`TVDetailActions.isResolving`), or focus lands on Watched and Play appears
  beside it. If the show has nothing to play, Play goes and focus is sent to
  Watched; left alone, tvOS moves it up to the synopsis.
- **The season tabs follow focus** (Benjamin, 2026-10-02): the tab with
  focus is the season on show, no Select. So into the tabs from the actions
  or the episodes, focus is sent to the season already on show; tvOS picks
  the tab nearest the control it left (Season 2 from Play, which is wide),
  which would switch season on the way past.
- **A show's format badges are the episode's that Play starts.** A series
  has no media source, and the view model resolves that episode without one,
  so the badges are read from the season's episode list, which is fetched with
  `detailFields`. The row's space is always held, since they land late.
- Below the episodes a show has the movie page's Cast & Crew (`TVCastRail`;
  the episode's own people when the page is on one and it has any), More
  Like This and Details (`TVDetailsPanel`, shared with the movie page): the
  episode's the page is on, and on the series the one Play starts
  (Benjamin, 2026-10-02), named beside the heading. Never the show's,
  which has no file to describe.
- **A show's page is on the series or on one of its episodes**: an episode
  tile from Home opens it on that episode, and Select on an episode in the
  rail turns the page to that episode in place, with focus on Play, rather
  than playing it (Benjamin, 2026-10-02; `chosenEpisodeID`). On an episode
  its name, overview and Details show and Play is that episode; Watched and
  Favorite act on the show, as on iOS. It isn't a push: Menu leaves the show.
- **A show page's imagery follows what it is on** (Benjamin, 2026-10-02;
  `TVShowDetailView.artItem`): the episode; otherwise the season chosen from
  the tabs; otherwise the show. That covers the backdrop (handed up to
  `TVDetailPage`), the logo and the no-backdrop side image. The fallback from
  episode to season to show isn't the app's: Jellyfin names the nearest
  ancestor with a backdrop or logo on every item, which
  `MediaItem.backdropImageURL` and `logoImageURL` read, as iOS does.
  What's on screen is held until the next image has loaded, then faded
  (`TVHeldImage`): swapped at once, an uncached image left its space empty
  until it arrived, a flash between two pictures.
- **Box set tiles open detail pages; playlist rows play**, with the playlist
  as the queue. Neither has the tall header, so their backdrop blurs by scroll
  offset (`tvDetailDimsWhenScrolled`), not by focus. An empty one shows a
  message that takes focus (`TVDetailEmptyMessage`): with focus nowhere, Menu
  reaches nothing. **A page still loading does the same with its spinner**
  (`TVDetailLoading`, on every detail page, box set and playlist): with
  nothing focused, the shell's three-second fallback opened the sidebar over
  the page, where Menu left the app instead of popping (M3 review).

**A title with no backdrop shows its poster or thumb beside the title**
(Benjamin, 2026-10-02; `TVDetailHeaderArt`): a movie's poster; a show's or an
episode's thumb, failing that an episode's still or a show's poster. It sits
in the header, so it scrolls away with it, and the page draws no backdrop at
all, leaving the shell's glow. A backdrop that is loading or fails draws
nothing either (`AsyncRemoteImage.showsPlaceholder`): a glyph mid-screen read
as broken. The art is an accessibility element with a label, not hidden, or
XCUITest can't see it.

The player reports where it stopped (`TVPlaybackSession.end()` returns the
outcome once; `TVPlayerPresenter.present(_:queue:client:userID:onClose:)`), so
the detail page beneath shows the new resume point at once, as iOS does.

`.searchable` draws its field only inside a navigation container, which the
`TabView` used to supply, so Search sits in a `NavigationStack`. Search lists
every kind the server returns, as rails by type in a fixed order with Other
last (`TVSearchGrouping`), and while the field is empty shows Recent Searches:
the results last opened, the history `SearchViewModel` shares with iOS,
grouped into the same rails by type under one heading with Clear beside it
(Benjamin, 2026-10-04). With none yet it shows iOS's "Search Your Library"
placeholder, in iOS's words. **The recent rails are keyed apart from the results'
rails** (`recentKey`): sharing their ids ("movies"), the lazy stack kept the
results' rail on screen when the field was emptied. Its tiles have no badges,
since search hints carry no user data. **Choosing another page from the
sidebar leaves Search, which starts fresh when chosen again** (Benjamin,
2026-10-04; `TVShellNavigation.selectionLeavesSearch`): the field emptied,
the results and the remembered tile dropped. A detail page pushed from
Search keeps the query, since Menu returns to it.

**Every rail and grid chooses one tile shape, as iOS's rails do**
(`TVTileShape`, Benjamin, 2026-10-05): posters when every item is
movie-like, landscape thumbs when any is a show or an episode
(`MediaItem.usesLandscapeRailTile`, the check behind iOS's
`MediaCollectionRail.usesLandscapeTiles`), so a mix is landscape. That
covers Home, More Like This, box set members, playlist rows, each Search and
Recent Searches rail, and the library and See All grids, where landscape is
four 16:9 columns (`TVTileMetrics.gridLandscape`) in the six posters' width.
iOS's own library grid is always posters; tvOS's follows the rule. A grid
takes its shape from every item, not the filtered ones, so a filter never
changes it.

**An episode tile carries its show's logo bottom-left**, as iOS's
`episodeLogoOverlay` does (`TVEpisodeLogoOverlay`, Benjamin, 2026-10-05): a
bottom gradient with the logo over it, raised clear of the progress bar while
part-watched. Only episodes, and only when Jellyfin names a logo up the chain
(`TVEpisodeLogo`); no text stands in, since the caption names the show.

**A tile's caption moves down with its artwork's lift while the tile has
focus** (`TVTileCaptionText`, `TVTileMetrics.captionLift`; Benjamin,
2026-10-04), on every SwiftUI poster and landscape tile. `.card` grows the
focused artwork about 10% (a 375pt poster's bottom edge drops 19pt,
measured), and a caption left in place had the poster run over it. The
collection grid's system posters do this themselves.

**Limitation: the system Search UX must be full screen to show and work
correctly** (Benjamin, 2026-10-04). `.searchable`'s field, keyboard and hint
are laid out for the window's width, not their container's: the keyboard is
one fixed-width row and the field a fixed width with the system's hint
("Hold … to dictate", "Press … to change keyboard") drawn after it, both
clipped to the search container. Measured on tvOS 27 beside the rail, every
inset, width and scale tried lost something: the first keys scrolled out of
sight, the hint ran off the right of the screen, or a scaled container cut
the hint at its own edge. Our own field and keyboard would fix the layout
but lose dictation, Continuity Keyboard and the system's suggestions. So
Search is the system's own full-screen layout (`TVPageScaffold(layout:
.fullScreen)`), and on it the shell slides the collapsed rail off the left
edge (`TVShellNavigation.hidesCollapsedRail`; 400pt, since at its frame's
width part of its glass still showed). A chevron at the middle of the left
edge says where it went (`TVEdgeChevron`, `showsEdgeChevron`). Menu, or Left
from a result in a rail's first column, slides the open sidebar in on
Search's row. Right from it hands focus back to the page as choosing the row
does (`handFocusToPage`), since the keyboard is UIKit near the top and tvOS
finds nothing right of the row by itself. A page pushed from Search has the
rail as usual. Left on the keyboard stays in the keyboard.

The Simulator's on-screen remote sends Select as a keyboard Return, which
the system keyboard takes as a typed Return, not a key press, so Select
types nothing there (on `develop` too). A Siri Remote press does type, as
XCUITest's remote does.

**Profile is the only way to settings** (`TVProfileView`, prototype screen
11): the user's avatar, name, server and address and both versions on the
left, and the settings as rows on the right (`TVSettingsRow`), in iOS's
sections minus Downloads, Theme and 3D Depth Effects: Account (Switch User,
Approve Quick Connect Code while the server has it on, Change Server, Sign
Out), Apple TV Users, Appearance (Auto Carousel on Home), Playback (Next
Episode Countdown, Chapters in Scrubber, Advanced) and About (License, Privacy
Policy), with iOS's footers. What isn't guessable:
- **Select on an on/off row flips it; a setting with more choices opens a
  page listing them all** (`TVSettingsPicker`, Benjamin, 2026-10-05): Next
  Episode Countdown, Streaming and Max Streaming Bitrate. The current choice
  is ticked and takes focus; Select picks and closes, Menu closes without
  changing anything. Not a SwiftUI `Menu`, for its late focus return. A row's
  value is its accessibility value, which is localized, so journeys compare
  it before and after, never to "On".
- **A row that opens a page shows a chevron** (Benjamin, 2026-10-05), beside
  its value when it has one. Advanced has none: it holds more than the
  streaming mode, so it doesn't preview it.
- **Sign Out forgets the account on this Apple TV**
  (`AppState.signOutForgettingAccount()`); Switch User keeps it remembered,
  one press away on Who's Watching? (Benjamin, 2026-10-01). So Sign Out asks
  first, as Change Server does (`TVConfirmation`, Cancel focused; Benjamin,
  2026-10-05), and both rows are tinted red as destructive.
- **Each sub-screen is a full-screen cover** (Advanced, Quick Connect
  approval, the two text pages, Change Server's and Sign Out's questions), so Menu closes it
  onto its row; not a push, which would put the sidebar beside it.
- **The License and Privacy Policy pages are cut into focusable paragraphs**
  (`TVTextPageView`), because a tvOS scroll view moves only with focus. Both
  files are bundled into `DionysusTV` as on iOS (`project.yml`).
- **Next Episode Countdown, Chapters in Scrubber, Subtitle Styling and Show
  Playback Stats Button are stored but change nothing on tvOS until M4**
  brings their player features; Streaming and Max Streaming Bitrate work now.
  The chapters and stats keys moved to `PlayerPreferenceKeys.swift` with the
  carousel's, since tvOS doesn't compile the iOS player views.

**A page's `.accessibilityHidden(false)` overrides every
`.accessibilityHidden(true)` inside it.** `TVMainView` once set
`.accessibilityHidden(!onShow)` on each page, which on the page on show put
the avatar and every backdrop in the tree (found by the tvOS accessibility
audit). Hidden pages stay out of the tree without it (checked with a movie
page over Home); set a hidden modifier only where it is always `true`.

Sign-in puts
Quick Connect first (`TVSignInRoute`): a user with a password goes to a code,
with "Use Password Instead" one press away, and only a user the server reports
as passwordless signs in on Select.

**Each Apple TV user has their own session.** The `DionysusTV` target runs
as the current Apple TV user (`com.apple.developer.user-management` =
`runs-as-current-user-with-user-independent-keychain`), so `UserDefaults` and
the Keychain are per user, and tvOS terminates the app on a user switch and
relaunches it as the new user. There is no in-app user-change event to handle.
The server configuration is the household's: `ServerSessionStore.ServerLocation
.platformDefault` puts it in the keychain every user shares
(`KeychainStore.Scope.allUsers`), where it also survives a reinstall.
Credentials carry the server they were issued by (`StoredCredentials.serverID`)
and are discarded at launch when another user has since changed it.
`DeviceIdentity.deviceID` must stay per user: Jellyfin revokes a user's older
token on the same device id (`SessionManager.GetAuthorizationToken`), so a
shared id would sign one person out whenever another signs in to the same
account.

**Every account signed in is remembered, on tvOS only**
(`ServerSessionStore.RememberedAccounts`), as the fallback for the system bug
below. The list sits in the current user's keychain beside the credentials,
not the shared one, which would hand each person's session to everyone
(unless the household chooses that, below).
Who's Watching? lists remembered accounts for the configured server first,
most recent first, five lockups to a row ("Other" included) before the row
scrolls (`TVWhosWatchingLayout`), and one press signs one in the way
launch restores a session (`AppState.signIn(rememberedAccount:)`): a password
account with its stored password, a Quick Connect one by validating its token.
Switch User (`signOut()`) keeps the list, since it's the way back to it;
Change Server clears it; holding Select on an account offers Forget This
Account. An account the server now refuses goes to its password screen with
the reason (or to a new code, for Quick Connect) and stays remembered; an
unreachable server says nothing about the account, so the person stays put.
XCUITest sees the system menu's row as `Other`, not a button, and focus on its
cell, so the journey finds it with `descendants(matching: .any)`.

**Profile's "Follow Apple TV Users" can turn per-user sessions off**
(`SessionScopeSetting`, on by default). The setting lives in the shared
keychain, since a per-container value would flip with the very bug it exists
for, so it is one setting for the whole Apple TV. Changing it moves the
session between the per-user and shared keychains
(`ServerSessionStore.moveSession(to:)`), written to the destination before it
is deleted from the source and merged with what the destination holds, never
over it. Off, every remembered account moves and every Apple TV user shares
one sign-in and list, which PRIVACY.md says. Back on, only the account in use
moves, ahead of the accounts that Apple TV user had before; the rest of the
shared list is deleted, since other people's passwords don't belong in one
person's keychain. It
can't change which container tvOS launches into, and preferences and the
device id stay per container either way. Another user's per-user session left
behind while it was off is untouched, and is theirs again once it's back on.
The UI-test reset clears the settings and the shared session too.

**With Follow off, "Select a User Every Relaunch" starts each launch at Who's
Watching?** (Benjamin, 2026-10-01; `WhoIsWatchingPolicy`, on by default, shown
on Profile only while Follow is off, stored beside it in the shared keychain).
`AppState.start()` then signs out the way Switch User does, with no request,
so the accounts stay remembered and one press signs one in. Two rules: with
exactly one remembered account there's nothing to choose, so it signs straight
in; and since tvOS suspends the app through sleep, coming back to the
foreground after 30 minutes away counts as a relaunch (`TVRootView` watches
`scenePhase`, closes the player, then signs out). Off, the app stays on
whoever was signed in until Switch User. An unreachable server leaves the
person on Who's Watching? there, where a launch otherwise resumes from cache.

**tvOS's user switching is unreliable, and no app can fix it.** Measured on
the Bedroom Apple TV (tvOS 27.0, 2026-09-30): the per-user split itself works
(a secondary user runs in `/var/PersonaVolumes/<id>/…`, the primary in
`/var/mobile/…`, and neither sees the other's per-user keychain), but cold
launches repeatedly ran in the *other* user's container, before and after
restarts, and installing a build from the Mac made it worse. It's the system
bug in Firecore's "User Switching Broken (tvOS 26.4)" thread (reproduced by
Firecore with a sample app; fixed in 26.6, reported recurring on 27). Don't
debug it as an app bug, and don't design anything that assumes the container
matches the Apple TV user: remembered accounts and one-press switching in the
app (above) are the fallback. To check which container a
launch got, print `NSHomeDirectory()`.

**HDR on the Apple TV plays through the HDR master as of AetherEngine 7.22.2**
(measured 2026-09-30 on an Apple TV 4K 3rd gen, tvOS 27.0, HDR10-only TV). The
engine requests the HDR10 mode and the right frame rate, and the TV takes about
2.9s to switch there, longer than the engine's 2s criteria gate. Up to 7.22.1
the engine served the master mid-switch, AVPlayer refused it (`-11868`), and
the refusal latched until the app was backgrounded (AetherEngine#588), so every
HDR title fell back to the media playlist: still HDR10/PQ on screen, but with no
subtitle or audio renditions. 7.22.2 waits for the switch to end before serving
the master and no longer latches a refusal raised mid-switch (AetherEngine#667,
which this app filed and retested on device). The HDR label still can't be
trusted on its own: `currentEDRHeadroom` reads a flat 1.00 while the TV shows
HDR10, so the engine only corrects `$videoFormat` from `.sdr` once AVPlayer
accepts the master, and a session that falls back would still read SDR. Trust
the TV's own info banner, not `displayColorFormat` or EDR headroom, when
checking HDR here. For the same reason the player's format chip stays hidden on
tvOS (`TVTransportOverlay.showsFormatChip`).
`DisplayContext` passes the real Match Content setting, and deliberately
asserts nothing about the panel's HDR state, since EDR headroom is the only
thing it could read and the engine reads that itself.

**The player host has three rules, each learned from AetherEngine's README or
Sodalite rather than guessable** (`DionysusTV/Player/`). It is presented with
UIKit `present`, never `fullScreenCover`, which takes the Menu button for
itself. The engine's own `AetherPlayerView` is hidden whenever
`currentAVPlayer` is non-nil, because AVKit draws the native route and the
software route has no AVPlayer at all (`TVPlayerSurfacePolicy`). And the
engine is made with `ownsNowPlayingSession: false`, since the
`AVPlayerViewController` already runs Now Playing and a second session
conflicts with it. AVKit's chrome is hidden and the transport is ours
(`TVTransportOverlay`), inset by the safe area alone. It fades four seconds
after playback starts or the last press, never while loading or paused
(`TVTransportChrome`); timing the first fade from the player appearing let a
slow load use up the title's time on screen.
The space bar is Play/Pause too (`TVKeyboardCommand`): a keyboard, and the
Simulator's on-screen remote, send it as a keyboard press (type 2044, HID
usage 0x2C), never `.playPause`, so a `.playPause` recognizer alone leaves
Play/Pause dead there. XCUITest can't type into the player (nothing has
keyboard focus), so check that path with `idb ui key <udid> 44`.

## Commands

The Xcode project (`DionysusPlayer.xcodeproj`) is generated from `project.yml`
via XcodeGen rather than committed — this keeps project structure a readable
diff instead of an opaque `.pbxproj`. **Whenever `project.yml` changes, or the
set of source files changes, regenerate the project:**

```sh
xcodegen generate
```

To build/run, open the generated project and build the `DionysusPlayer`
scheme (target iOS 18+):

```sh
open DionysusPlayer.xcodeproj
```

Two test targets exist: `DionysusPlayerTests` (XCTest unit tests, host-app
style) and `DionysusPlayerUITests` (XCUITest journeys). Three test plans live
in `TestPlans/` — `UnitTests` (the scheme default), `UITests-Smoke` (the PR
gate) and `UITests-Full`. See `TESTING.md` for the strategy and what's
covered. CI runs the UI plans on an iPhone 16 and an iPad (A16), on iOS 26.5
(the smoke gate) and also on iOS 18.6, the deployment floor, for nightly,
release and PRs into `stable`. `.github/workflows/ui-tests.yml` owns that matrix. CI pins Xcode
26.6 on `macos-26`, except the iOS 18 leg: no image has both runtimes and
Xcode won't download an iOS 18 one, so it runs on `macos-15` with Xcode 26.3. The two smoke checks' names embed the device and OS and are
required by both rulesets. See TESTING.md's "Where they run in CI" before
changing any of it. Run it from Xcode with
the `DionysusPlayer` scheme (Cmd+U), or from the CLI once a Simulator runtime
is available:

```sh
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Pinning AetherEngine

**`project.yml` pins AetherEngine with `version:` (XcodeGen's spelling of
SPM's `.exact` requirement), not a `from:` range.** This used to be
`from: 6.5.5` (SPM's "up to next major" rule), which meant a cold resolve —
every CI run, since `Package.resolved` is gitignored along with the rest of
the generated `.xcodeproj` (see above) — could silently land on whatever the
newest `6.x` release happened to be, with zero commit in this repo to review
or even notice. Confirmed live more than once (PR #147, 2026-08-28: CI
resolved `6.54.0` against a checked-in `6.52.0` pin with no other
AetherEngine-related change on the branch at all). An exact pin makes that
structurally impossible: a cold resolve always lands on this exact version.

**Bumping the pin is automated but still reviewed.** The "Bump AetherEngine"
workflow (`.github/workflows/aetherengine-bump.yml`) runs weekly, finds the
newest release tag within the *current* major (what `from: <major>.0.0`
would resolve, prereleases excluded), and if that's newer than the pin,
opens a PR bumping `project.yml`'s one line. It never proposes a major bump
(8.0.0) — that's exactly where AetherEngine's public API is allowed to break
per semver, so project.yml's own comment on the `packages:` block treats it
as a deliberate manual edit. A bump PR goes through the same `pr-checks.yml`
gate as any other PR before it can merge — nothing lands unbuilt/untested.

**The version shown in "stats for nerds" comes from the engine itself.**
`PlaybackStatsOverlay` reads `AetherEngine.version` (added upstream in 7.3.0)
through the `AetherEngineVersion` shim in `Core/Playback/`, so nothing needs
regenerating after a bump. This replaced a checked-in generated constant,
its regeneration script, and a `pr-checks.yml` drift gate — all of which
existed only because AetherEngine used to expose no version at all.
Upstream rewrites the literal in each release's prep commit and holds it to
the tag by test; it matched on every tag from 7.3.0 to 7.15.0.

### App version (SemVer)

The app's own version — shown on the Profile screen's footer via
`AppVersionInfo`/`AppVersion.swift` — follows SemVer, grounded in git tags
and wired into `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` as far as
Apple's numeric-only version fields allow. This used to be the same
"stamp git branch/commit into the built Info.plist via a
postCompileScripts phase" trick as AetherEngine's version above, and hit
the identical build-graph-ordering bug; it's since been replaced with the
same fix (a checked-in generated file, refreshed by
`Scripts/update-version.sh`). See `VERSIONING.md` for the full scheme —
tag convention, alpha/beta/final release flow, and how the version reaches
the built app.

`stable` is the branch final `vX.Y.Z` releases are tagged from — it moves
forward only via the `develop → stable` promotion PR (`promote-to-stable.yml`,
see `VERSIONING.md`), and should never be branched from or committed to
directly. `develop` is the default branch and where all day-to-day work
happens; `stable` stays dormant until there's a final release to cut.

**Cutting a release is one annotated tag push.** `release.yml` stamps the
version from the tag, builds and tests it, archives and signs it, uploads it
to App Store Connect (where it becomes a TestFlight build), and publishes the
GitHub Release. Nothing needs stamping, predicting, or verifying beforehand —
if you find yourself adding a "stamp before tagging" step, read
`VERSIONING.md`'s "Why there is no longer a release-prep PR" first; that
coupling was removed deliberately after its build-number prediction broke
three times.

Three things about it that aren't obvious from the workflow file:

- **The annotated tag's message is the release notes.** It becomes both the
  GitHub Release body and TestFlight's "What to Test", so write it for a
  tester. A lightweight tag (`git tag` without `-a`) silently produces an
  empty summary.
- **`Config/Version.xcconfig` and `AppVersion.swift` are expected to lag**
  between releases. CI stamps the shipped build; the checked-in copies are a
  local-dev convenience and report honest off-tag metadata
  (`0.8.0-alpha.1+12.gabc1234`). Don't "fix" them to match.
- **The archive and the export both sign manually**, with the distribution
  certificate and a provisioning profile named *by string* — on the app
  target's Release config in `project.yml`, and in `Config/ExportOptions.plist`.
  Automatic export fails with a cloud-signing permission error, and an
  automatic archive created a new development certificate on every run until
  the account hit its cap. The profile and certificate expire 2027-08-30.
  See `VERSIONING.md`'s "Signing setup".

## UI verification

**The regression net is `DionysusPlayerUITests`** — an XCUITest suite driving
the real app against an in-process stub server and a fake playback engine.
See `TESTING.md`'s "UI tests" section for the harness, the launch arguments,
the fixture catalogue and the selector rules. Run it with
`-testPlan UITests-Smoke` (the PR gate) or `-testPlan UITests-Full`.

**If a change touches a view, add or update a journey there** rather than
verifying once by hand and moving on. Two rules that are not guessable and
cost a debugging session each: never select on an accessibility *label*
(those are localized), and never put an identifier on a screen-root
container (it sometimes overwrites every descendant's own). Both are
documented in `A11yID`.

**Accessibility is gated too.** `AccessibilityAuditTests` runs
`performAccessibilityAudit()` over every screen, on the *structural* audit
types only — unlabeled controls, labels that aren't human-readable, wrong
traits, hit regions. A new view with a decorative `Image(systemName:)` and
no `.accessibilityHidden(true)` will fail it, because SwiftUI falls back to
the SF Symbol's name and VoiceOver reads it aloud. Contrast, Dynamic Type
and text clipping are deliberately *not* gated — 145 known findings that
come from app-wide design choices rather than mistakes; see `TESTING.md`'s
"Accessibility audits" before widening the set or adding a suppression.

Everything below is for *exploratory* checking — seeing a new design, or
chasing something the suite can't express. It is not a substitute for a
committed test.

For visual or interactive changes, prefer the `ios-simulator-skill` (when
available) over ad hoc `simctl`/coordinate-tap scripting: it drives the
Simulator via `idb`'s accessibility tree (find-by-text/type/id, then tap)
rather than blind pixel coordinates, which survives layout changes far
better. It needs `idb-companion` installed (`brew tap facebook/fb && brew
install idb-companion`) plus the `idb` Python client — install that via
`pipx install --python $(which python3.12) fb-idb` specifically; pipx's
default (newer) Python fails at runtime with an `asyncio.get_event_loop()`
error. Start a session with `idb_companion --udid <udid> &` then
`idb connect <udid>` before the first call.

Reuse a single booted Simulator instance across tasks rather than
booting/quitting one per session: check `xcrun simctl list devices | grep
Booted` first and target whatever's already running (same device for
`xcodebuild -destination`/`simctl install`/`simctl launch`), and don't
`simctl shutdown` or quit Simulator.app when a task finishes. One instance
reuses fine back-to-back — closing and relaunching only wastes boot time and
throws away useful state (installed build, current screen).

Confirmed (2026-08-12) working well for Login, Home, Search, Profile, and
detail-page screens — real accessibility elements, real taps.

An earlier version of this section said `idb` returns an empty accessibility
tree on the Player screen and that automated taps there were hopeless. **That
is no longer true** — it was disproven on 2026-09-05, and XCUITest drives the
player's controls fine under the UI-test harness, where the fake playback
engine means there is no video surface at all. If a real AetherEngine session
*is* on screen, the surface repaints continuously and automation there is
still worth avoiding; use the harness instead of fighting it.

## Architecture

The app is a straight linear state machine at the top, with feature modules
underneath that each follow the same MVVM shape.

### App-level flow (`App/`)

`AppState` (`App/AppState.swift`) is the single source of truth for where the
user is in the app, driven by a `Phase` enum: `.serverSetup` → `.login` →
`.main`. It also owns the `JellyfinAPIClient` instance, since the client's
base URL depends on which server was configured — there is one client per
configured server, created in `completeServerSetup` and recreated on
`start()`. `RootView` shows `MainTabView` once the user is in `.main` and
the session has restored, and `OnboardingFlowView` otherwise — everything
before the app, as one continuous scene (see "Welcome, server setup and
sign-in" below). Session persistence
(`ServerSessionStore`, `Core/Persistence/`) splits storage by sensitivity:
server config in `UserDefaults`, credentials/access token in the Keychain
(`KeychainStore`). On launch, `AppState.start()` restores the server, then
attempts silent sign-in with stored credentials before falling back to the
login screen.

### Welcome, server setup and sign-in (`Features/Onboarding/`)

`OnboardingFlowView` hosts four stages — the splash (`SplashView`, while
`AppState.isRestoringSession`), the first-run welcome (`WelcomeView`), server
setup and sign-in — and owns what they share, so nothing cuts between them:
the brand background (`OnboardingBackground`), the glyph's matched-geometry
namespace (the glyph *moves* from screen to screen), an always-dark
appearance scoped to the flow rather than forced on the window, the
composition, and the orientation lock. The shared pieces live in
`Shared/Components/Onboarding/`. Five things about it aren't guessable:

- **The composition is chosen from the window, never the device**
  (`OnboardingLayout.resolve`): compact (one column, actions pinned to the
  bottom edge) unless the size class is regular *and* the window is at least
  600pt wide; then regular (one centred block, actions inline) or, for a
  window wider than tall and at least 900pt, landscape (brand pane left, task
  right). The size is the *whole* window, safe areas included — a foldable's
  vertical status bar otherwise took enough off its 951pt inner screen to miss
  the threshold. `OnboardingLayoutTests` pins every measured device size.
- **Portrait-only on a phone-sized screen** — shorter side under 600pt
  (`RotationLock.isPhoneSized`), keyed on the screen rather than the idiom
  because a foldable iPhone is both a phone (outer, 466pt) and not (inner,
  669pt, held in landscape). **Known gap, parked until that hardware ships**
  (all tooling pre-release as of 2026-09-25): unfolding after folding releases
  the lock but iOS leaves the interface sideways until the device is turned;
  `requestGeometryUpdate(.all)` didn't move it, and `UIDevice.orientation`
  reads `.portrait` on the inner screen, so it can't choose a target.
- **The welcome shows once** (`ServerSessionStore.hasCompletedWelcome`):
  "Get Started", or having *ever* configured a server — which covers everyone
  who set the app up before the welcome existed. `clearAll()` leaves it set,
  so changing server never replays it. UI tests skip it with
  `-onboarding.welcomeCompleted YES` (`UITestCase.launch(skipsWelcome:)`).
- **`HasPassword: true` doesn't mean a password is needed.** Sign-in is built
  on `/Users/Public` (unauthenticated — what Jellyfin's own login page lists),
  and the demo server reports `demo` as `HasPassword: true` while signing it in
  with an empty password (checked 2026-09-25). So only `false` signs in on one
  tap; anyone else is asked, and an empty password is still submitted rather
  than blocked. An empty list — every user hidden by an admin — falls back to
  a plain username/password form.
- **Server branding comes with two traps.** `/Branding/Configuration`'s
  `LoginDisclaimer` is HTML (the demo server's has `<br/>`), so it goes
  through `LoginDisclaimer.plainText(from:)`. And `/Branding/Splashscreen` is
  off by default (404) and ignores `maxWidth` — it serves the admin's
  original, 4MB for the demo server — so it's only fetched when
  `SplashscreenEnabled`, as JPEG, and downscaled before display.

Also: the splash glyph used to tilt with the device, pivoting 150pt in front
of itself — and SwiftUI's perspective projection scales a view by 1 / (1 +
perspective × anchorZ / size) *even at zero tilt*, which is why its 179pt
frame rendered at 134pt. The tilt is gone from the whole flow (the user found
it pointless once the glyph was one piece of a composed screen; the detail
pages' hero keeps its own). The splash is sized to that measured 134, and
`LaunchScreen.storyboard`'s 157pt glyph frame matches it (its SVG's artwork
fills 1068/1253 of its viewBox). Ambient motion (the drifting background and
the scan radar) stops under Reduce Motion and under the UI-test harness
(`UITestHarness.freezesAmbientMotion`), where a continuously redrawing view
keeps the accessibility tree in motion.

### Networking (`Core/Networking/`)

`JellyfinAPIClient` is an `actor` — all network calls are async and
serialized through it, and it holds mutable state (`accessToken`) that gets
set post-authentication. It's a thin hand-written wrapper over Jellyfin's
REST API (no generated SDK), intentionally scoped to only what the app needs:
server info, auth, browsing/search, playback info, progress reporting, and
(diagnostics-only, for `PlaybackStatsOverlay`'s Streaming section) reading
back the server's own live session/transcode state via `/Sessions`.

`sendRaw` (every request funnels through it) auto-recovers from a 401 on any
token-bearing request: it remembers whatever credentials last succeeded via
`authenticate(...)` and, on a 401, silently re-authenticates and retries with
backoff (`reauthBackoffSchedule`) before giving up as `.notAuthenticated` —
confirmed live against a heavily-shared public demo server that a session
token can be invalidated server-side for reasons entirely outside this app's
control. Concurrent 401s coalesce into one re-authentication via an
in-flight `Task` rather than each racing to sign in independently.
`authenticate(...)`'s own 401 (a wrong password at first sign-in) is
unaffected — it's sent with `requiresAuth: false`, so it never carries the
token header this keys off. `AppState.signOut()` clears the remembered
credentials on the client it reuses across a sign-out/sign-back-in, so a
request still in flight around sign-out can't silently re-authenticate as
the just-signed-out user.

**Quick Connect sessions have no password, and that shapes three things.**
Login offers "Sign In with Quick Connect" when `/QuickConnect/Enabled` says so
(`QuickConnectView`/`QuickConnectViewModel`): the server issues a 6-digit code,
the user approves it on another signed-in client, and the approved secret is
exchanged via `/Users/AuthenticateWithQuickConnect` for an ordinary session.
Behaviour read from `QuickConnectManager.cs` (10.11 and 12.z agree) and checked
against the LAN test server: a code expires 10 minutes after it's issued, after
which polling its secret answers **404**, which is how expiry is detected.
Then, because there is no password:
- **`StoredCredentials.authMethod` says which kind of session it is**, and launch
  branches on it. A `.quickConnect` session validates its stored token with
  `GET /Users/Me` instead of signing in again. It is explicit rather than
  inferred from `password == nil` because passwordless accounts sign in by
  password too and store `""`. It decodes as `.password` when absent, which is
  every keychain entry written before it existed.
- **A mid-session 401 can't recover.** `authenticateWithQuickConnect` clears
  `reauthCredentials`, so `sendRaw` surfaces `.notAuthenticated` at once —
  and never replays an earlier password sign-in on the same client, which would
  silently swap users. Jellyfin tokens don't expire on their own, so this only
  happens when the session is revoked server-side.
- **The instruction text names no menu path** ("open Quick Connect"), because
  where Quick Connect lives differs between Jellyfin clients.

**The other direction — approving someone else's code — lives in the Account
screen** (`QuickConnectApprovalView`, pushed from `AccountDetailsContent`,
shown only when Quick Connect is enabled). `POST /QuickConnect/Authorize`
answers, measured against 10.11.11: 200 `true`, **404** for an unknown or
expired code, **500** for one already approved (an unhandled
`InvalidOperationException`, indistinguishable from any other server error, so
the message says both), and 401 with Quick Connect off. Two things about it:
- **It sends no `userId`.** The server then approves for the caller; naming
  another user needs admin rights and answers 403 otherwise.
- **It runs with `maxReauthAttempts: 1`**, like `deleteItem`: its 401 is a
  refusal, not an expired token. `QuickConnectApprovalViewModel` tells "turned
  off" from "session expired" by asking `/QuickConnect/Enabled` again.

There is no "approve this device?" step because there's nothing to show in
one: only the requesting device can look up which device and app asked.

**Server discovery** (`ServerDiscovery.swift`, run by Find Your Server as
soon as it appears — `ServerSetupViewModel.startScanOnArrival`) speaks Jellyfin's UDP auto-discovery protocol — `who is
JellyfinServer?` to port 7359, answered with `{Address, Id, Name}` — but
**unicast to every host on the subnet, never broadcast.** Sending to a
broadcast or multicast address on iOS needs the restricted
`com.apple.developer.networking.multicast` entitlement, which Apple grants
only on request; the server (`AutoDiscoveryHost.cs`) answers the phrase in any
datagram, so a unicast sweep finds the same servers with only the Local
Network permission. Don't "simplify" it to a broadcast without that
entitlement — it fails silently. There is no API to ask for Local Network
access or read its state, and **under the prompt, UDP probes are accepted and
silently dropped** (seen on device) — so the one reliable signal is the app
going inactive, which a system prompt causes. The scan keeps running while the
app is inactive and starts over once it's active again (`ScanSchedule`); a scan
in which every send is refused reads as denied. The first *HTTP* request to a
LAN address has the same problem — typing an address skips the scan, so that
request raises the prompt and fails behind it — hence
`ServerSetupViewModel.probeAcrossLocalNetworkPrompt`, which waits for the
answer and retries once. The device's own address stays in
the sweep, which is what lets the Simulator find a server on its own Mac.

**A discovered `https://` server whose certificate fails gets an opt-in HTTP
fallback** (`ServerSetupViewModel.connect(to:)`). A server with HTTPS on and no
published URL advertises `https://<LAN IP>:<HTTPS port>`, which a certificate
issued for a domain name (or a self-signed one) can never validate. Both ports
are configurable and **nothing a signed-out client can read reveals the HTTP
port** — the discovery reply carries one address, and the ports live only in
the admin-only network configuration — so 8096 is tried as a first guess and
the user is asked for the port if it's silent. Whatever port answers must
report the discovery reply's `SystemId` over `/System/Info/Public`, and nothing
connects until the user confirms going unencrypted. Only certificate failures
(`URLError.isCertificateFailure`) trigger any of it.

`ImageURLBuilder` is deliberately *not* actor-isolated — it's a plain struct
snapshotted via `client.makeImageURLBuilder()` so SwiftUI views can build
image URLs synchronously without hopping through the actor on every render.

**Live playback** negotiates with the server by default, via a
`StreamPreferenceStore.decisionMode` setting (Profile → Streaming) that
switches between **Allow Transcoding** (default since 2026-08-28 —
`DeviceProfileBuilder.build(maxStreamingBitrate:)` —
`Core/Networking/DeviceProfile.swift` — builds a real `DeviceProfile`, sent
on `/PlaybackInfo` so Jellyfin can choose direct play or a transcode;
`PlayerViewModel.start()` branches on whether the response carries a
`MediaSourceInfo.transcodingUrl`) and **Direct Play Always**
(`streamURL(itemID:mediaSourceID:container:)` builds a static stream URL —
`Static=true` — and AetherEngine decodes whatever comes back; no
`DeviceProfile` sent, the app's original, non-negotiated behavior — still
available for anyone who wants to force it). A
server-chosen transcode is consumed via AetherEngine's `nativeRemoteHLS`
bypass (`AetherPlaybackEngine.load(..., isRemoteHLS: true)` — the playlist
goes straight to AVPlayer, no local FFmpeg demux) rather than downloaded
and re-muxed; the HLS transcode target itself is fragmented MP4 (H.264 or
HEVC), never MPEG-TS — see that file's `hlsTranscode` doc comment for why
(Apple's HLS Authoring Spec doesn't support HEVC-in-MPEG-TS on AVPlayer at
all). `PlaybackStats.route` in the "stats for nerds" overlay shows which
AetherEngine pipeline (`.remoteBypass`/`.loopback`/...) actually ended up
serving a session — `playbackBackend` alone can't distinguish them.

**Downloads are a separate path that always transcodes** —
`downloadStreamURL(...)` (`Static=false`, HEVC/MP4, resolution + bitrate capped
to the user's chosen tier). Don't read the playback paragraph above as a
whole-app statement: the app both direct-plays and transcodes, just in
different places. The tiers, the bitrate ladder behind them, and why the
default differs between iPhone and iPad are documented in `DOWNLOADS.md` —
**read it before changing any number in `DownloadTypes.swift`**, since the
ladder is derived from a single bits-per-pixel rule rather than chosen
per-rung, and a locally-sensible tweak breaks that. `DownloadTypesTests`
asserts the rule directly.

### Image loading & placeholders

`RemoteImageLoader` (`Core/Networking/`) is the single choke point for every
network image (posters, backdrops, logos, cast photos) — an actor with its
own tuned `URLSession`, retry-with-backoff for transient failures, an
in-memory `NSCache` (byte-cost-limited, not count-limited), and in-flight
de-duplication, all built to survive a burst of concurrent requests against
a self-hosted server on first launch. `image(for:maxAttempts:retryBaseDelay:)`
takes optional per-call overrides on top of its own configured defaults —
used by `AsyncRemoteImage.RetryPatience`/`LogoImageView`'s `retryPatience`
(`.standard` vs `.extended`) to give the single hero backdrop/logo per
screen a longer retry budget than every other, smaller image, without
multiplying a cold server's initial request burst. `AsyncRemoteImage`
(network) and `LocalFileImage` (local/offline `file://` artwork — a
synchronous `ImageIO` decode, deliberately not routed through
`RemoteImageLoader`, whose retry logic assumes an `HTTPURLResponse`) are the
two view-level wrappers everything else uses; `LogoImageView` layers on top
of `AsyncRemoteImage`'s network path for the fade-in/fallback-text behavior
logos need.

Every one of those three renders `MediaPlaceholderBox`
(`Shared/Components/`) for its loading/failure state — a content-type SF
Symbol glyph (`BaseItemKind.placeholderSystemImage`, e.g. `film` for a
movie, `tv` for a show, `person.fill` for cast) tinted `.dionysusHighlight`,
never a generic spinner or blank gray box. The glyph itself shimmers (via
the `SwiftUI-Shimmer` package's `.shimmering()` modifier, scoped to the
glyph rather than the whole tile — deliberately calmer than shimmering the
full box) while a fetch is still outstanding, and settles to a static,
higher-opacity glyph once it's failed or known not to exist at all (`isSettled`
— gated on Reduce Motion, matching every other animated effect in this
part of the app). When adding a new image display site, pass a
`placeholderSystemImage` that matches the content type rather than leaving
the generic default.

`LogoImageView`'s `fallback` view (usually title text, via
`BackdropLogoOverlay`) renders immediately while the logo is loading, not
just after a definitive failure — cross-fading to the real logo once it
resolves, reduce-motion aware.

### Playback (`Core/Playback/`)

`PlaybackEngine` is a protocol wrapping AetherEngine so feature code never
depends on the third-party library directly — `AetherPlaybackEngine` is the
real adapter, `PreviewPlaybackEngine` (`#if DEBUG`-gated) is a fake used only
in SwiftUI previews. When changing playback behavior, change the protocol
and both conformers; `PlayerViewModel` should only ever talk to the
`PlaybackEngine` abstraction.

Picture in Picture is wired for AetherEngine's native (AVPlayer) route only —
covers HEVC/H.264, effectively all of this app's real content today.
`AetherPlaybackEngine` owns the `AVPictureInPictureController` (built around
`AetherEngine.nativePlayerLayer`, rebuilt whenever `engine.$currentAVPlayer`
re-emits) behind a small `NSObject` delegate proxy (`PictureInPictureDelegateProxy`
in the same file) — `AetherPlaybackEngine` itself can't conform to the
Objective-C `AVPictureInPictureControllerDelegate` directly without giving up
its throwing `init()`. On PiP start/stop it calls AetherEngine's own
`setNativeSubtitleRendering(_:)`, the documented host hook for handing
whichever subtitle track the app has selected to AVKit as a native WebVTT
rendition — the app's own `SubtitleOverlayView` isn't visible inside the
captured layer. The software (sample-buffer) route — AV1/VP9/interlaced/
legacy sources — has no PiP support yet; the button in `PlayerControlsOverlay`
is omitted there for free (not shown disabled), since `isPictureInPicturePossible`
never turns true without a controller, which never gets built without a
native player layer.

`AetherPlaybackEngine` also opts into owning the native video path's system
Now-Playing session (`engine.ownsVideoNowPlayingSession = true`, set before
`load()`) — required for the lock screen/Control Center card to show
anything at all, since this app renders its own transport chrome rather than
going through `AVPlayerViewController` (which would get Now-Playing from
AVKit for free, and must NOT also opt into a session of its own — see
AetherEngine's own doc comment on why the default is off). Opting in makes
the *host* responsible for wiring transport commands too: `AetherPlaybackEngine`
registers play/pause/skip against `engine.videoNowPlayingSession
.remoteCommandCenter` (re-registered on the same `$currentAVPlayer` signal
PiP rebuilds on), and `PlayerViewModel.start()` stages title/subtitle
(`MediaItem.railTitle`/`.railSubtitle`) via `engine.setNowPlayingInfo(title:
subtitle:artwork:)` immediately, with artwork following separately once
fetched through `RemoteImageLoader`.

**A stop is reported only after a start** (`PlayerViewModel.stop()`).
Jellyfin's `UserDataManager.UpdatePlayState` (10.11) writes a reported
position straight to the resume point, so closing the player while it was
still loading reported 0 and wiped it; omitting the position is worse, since
the server then marks the item played. `start()` also checks for cancellation
before playing, so a close during the resume seek can't play or report a start
after the stop it raced.

### Subtitles

Two renderers, split by codec. **ASS/SSA goes to libass**
(`ASSSubtitleRenderSession`, on the `swift-ass-renderer` package); everything
else — SubRip, WebVTT, teletext, PGS and other bitmap formats — keeps
rendering through `SubtitleOverlayView`'s own SwiftUI path on the cues
AetherEngine publishes. Four things about that split are load-bearing and none
are guessable:

- **`LoadOptions.preserveASSMarkup` is deliberately NOT set.** The app fetches
  the complete `.ass` script itself instead, so AetherEngine's cue path stays
  exactly as it was for every track. Jellyfin extracts any subtitle stream —
  embedded ones included — via `JellyfinAPIClient.subtitleURL`, and
  `DownloadManager` already stores every non-bitmap track as a sidecar, so the
  script is always available without it. An earlier version of this bullet gave
  a second reason — that turning the flag on would flip the session's embedded
  SubRip tracks to raw event lines too, because it is codec-gated on the sidecar
  path but not on the embedded one (AetherEngine#587). That was wrong, and the
  issue was refuted upstream by measurement. The gate is in
  `EmbeddedSubtitleDecoder.init`, which narrows the flag once into a stored
  property *of the same name*, so the emit site downstream reads as though
  nothing had been checked when it is reading an already-gated value. Don't
  re-raise it from reading that line; upstream has since renamed the property to
  `emitsRawASSLines`. The flag is unnecessary here, not dangerous.
- **A whole script, loaded once — never `reloadTrack` per cue.**
  `swift-ass-renderer` exposes only whole-script load/reload, and `reloadTrack`
  frees the current track synchronously, so feeding it a growing script blinks
  the subtitle off on every rebuild. Reloading only happens on a geometry
  change, which is cheap (0.4–1.7ms for a 218KB script) and deliberately does
  not clear the outgoing frame.
- **Engine track ids match nothing on the server**, so a selected track is
  mapped back by *ordinal*, two different ways. A track AetherEngine demuxed
  out of the container pairs with its `MediaStream` among *embedded ASS*
  entries (`jellyfinStream(forTrack:engineTracks:mediaStreams:)`); a sidecar
  this app registered pairs with what it was built from, among *externals*
  (`registeredSidecar(forTrack:engineTracks:registered:)`, shared by the
  streaming and offline paths). Filtering both sides identically is what makes
  either ordinal meaningful; counting the wrong tracks shifts it and silently
  serves a different track's script, which reads as a bad file rather than a
  mapping bug. `ASSSubtitleMappingTests` pins both.
- **On a transcode the container's own text tracks must be registered as
  sidecars.** The app plays the server's HLS through AVPlayer, and that
  playlist carries no rendition for them, so nothing demuxes them — every
  embedded SubRip and ASS track disappeared from the picker until
  `externalSubtitleStreams(from:isRemoteHLS:)` started registering them.
  Jellyfin says which: asked with this app's `DeviceProfile` it answers
  `MediaStream.deliveryMethod == "External"` for exactly those streams (and
  `"Encode"` for the bitmap ones it burns in). That field is **not**
  `isExternal`, which says where the stream lives in the library rather than
  how it reaches the player — an embedded ASS track on a transcode is
  `isExternal: false` with `deliveryMethod: "External"`, and filtering on the
  former is what dropped them. The route gate is equally load-bearing: direct
  play reports the same `"External"` for the same streams, where the engine
  has already listed them, so registering sidecars there shows every track
  twice. Confirmed against 10.11.11, both routes. AetherEngine supports
  sidecars on the `nativeRemoteHLS` bypass as of 6.14.0 (its #316), which
  rewrites the master playlist to carry them.
- **A cold fetch can take over a minute.** Jellyfin extracts an embedded track
  on demand and caches it: 70s measured against a 4K remux, 0.03s after. The
  request therefore carries its own 180s timeout (`URLSession`'s 60s default
  cut it off just before it finished), and until the script lands the cue path
  renders the same track unstyled, so there is never a dead screen.

**On a transcode, libass is timed off AVPlayer's own subtitle timing, not the
raw playhead.** There AVPlayer's item time runs *ahead of the picture* after a
seek: Jellyfin restarts the transcode at the source keyframe before the
requested segment, and AVPlayer anchors its timeline to the first segment it
loads, so the gap is that segment's slot minus its keyframe — measured anywhere
from 0.8s to 8.3s on one film. It keeps that anchor across later job restarts,
so reading segment timestamps can't recover it (tried and disproven). What does
know it is AVPlayer's timing of the WebVTT rendition AetherEngine injects for
the same track. Since AetherEngine 7.15.2 (AetherEngine#616, which this app
filed and verified on device) the engine measures the lead off that rendition
itself and publishes `sourceTime` minus it, so libass renders at `sourceTime`
unmodified. Don't reintroduce a host-side offset on top — it would subtract the
lead twice and draw every line late. Three things remain the app's job:

- **The rendition must stay selected**, or the engine has nothing to measure.
  An app-owned `AVPlayerItemLegibleOutput` suppresses its drawing instead
  (`setNativeSubtitleCapture`). Two traps, both found on device: an output
  that starts suppressing while AVPlayer is drawing a line freezes that line on
  screen for good — not even a deselect clears it afterwards — so the rendition
  is deselected *before* the output attaches; and a (re)attached output
  re-delivers the line on screen as though it had just started.
- **The engine re-measures only when a line starts**, so between a seek landing
  and that line `sourceTime` still carries the previous seek's lead (off by up
  to 1.8s on device). `ASSSeekHold` paints nothing in that window, gated on the
  engine's own `clock.sourceTimeFollowsPicture` (7.16.0, added upstream at this
  app's request) rather than on seeks the app detects itself. The engine
  re-assigns `false` at every time jump, so the sink must not deduplicate it.
- **The hold gives up after 5s of playback**, because the flag only turns true
  on a line the WebVTT rendition carries and libass can have things to draw
  that it doesn't. That time is summed from small item-time steps, so a pause
  never releases the hold and a seek never counts towards it.

Direct play and offline never need any of this: there `sourceTime` is the
source PTS.

**The user can turn styling off** — Profile → Playback → Advanced → Subtitle
Styling, on by default (`styledASSSubtitlesEnabledDefault`). It sits in
Advanced because it is an escape hatch for a script whose typesetting fights
the phone, not a taste preference. There is exactly one gate,
`PlayerViewModel.handleSubtitleTrackChange`'s `isStyledASSEnabled()` check, and
turning it off makes an ASS track behave like a SubRip one — it still renders,
through `SubtitleOverlayView`'s own path, just unstyled. Read at each track
selection rather than captured, which is as live as it can be observed to be:
the player is a `fullScreenCover` and settings live in a tab behind it, so the
two are never on screen together. Note `isStyledASSEnabled` reads
`object(forKey:)` before `bool(forKey:)` — the latter reports `false` for a key
that was never written, which would ship the feature off for everyone who never
opened Settings.

**Geometry.** libass gets a frame running from the picture's top edge to the
bottom of the overlay, with `ass_set_margins` describing the bar below the
picture and `ass_set_use_margins` on — the documented mechanism for subtitles
in the letterbox bar. Regular dialogue moves into that bar while `\pos` signs,
which are positioned rather than regular, stay anchored to the picture.

**The drawable region is the picture intersected with the safe area**, with the
bottom raised for the transport chrome. The overlay itself must ignore the safe
area to sit over a full-bleed video, so nothing else keeps subtitles off the
rounded corners and the sensor housing — and in landscape the picture fills the
screen, so a corner-aligned sign drew *underneath* them and was physically cut
off. That is invisible in a screenshot, because the framebuffer has no corners;
it only shows on the device. Note the insets come from the window, not from a
`GeometryReader`: one inside an `ignoresSafeArea` view reports zeroes (measured,
not assumed).

**The margins are signed, and in landscape the bottom one is negative.** libass
documents a negative margin as "the frame is inside the video, i.e. the video
has been cropped", which is exactly what landscape is: the picture fills the
screen, so the frame — which stops short of the transport chrome — is shorter
than the picture. Clamping that to zero tells libass the picture ends where the
frame does and maps every `\pos` sign into a too-short rectangle (measured: a
sign at y 20–34 against a correct 29–49, and 30% undersized). Portrait margins
are positive, so the clamp never fired there and the defect was landscape-only.
`ASSSubtitleGeometryTests` pins both orientations.

**Regular events take their font scale from the frame, so landscape needs
`ass_set_font_scale`.** libass scales a regular event to whichever of the frame
and the video area is smaller, while a positioned one always scales to the
video area. In portrait the frame is the taller of the two (it includes the bar
below the picture), so the two agree. In landscape the picture fills the screen
and the frame stops short of the chrome, so dialogue rendered about 7% small at
rest and 28% small with the controls up — measured by rendered *width*, since
glyph heights are quantised too coarsely to see a 7% difference.
`Geometry.fontScale` (`max(1, pictureHeight / frameHeight)`) compensates,
restoring all three of dialogue, `\pos` and `\an8` to the widths they render
at against a full-height frame, and resolving to exactly 1 in portrait so the
common case is untouched. Positioned events are unaffected by it — verified by
measurement, not assumed. Note `ass_set_storage_size` is *not* the knob for
this: it affects aspect ratio and blur, not scale.

An earlier version of this section stated the opposite — that there was "no way
in libass' model to confine regular events to a shorter frame while scaling
them to the full picture". That was wrong; `ass_set_font_scale` is exactly that
knob, and it was missed rather than ruled out.

The frame starts at the picture rather than the overlay so there is **no top
margin**. `use_margins` relocates every *regular* event into the margins and
top-aligned events are regular, so a top margin sends an `\an8` sign into the
bar above the picture — measured at y 9–23 against a picture starting at 324.
The cost is a bare `\an5`, which centres in the frame and so sits low; that is
a real trade in libass' model (only a zero top margin places `\an8` right, only
a symmetric one places `\an5` right, and the bottom bar rules out both being
zero) settled on frequency — typesetting uses `\an8` constantly, while a bare
`\an5` is rare and usually carries a `\pos`, which is exempt anyway. The bottom clearance is **measured**, not constant —
`PlayerControlsOverlay` publishes its chrome's top edge via
`BottomChromeTopKey`, because that chrome's height varies with content (the
chapter/format row is ~48pt and only present sometimes) and because the
controls respect the safe area while the subtitle overlay ignores it.

**Embedded fonts are registered with CoreText, not fontconfig.**
`engine.fontAttachments` (populated from AetherEngine's probe regardless of
`preserveASSMarkup`) are written to a temp directory and registered with
`CTFontManagerRegisterFontsForURL` at `.process` scope. The fontconfig
provider would resolve embedded faces at the cost of every system one — the
wrapper's generated `fonts.conf` declares exactly one directory and no system
font paths. Registration is process-global, so teardown unregisters precisely
what it registered.

**Two routes have no attachments to probe, and both fetch them instead.** A
server-side transcode plays the server's fMP4 HLS through AVPlayer, so nothing
local ever demuxes the source container; offline, the downloaded file is MP4,
which has no attachment streams at all. AetherEngine reports an empty list in
both cases. `MediaSourceInfo.mediaAttachments` carries them regardless of route
(verified live against 10.11.11 — present on the transcode path as well as the
direct-play one), so live playback fetches them from
`/Videos/{id}/{source}/Attachments/{index}` and `DownloadManager` stores them as
sidecars at enqueue, next to the subtitles and for the same reason. Build that
URL from ids rather than reading `MediaAttachment.deliveryUrl`, which the server
fills only when the `/PlaybackInfo` request carried a `DeviceProfile` — the same
trap `MediaStream`'s own delivery URL sets.

Four things about that are load-bearing:

- **The engine's own attachments win whenever it has any** — see
  `PlayerViewModel.assFonts(engineAttachments:fetched:)`. Not a merge: on a
  direct play the two lists are the same faces out of the same container, so
  merging registers each one twice, and a container carrying fonts never probes
  to an empty list, so there is no partial case to serve.
- **Fonts never gate the script.** The script is applied the moment it lands and
  the fonts re-apply when they arrive, costing one extra parse (0.4–1.7ms) on
  the routes that fetch and nothing at all on the common path. Joining the two
  instead would hold a subtitle back for however long several megabytes of CJK
  faces take, purely to change how it looks. `StyledSubtitleJourneyTests`'
  `.slowSubtitleFonts` journey pins this, and was confirmed to fail against a
  build that waits.
- **Not every attachment is a font.** Cover art (`cover.jpg`) is the common
  other case. `JellyfinAPIClient.isFontAttachment` takes any of codec, MIME type
  or filename extension as sufficient — none is reliable alone — with WOFF as
  the single veto, since `CTFontManager` can't register it whatever the codec
  column says.
- **Attachments are rare.** 4 of 932 MKVs in the library this was built against
  carry any, so all of this has to stay free when there are none.


### Features (`Features/*`)

Each feature folder is a vertical slice: a SwiftUI `View` + an `@Observable`
`@MainActor` ViewModel that owns a `JellyfinAPIClient` reference and exposes a
`LoadState`-style enum (`idle`/`loading`/`loaded`/`failed`) for the view to
switch on. ViewModels are constructed with an already-resolved `client` and
`userID` (see `HomeViewModel.init`) rather than reaching into `AppState`
themselves — when adding a new feature screen, follow this pattern rather
than injecting `AppState` directly into ViewModels.

Rail/grid selection logic (what shows up on Home, in what order) is
explicitly a placeholder per the ViewModel doc comments — don't over-invest
in "correct" curation logic there without checking if it's being redesigned.

`CollectionGridView`/`CollectionGridViewModel` (Movies/Shows/Collections
grids) combine a server-side sort (field + ascending/descending, refetched on
change) with client-side filtering across up to five facets — Genre, Studio
(labeled "Network" instead when the query is Series-typed — Jellyfin has no
separate Network field; a show's network lives in the same `Studios` field a
movie's studio does), Decade, Watched, and Favorites. All five are
`Menu`-based pills; Favorites offers All Items/Favorites/Non-Favorites (an
`Optional<CollectionFavoriteStatus>` selection, mirroring Watched's
`Optional<CollectionWatchStatus>` shape) rather than a plain on/off toggle,
so it can filter *out* favorites too. All five are *cascading*: each facet's
own available-options list is computed by applying every *other* active
facet to `items` (never itself — see `CollectionGridViewModel
.matchingItems`'s doc comment), so no combination the UI offers can ever
funnel down to zero results. When adding another facet here, follow that
same "exclude yourself, apply the rest" shape rather than a flat AND filter,
or the funnel guarantee breaks.

### Transient confirmations (`Shared/Components/Toast.swift`)

`ToastCenter.shared.post(Toast(message:))` shows a brief, self-dismissing
capsule; `ToastHost` renders it, applied once as an overlay in `MainTabView`
so a toast outlives whatever raised it. That indirection is the point — the
first thing to use it (adding to a playlist) finishes by *dismissing its own
sheet*, so a confirmation owned by that sheet would be torn down in the same
frame it appeared.

**Use it for "that worked" on an action whose own UI has already gone**, not
as a general notification channel: it can't be dismissed by anything but a
tap or its own timer, and a second post replaces the first rather than
queueing. A haptic alongside it is fine (`AddToPlaylistSheet` does both), but
a haptic alone is not — it says nothing to a user who has them off. Posting
also fires a VoiceOver announcement, since a view that disappears on its own
can't be found by focus.

### Playlist editing, and what Jellyfin actually gates

The app can add items to a playlist (`AssetActionsButton` →
`AddToPlaylistSheet`) and remove them (`PlaylistItemList`'s long-press menu).
Three facts about the server side are load-bearing and none are guessable
from the API docs — all were read out of `jellyfin/jellyfin`'s
`PlaylistsController.cs`/`PlaylistManager.cs` and cross-checked against
`jellyfin-web`'s `playlisteditor.ts`:

- **Creating a playlist has no permission gate at all.** `POST /Playlists`
  is `[Authorize]`-only; `UserPolicy` has `EnableCollectionManagement`, which
  governs *collections*, not playlists. So every signed-in user can always
  create one — which is why "Add to Playlist" renders unconditionally, and
  why the toolbar's `ellipsis` overflow is never empty. Don't add a
  permission check for it. (The overflow is drawn for everyone rather than
  collapsing to a bare add button without delete rights: `CanDelete` only
  arrives with the full item, and swapping a bar button for a menu on iOS 26
  blanks the whole toolbar group — see `AssetActionsButton`.)
- **Adding to and removing from an existing playlist share one gate**:
  `OwnerUserId == caller || Shares.Any(CanEdit && caller)`, refused as a
  clean 403. There is no bulk "which playlists may I edit" query and no DTO
  that exposes `OwnerUserId`, so the only way to answer it is one
  `GET /Playlists/{id}/Users/{me}` per playlist — an N+1 that Jellyfin's own
  web client also performs. `JellyfinAPIClient.editablePlaylists` does it
  with capped concurrency and a fail-soft per check, the same shape
  `collectionsContaining` settled on.
- **Posting a Series or Season id adds every episode beneath it**, in one
  request: `Playlist.GetPlaylistItems` expands any folder-shaped item
  recursively server-side. "Add the whole show" must therefore send the
  show's own id — never a client-side enumeration of episodes, which would
  both duplicate the server's work and be wrong for a show whose episodes
  this client hasn't fetched.

One more, easy to get wrong silently: `CreatePlaylistDto.IsPublic`
initializes to **`true`** server-side, so `CreatePlaylistRequest.isPublic` is
non-optional and always encoded. Omitting it publishes the playlist to every
user on the server. New playlists default to private here, matching
`jellyfin-web`'s own unchecked "Public" box.

### Navigation (`Shared/Navigation/`)

Single shared `AppRoute` enum (`collection`, `assetDetail`, `downloadedAsset`,
`downloadedShow`, `downloadedSeason`) used as the
`navigationDestination(for:)` type across `MainTabView`'s four tabs
(Home/Search/Downloads/Profile). Home, Search and Downloads each own a
`NavigationStack`; Profile owns its own container, because that container
differs by device (a `NavigationSplitView` on iPad). Adding a new
pushable destination means adding a case to `AppRoute` and a branch in
`AppRouteDestinationView`, not a per-feature navigation type.

### Models (`Core/Models/`)

Jellyfin API DTOs (`JellyfinModels.swift`) are kept separate from the app's
own lighter view-facing models (e.g. `MediaItem`, `MediaCollectionRail`) —
DTOs get mapped into app models (usually via an `init(dto:images:)`
initializer) rather than passed directly to views.

**`BaseItemDto`/`MediaItem` equality is structural, and must stay that
way.** Both look like obvious candidates for a cheap id-only `==` (both
did, once). Don't: SwiftUI prefers a stored property's own `==` over its
internal comparison when deciding whether a view changed, and `MediaItem`
is the stored property of essentially every view in the app while
`[MediaItem]` is what `ForEach(rail.items)` diffs on. An id-only `==`
promises SwiftUI that nothing under a stable id is worth repainting —
false for `userData` after playback and for `mediaSources`/`people` when
`AssetDetailViewModel` swaps its preloaded item for the full fetch. The
symptom is a view frozen on stale data while every layer underneath it
holds the correct value, which reads convincingly as a timing bug and
isn't one; it cost six separate `.id(...)` workarounds and a spell of
`os.Logger` calls kept in production before the shared cause was found.
`hash(into:)` stays id-only alongside it — the legal direction for the
`Hashable` contract. See `MediaItem.==`'s doc comment.

### Localization

User-facing strings go through a String Catalog
(`DionysusPlayer/Resources/Localizable.xcstrings`) — only English is
populated for now, but a translation vendor can be plugged in later without
code changes (add a language to the catalog, import their XLIFF). Two
conventions, depending on layer:

- In SwiftUI views, write plain string literals to `Text`/`Button`/`Label`/
  `Section`/`.navigationTitle`/etc. — their `LocalizedStringKey`-typed
  overload is what Xcode auto-extracts into the catalog. This does *not*
  apply to a computed `String` value (e.g. `Text(foo ?? "Bar")`) or a
  parameter on a custom view typed `String` rather than
  `LocalizedStringKey` — neither gets auto-extracted even with a literal
  argument.
- Everywhere else (ViewModels, error messages, model-layer display strings,
  and any of the `String`-typed cases above), wrap the literal in
  `String(localized: "...")` instead.

Server/user-supplied content (item titles, library names, cast/crew names,
...) and industry-standard technical terms or formatted data (codec names,
HDR format names, timecodes, "S1:E4"-style labels, the app's own name)
should stay as plain strings, not wrapped — see `MediaItem.swift` and
`PlayerControlsOverlay.swift` for the reasoning at each such case.

The catalog only gets populated by an Xcode.app IDE build (**Cmd+B**), not
by `xcodebuild` from the CLI — extraction-into-catalog is an IDE/source-editor
feature, not part of the command-line build system. Don't take a build-time
absence of new strings in `Localizable.xcstrings` as a sign something's
wrong; open the project in Xcode and build once to sync it.

**Sync the catalog in the same PR that adds the strings, not as a
follow-up.** Because extraction is IDE-only, neither `pr-checks.yml` nor
`release.yml` (both CLI `xcodebuild`) can ever catch or commit this — it
used to be deferred to a separate "Sync Localizable.xcstrings catalog" PR
discovered well after the fact (e.g. #106, #119), which is exactly the kind
of release-day cleanup this project is trying to eliminate (see
`VERSIONING.md`'s release flow). If a PR adds or changes any
`Text`/`String(localized:)` literal, open the project in Xcode.app and
build once (Cmd+B) before opening the PR, and include the resulting
`Localizable.xcstrings` diff in it.

## Privacy policy maintenance

`PRIVACY.md` (repo root) is the app's App Store-required privacy policy,
also reachable in-app from Profile → Privacy Policy
(`DionysusPlayer/Resources/PRIVACY.md` is a symlink to the root file, same
single-source-of-truth pattern as `LICENSE`/`LicenseView`). It was written
by auditing the app's actual data collection/storage/network behavior, not
from a generic template — if that behavior changes, the document goes
stale in a way nothing will catch automatically (no CI check compares them,
the same gap `Localizable.xcstrings` used to have above).

**Update `PRIVACY.md` in the same PR** as any change that adds a new stored
identifier, a new `NS*UsageDescription`/permission, a new SDK or third-party
dependency, or any network destination other than the user's configured
Jellyfin server — rather than letting it drift and fixing it in a later
cleanup PR.

`PrivacyPolicyView` renders `PRIVACY.md` with a small hand-written
line-by-line Markdown renderer (headers/bold/italic/links/bullets only)
rather than a third-party library — a deliberate call while it's the only
Markdown file bundled in-app (see the view's doc comment for why). **If a
second Markdown file gets bundled into the app** (another legal doc, a
changelog, release notes, etc.), revisit that call — a real Markdown
library (e.g. MarkdownUI) is worth the added dependency once there's more
than one document's worth of rendering to maintain, or once a document
needs constructs the hand-written renderer doesn't handle (nested lists,
code blocks, tables).

## Store screenshots

`store-screenshots/` (repo root) holds the finished App Store Connect
screenshot sets; `Scripts/store-screenshots/{gen.py,shot.swift}` plus the
`Scripts/render-store-screenshots.sh` wrapper is the tool that produces
them from raw Simulator captures. See README.md's "Store screenshots"
section for the two-step workflow (capture, then render) — this section is
only the parts that aren't obvious from reading the scripts themselves.

**Capture against the Jellyfin demo server
(`demo.jellyfin.org/stable`, user `demo`, no password), never a personal
server.** The screenshots are checked into the repo and published to App
Store Connect, so anything they show is effectively public; the demo
server's whole catalogue is public-domain/Creative Commons for exactly
this reason. This was a live correction mid-session once already — default
to the demo server for any future screenshot refresh rather than whatever
server the Simulator happens to already be signed into.

**The demo server has no HDR, multi-track, or chaptered content.** Its
`Movie`/`Episode` items are all SDR H.264, single audio track, no
subtitles, zero chapters (confirmed via a `/Users/{id}/Items` probe across
its ~140 items). A slide claiming Dolby Vision/HDR10/Atmos or showing
chapters/track-picker UI can't be captured live there — either accept the
copy describing the app's real capability (verified elsewhere, see the
top of this file) rather than what's on screen in that one frame, or skip
the claim. Don't invent HDR-looking source video to fake it.

**`xcrun simctl` has no orientation control.** The player slide needs a
landscape capture (a portrait screenshot of the player is ~70% black
bars). Rotate via the Simulator's own UI — `osascript` driving the
Device ▸ Orientation menu works from a script — then screenshot.
`gen.py`'s landscape frame expects an already-upright image: Xcode 27's
Device Hub (`DeviceHub` process, one window showing whichever device is
selected in its source list, so select the right one first) saves it
upright, while the older Simulator app needed `sips -r 270 <file>`.

**iOS defers a download task created while the Simulator is
backgrounded** (same mechanism as `ios-defers-background-created-download-tasks`
in the downloads feature itself) — a Downloads-tab capture queued while
scripting another window will sit at "Preparing…" indefinitely. Foreground
the target Simulator window (`osascript` `perform action "AXRaise"`) and
give it real wall-clock time before capturing that slide.

**The demo server's own transcode jobs restart mid-download** for larger
titles (a `Downloading… 86%` row can drop back to "Preparing download…"
minutes later, unrelated to anything this app does) — expect it, and
either wait out another cycle or pick a shorter title for that slide
rather than treating it as a capture bug.

`gen.py`'s brand colors (`MAGENTA`/`AMBER`) are copied constants, not
computed from `BrandColors.swift` — if that palette changes, update both
by hand.

## Commit messages and pull request descriptions

**Never include a Claude session URL (`https://claude.ai/code/session_...`)
anywhere in a commit message or a PR description** — including as a
`Claude-Session:` trailer. It's an internal reference with no meaning to
anyone reading the repository, and it leaks the existence/id of an otherwise
private session. Git history is permanent and public, which makes a commit
trailer the worse of the two.

Attribution itself is fine and wanted: keep `Co-Authored-By: Claude ...` on
commits and the "Generated with Claude Code" line on PR descriptions. Only
the session link is excluded.

This overrides any per-session attribution instruction that asks for the
trailer — those are generated by the tooling rather than chosen here, and a
session that receives one should drop the session-URL line and keep the rest.
