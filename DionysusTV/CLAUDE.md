# The Apple TV app

Loaded when working in `DionysusTV/`. The root `CLAUDE.md` has the target's
shape (what it compiles, `#if DOWNLOADS`); `TESTING.md` has the tvOS suites
and CI. Design, decisions and milestones:
`docs/superpowers/specs/2026-09-29-tvos-app-design.md`. Facts marked with a
tvOS version were measured there; tvOS 26 and 27 behave differently, and 26.0
is the floor.

**The icon can't be `dionysus.icon`**: actool compiles no tvOS icon from an
Icon Composer file and wants an "App Icon & Top Shelf Image" brand-assets set.
`DionysusTV/Resources/TVAssets.xcassets` is rendered from `dionysus.icon`'s
gradient and glyph by `Scripts/render-tvos-app-icon.py` (ImageMagick); re-run
it and commit the result whenever the iOS icon changes.

## The shell: sidebar and pages

**The shell is a custom sidebar, not tvOS's `TabView` one** (`TVMainView`,
`TVSidebar`), since the system's looks nothing like the prototype (screens 5,
6, 6b). Collapsed, it's a glass icon rail on the left of every signed-in page
(not onboarding, not the player), except Search, where it slides off the left
edge. Open (whenever a row has focus) it's a 520pt glass panel of pill rows,
the page pushed right and dimmed. Profile is pinned at the top (avatar, name,
server; VoiceOver reads "Profile & Settings"), then Home, Search and the
libraries; above five they sit under one "Libraries" row that starts open and
closes in place (`TVSidebarLayout.rows(libraries:librariesExpanded:)`). A
library load that failed at launch is retried whenever the rail takes focus.
Library icons come from Jellyfin's `CollectionType` (the admin's "Content
type"), never the name.

**Every row but the Libraries group is a top-level page** (Benjamin,
2026-10-01). Left from a page's leftmost item, or Menu on a page, opens the
rail on that page's row; Menu with it open has no handler, so tvOS leaves the
app. Choosing a row opens its page, collapses the rail and focuses the page's
first item. Where the shell is and which rows can take focus is
`TVShellNavigation`, unit-tested.

**Every page sits in `TVPageScaffold`.** The shell draws the plum glow once
beneath every page (a page drawing its own faded in with it, showing black
for a frame). A page's own background fills the screen behind the rail; its
content starts right of the rail (`TVShellMetrics.contentInset`, a 56pt gap,
what a focused control's platter needs; at 40pt it was sliced off) and is
clipped there. Home is the exception (`layout: .besideRailScrollingUnder`,
Benjamin, 2026-10-05): its rails keep drawing under the glass when scrolled
right, while each rail's first tile still starts at the inset. Lifting the
clip wasn't enough (a rail's row ended at the inset, so the lazy stack tore
down tiles scrolled past it), and widening the row let tvOS scroll the
focused tile under the sidebar (content margins and safe-area padding both
tried). So Home's rows keep their bounds and build every tile at once
(`TVRail.buildsEveryTile`, an `HStack`). The clip is visual only; check it by
screenshot.

**Only the page on show is built, and the player is laid over it** (Benjamin,
2026-10-01, the app being image heavy). Choosing another page tears the old
one down; the shell owns Home's, Search's and each library's view model, and
each page remembers its focused item, so it comes back as it was.
`TVPlayerPresenter` presents the player over the page, which stays alive
beneath, so leaving it is immediate with scroll and focus intact. It refuses a
second player while one is anywhere in the presented chain
(`canPresent(over:)`): a second Select on the hero's Play stacked two. The
player used to tear the shell down (`TVPageStack`, removed): the rebuilt page
asked a lazy grid to focus a tile it hadn't built, and anything below the
first screen came back at the top.

### Focus: what cost a debugging session each

- **Collapsed, only the page's own row is enabled**
  (`TVShellNavigation.focusableRows`). The rail's focus section spans the
  screen's height, so Left from any height lands on that row. A folded
  library's row isn't drawn collapsed, so the Libraries row stands in, and
  focus moves on to the library once the panel opens.
- **Each page claims focus itself** (`tvClaimsFocus`): its first item on
  arrival and on each handoff from the sidebar, the remembered one when
  rebuilt. Never with `.defaultFocus`: on Profile it pulled every later move
  back to Switch User, so Change Server was unreachable.
- **Every claim holds the rail until it lands** (`tvPageClaimingFocus`). A
  page claims its spinner, then its first item when data arrives; on tvOS 26
  the spinner's removal makes tvOS pick focus itself before the claim lands,
  and with the rail free it went there and opened it after every sign-in,
  library and search (tvOS 27 honours the claim, so only a 26 Simulator shows
  it).
- **Handing focus from the sidebar to a page needs the focus system asked.**
  Choosing a row holds the rail disabled and calls
  `UIFocusSystem.requestFocusUpdate(to:)` on the window's root; disabling a
  SwiftUI view alone never moved focus. That is what reaches Search's
  keyboard, a UIKit control SwiftUI can't focus. The rail stays held until the
  page reports its claim (`tvPageClaimedFocus`), on a fresh shell too, and is
  released only once focus is in the page, asking again until it is: on a
  loaded CI machine Search's keyboard joined the window after the claim, and
  the freed rail opened over Search (2026-10-09). After three seconds with
  focus nowhere (an empty library) focus goes to the page's row, since Menu
  reaches nothing then; the same goes for focus pushed onto Profile's row
  while the rail is held.
- **Right out of the sidebar returns to the item the page last had**
  (`tvRailReturn`). tvOS picks whatever sits nearest the row it leaves (on
  Home, the hero's Play, however far down focus had been). The shell bumps it
  when focus leaves without a row chosen; the page takes what it had when the
  rail opened, since tvOS's own move lands first and is remembered.
- **Each page's content is a focus section**, so Right from any row enters it
  (Profile's buttons are level with no row). Left from Search's keyboard stays
  in the keyboard; Menu still opens the rail there.

### Pushed pages

**Detail pages and See All grids are pushed onto a path inside the shell**
(`TVShellNavigation.path`), beside the rail; every tile opens a detail page,
never playback. Menu pops before it opens the rail; choosing a row drops the
path. The root, the top page and the two beneath it stay built
(`TVPageKeepAlive`, Benjamin, 2026-10-01), hidden and disabled, so Menu
returns to a page exactly as it was; deeper ones are rebuilt from their view
model, which the shell keeps per path entry.

- **Pushing and popping hold the rail** (`holdRail()`): the focused tile is
  disabled as its page is covered, and tvOS otherwise hands focus to the rail
  and opens it.
- **A page coming back on show claims its item more than once.** As it's
  enabled tvOS focuses its first item and drops a claim made in the same
  pass, so `tvClaimsFocus` fixes the target when the page is covered and sets
  it until it holds (`tvPageIsOnShow`). Search does the same by hand.
- **A hidden page claims nothing and remembers nothing** (the `tvPageIsOnShow`
  guards), or it would answer for the page above it. A page refreshes its data
  when it comes back on show, without tearing down its views.
- **A page coming back on show ignores tvOS's focus on its header for a
  moment** (`TVDetailLanding.settling`): tvOS focuses Play before the page
  restores its tile, and taken at its word that scrolled to the top and cut
  off a Continue Watching tile (Benjamin, 2026-10-07).

**Away from its landing view, Menu first takes a page back to it**
(Benjamin, 2026-10-07; `tvMenuReturnsToLanding`): to the top with focus on
the item the page opens on; Menu again pops or opens the sidebar. "Away" is
focus below the header on Home, a movie's and a show's page; scrolled from
the top on a box set, a playlist, a grid and Profile; and focus in Search's
results or on Clear, where Menu goes back to the keyboard with the query kept
(through `tvFocusPageDefault`, the handoff choosing the row uses). At the
landing view the page's handler is `nil`, so the shell's runs. After a long
scroll the lazy stack may have torn the landing item down, so the page
scrolls up first and sets focus until it holds; the grid waits for its scroll
to land.

## Home

**`TVHomeView` runs on the shared `HomeViewModel`**: the hero over a
full-bleed backdrop, then the rails in iOS's order with See All tiles. No
Libraries rail (Benjamin, 2026-10-05): the sidebar lists them. Every tile's
caption always shows.

- **The hero's timer runs only when everything allows it**
  (`TVHeroPager.timerRuns`): more than one item, Auto Carousel on, no Reduce
  Motion, no VoiceOver, not under the UI-test harness, the hero focused, Home
  on show, and no page turned by hand this visit. It waits ten seconds
  (Benjamin, 2026-10-04; iOS uses five).
- **Paging by hand is forward only, and wraps** (Benjamin, 2026-10-04): an
  invisible focus guard right of More Info turns the page when it takes focus
  and hands focus back. Nothing is left of Play, so Left there opens the rail.
  Under VoiceOver the guard isn't focusable; the hero's buttons carry a "Next
  Item" accessibility action instead, which announces the item it turns to
  (focus stays on the button, whose label doesn't change), as iOS's does.
- **The current page dot fills over the interval while the timer runs**, and
  is solid white while stopped (Benjamin, 2026-10-04).
- **The hero holds only titles with a backdrop of their own**: the random
  fetch asks for `ImageTypes=Backdrop` (Benjamin, 2026-10-04), on iOS too,
  since the view model is shared. The logo crossfades with the backdrop
  (`TVHeldImage` keys each picture's view, so old and new overlap).
- **Play on a series plays an episode** (`TVHeroPlayTarget`): its Next Up, or
  the first episode of a show never started.
- **Leaving a player started from the hero lands on the title's detail page**
  (Benjamin, 2026-10-04), pushed over Home so Menu goes back to the hero
  (`tvOpenDetailBeneathPlayer`). It's pushed beneath the player and counts as
  not on show until the player closes, then claims Play as a page coming back
  does. Full-screen presentation takes the page out of the window, cancelling
  its `.task`, so `AssetDetailViewModel.loadIfNeeded()` loads in a task of its
  own (as `HomeViewModel` does); cancelled, a show's episode lookups failed
  quietly and it loaded with no Play.
- **More rails load for as long as the spinner below them is built**, in a
  loop, each batch in a task of its own (Benjamin saw it spin for good,
  2026-10-05): a batch whose candidates were all too thin, one that didn't
  move the spinner out of the lazy stack, or an appearance mid-load left
  nothing to ask for the next batch. (iOS's `ScrollBottomObserver` exists for
  the same reason: a row's appearance isn't a reliable trigger.)
- **Rails are keyed by title**, in focus ids and `ForEach`: a rail's id is new
  with every refresh, and Home refreshes when it comes back on show, so keyed
  by id the rails were rebuilt, scrolled back to their start, and focus
  couldn't return to a See All.
- **The hero sits outside the rails' `LazyVStack`**, so Menu-to-landing's
  focus write always names a built view (see "VoiceOver").
- The hero's height is the detail pages' (`TVDetailMetrics.headerHeight`), so
  Play lands without a nudge, and the page returns to its top when focus goes
  back up. The backdrop fades out once focus is below the hero, leaving the
  plum glow, and back in when focus returns (Benjamin, 2026-10-04).

## Detail pages

**On a detail page Down walks a row at a time** (Benjamin, 2026-10-02): the
actions, Cast & Crew, More Like This, Details. Cast tiles take focus though
Select does nothing (there's no person page). The action row's focus section
spans the page's width (`TVDetailActions`); hugging its buttons, Up from a
cast member right of Favorite found nothing. Details is a summary; Select
opens the full list over the page (`TVFullDetailsView`: iOS's Details rows and
every audio and subtitle track, per version, in focusable sections, since a
tvOS scroll view moves only with focus). The backdrop blurs and dims once
focus is below the header.

**While focus is in the header, the page sits at its top** (Benjamin,
2026-10-02; `TVMovieDetailView.restoreLanding`, shared as `tvDetailLanding`
with `TVDetailMetrics.headerHeight`):

- **The header's height is what makes the top the landing position.** Too
  tall and tvOS nudges the page down as Play takes focus: 60pt at 860, 16pt at
  800, 4pt at 784, none at 776 (measured frame by frame). Measure before
  changing `headerHeight`.
- **The header holds space for what arrives late.** A tile hands the page a
  lighter copy of the item; badges, credits and sometimes the overview come
  with the full fetch, seconds later from a cold server. Those rows keep their
  space and text rows reserve their full line count, so the logo doesn't
  jump.
- **tvOS's own focus scroll can start after ours and win**, at no fixed delay,
  so the page is also sent back whenever a scroll comes to rest
  (`onScrollPhaseChange`) with focus in the header.
- **`ScrollPosition` measures from the inset top**:
  `contentOffset.y + contentInsets.top` is zero at the top; scrolling to the
  raw offset sat 60pt high.

**Shows, box sets and playlists have their own pages** (`TVDetailPage`
chooses by kind), all on `AssetDetailViewModel`.

- **A show's episodes live in `TVSeasonEpisodesModel`**, a season at a time
  (iOS keeps them in a view; here the shell rebuilds pages).
- **Play is drawn before the show's episode is known**
  (`TVDetailActions.isResolving`), or focus lands on Watched and Play appears
  beside it. With nothing to play, Play goes and focus is sent to Watched
  (left alone, tvOS moved it up to the synopsis).
- **The season tabs follow focus** (Benjamin, 2026-10-02): the focused tab is
  the season on show, no Select. Into the tabs, focus goes to the season on
  show, not the tab nearest the control left (Season 2 from Play), as the
  row's default focus at `.userInitiated` priority: redirected after tvOS's
  own pick, that tab drew focused for a frame (Benjamin, on device,
  2026-10-05). The redirect stays as a fallback.
- **A show's format badges are the episode's that Play starts**, read from the
  season's episode list (fetched with `detailFields`), since a series has no
  media source. The row's space is always held.
- Below the episodes: Cast & Crew (`TVCastRail`; the episode's own people when
  on one), More Like This and Details (`TVDetailsPanel`): the episode the page
  is on, else the one Play starts, named beside the heading (Benjamin,
  2026-10-02), never the show, which has no file.
- **A show's page is on the series or on one of its episodes.** An episode
  tile from Home opens it on that episode; Select on an episode in the rail
  turns the page to it in place with focus on Play (Benjamin, 2026-10-02;
  `chosenEpisodeID`). On an episode, its name, overview, Details and Play are
  the episode's; Watched and Favorite act on the show, as on iOS. Not a push:
  Menu leaves the show.
- **A show page's imagery follows what it's on** (`TVShowDetailView.artItem`):
  the episode; on the series, the episode Play starts (Benjamin, 2026-10-05),
  so per-season art shows the right season's; otherwise the show. A season
  tab taking focus changes nothing (browsing isn't choosing). That covers the
  backdrop, logo and side image. The episode→season→show fallback is
  Jellyfin's: it names the nearest ancestor with a backdrop or logo on every
  item (`MediaItem.backdropImageURL`/`logoImageURL`). What's on screen is held
  until the next image loads, then faded (`TVHeldImage`).
- **Box set tiles open detail pages; playlist rows play**, with the playlist
  as the queue. Over a backdrop neither has the tall header, so the backdrop
  blurs by scroll offset (`tvDetailDimsWhenScrolled`). Without one the header
  takes the first screen with the poster beside the title
  (`tvDetailHeaderFrameWhenNoBackdrop`, Benjamin, 2026-10-05); a playlist's
  Play sits at its foot.
- **An empty page shows a message that takes focus**
  (`TVDetailEmptyMessage`), **and a page still loading does the same with its
  spinner** (`TVDetailLoading`, on every detail page and on Home and a
  library): with nothing focused, Menu reaches nothing, and the shell's
  three-second fallback opened the sidebar, where Menu left the app.

**A title with no backdrop shows its poster or thumb beside the title**
(Benjamin, 2026-10-02; `TVDetailHeaderArt`): a movie's, box set's or
playlist's poster; a show's or episode's thumb, failing that an episode's
still or a show's poster. It sits in the header and scrolls with it, and the
page draws no backdrop, leaving the glow. A poster stands at the header's
foot; a thumb or still is wide enough to reach the synopsis there, so it sits
top-right (Benjamin, 2026-10-07). A backdrop loading or failed draws nothing
(`AsyncRemoteImage.showsPlaceholder`). The art is an accessibility element
with a label, not hidden, or XCUITest can't see it.

The player reports where it stopped (`TVPlaybackSession.end()` returns the
outcome once, through `TVPlayerPresenter.present(_:queue:client:userID:onClose:)`),
so the page beneath shows the new resume point at once.

## Library and See All grids

**A library's page and a See All grid are `TVCollectionGridView`** on the
shared `CollectionGridViewModel`: a title and count, the five cascading
filter pills with iOS's symbols (filled or struck while set), Reset while any
is set, the sort pill at the right, and six columns of posters with captions
always shown (Benjamin, 2026-10-02).

- **The posters are a UIKit collection view** (`TVPosterCollection`), for the
  system's alphabet index, offered only while sorted by title
  (`indexTitles(for:)`, letters from `TVAlphabetIndex`, Z→A with "#" last when
  descending, so the bar runs the grid's way; Benjamin, 2026-10-05). SwiftUI's
  `sectionIndexLabel` is for `List` only.
- **Each cell is the system's `TVPosterView`, not the app's SwiftUI tile.**
  Hosted in a cell, the SwiftUI tile held focus UIKit couldn't see: Up from
  the top row went nowhere, and releasing the index left every button dead
  (Benjamin, 2026-10-03). Badges and the loading glyph are SwiftUI hosted in
  the artwork's `overlayContentView`, so they lift with it. The caption is the
  system's labels restyled (`TVCaptionedPosterView`): semibold over a
  secondary caption2, one line each, leading-aligned by a footer subclass
  (`TVLeadingCaptionFooter`), the style put back on every focus change.
- **A cached image is set a pass later, as a fetched one is**
  (`TVPosterCell.show`). Set while the cell was configured, the poster kept
  its artwork uninset and the focused poster ran over its caption, on every
  return to a cached grid. **Until artwork arrives, or with none, a clear
  stand-in image is set the same way** (`showStandIn`): with no image the
  system draws the artwork uninset, larger than its neighbours.
- **The posters follow ancestor focus, and SwiftUI focus counts as an
  ancestor's** (`TVPosterCollectionView.didUpdateFocus`, measured
  2026-10-12). While SwiftUI holds focus (the sidebar, the pills, a page
  pushed over the grid) the root hosting view reports `isFocused`, so a poster
  built or left under it takes the focused look, and UIKit tells only the
  posters on the focus chain when focus moves. On tvOS 26 that drew every
  poster of a freshly opened grid at its lifted size, over its caption; on 26
  and 27 the poster focus last left kept its caption lowered. So when focus
  enters the grid from outside, every other visible poster is made to look
  again: its `adjustsImageWhenAncestorFocused` turned off and on (the
  artwork), and that focus update handed to it (the caption). Turning the
  setting off for good draws the artwork flat, square and uninset, with no
  lift. **Known issue, tvOS 26 only** (Benjamin, 2026-10-12: every tvOS 26
  device can update to 27): while focus is outside the grid, the poster it
  left still looks focused, and posters reloaded from the header (a sort or
  filter) are drawn lifted until focus comes back down. tvOS 27 fixed the
  artwork; closing it on 26 would need a poster that draws its own lift.
- **Focus is put on a poster through SwiftUI, not UIKit.** A focus update
  requested of a cell while SwiftUI holds focus in the header was refused
  every time. So the grid is its scope's default (`prefersDefaultFocus`),
  `TVPosterCollectionView.preferredFocusEnvironments` names the target cell,
  and `resetFocus` asks, followed by a focus update from the window's root (the
  reset alone left focus on the rail one time in four): on arrival, a handoff
  from the sidebar, and back on show, held until it sticks. Focus inside the
  grid is remembered from the collection view's own updates.
- **The header (title, pills, open list) is SwiftUI drawn over the grid**,
  offset by its scroll; inside a cell it would be another SwiftUI hierarchy
  from the page's focus state. A pill taking focus scrolls the grid to its top.
- **The pills aren't SwiftUI `Menu`s** (`TVDropdownPill`, `TVDropdownList`). A
  tvOS `Menu` gives focus back about 1.3 seconds after a choice, with nothing
  focused between; ours closes with focus on the pill the next frame
  (Benjamin, 2026-10-02). The open list is laid over the page from the pill's
  bounds, not hung from it, since the pill row is a focus section that
  confines movement to its frame; focus is held on the pill a moment after a
  choice while the grid reloads. Menu closes an open list, as does focus
  leaving it. A pill's text is one line, cut with an ellipsis past 260pt
  (`TVDropdownPill.maxTitleWidth`).
- **Reset appears only while a filter is set** and clears all of them; focus
  then goes to the first pill.
- **A cell answers `canBecomeFocused` itself (false).** Left to UIKit, the
  collection view could reload its data to answer, and asked while a See All
  grid was popped with a poster focused, that reload reused the focused cell
  and UIKit's focus system aborted the app. A list change is reloaded at once
  (`reloadData`, then `layoutIfNeeded`).
- **The grid reloads when it comes back on show** and keeps its place. A title
  that drops out (marked watched in an Unwatched grid) hands focus to the
  tile that took its place. Focus placement looks its target up by id every
  attempt: an index path kept across that reload was past the end and
  `scrollToItem` aborted the app. A refresh keeps the scroll position; a
  change from the header (filter, sort) starts at the top.

## Tiles

- **Every rail and grid chooses one tile shape** (`TVTileShape`, Benjamin,
  2026-10-05): posters when every item is movie-like, landscape thumbs when
  any is a show or episode (`MediaItem.usesLandscapeRailTile`, as iOS's
  rails), so a mix is landscape. On Home, More Like This, box set members,
  playlist rows, Search's rails and the grids, where landscape is four 16:9
  columns (`TVTileMetrics.gridLandscape`). A grid's shape comes from every
  item, not the filtered ones. (iOS's own library grid is always posters.)
- **An episode tile carries its show's logo bottom-left**
  (`TVEpisodeLogoOverlay`, as iOS's `episodeLogoOverlay`; Benjamin,
  2026-10-05), over a bottom gradient, raised clear of the progress bar.
  Only episodes, only when Jellyfin names a logo up the chain
  (`TVEpisodeLogo`); no text stands in.
- **A tile's caption moves down with the artwork's lift while focused**
  (`TVTileCaptionText`, `TVTileMetrics.captionLift`; Benjamin, 2026-10-04):
  `.card` grows the focused artwork about 10% (a 375pt poster's bottom drops
  19pt), and the poster ran over a caption left in place. The grid's system
  posters do this themselves.
- Tiles speak their badges as an accessibility value ("Watched",
  "Favorite"), since the badges are drawn.

## Search

`.searchable` draws its field only inside a navigation container, so Search
sits in a `NavigationStack`. It lists every kind the server returns as rails
by type in a fixed order, Other last (`TVSearchGrouping`). While the field is
empty it shows Recent Searches: the results last opened (the history
`SearchViewModel` shares with iOS), grouped into the same rails under one
heading with Clear beside it (Benjamin, 2026-10-04); with none, iOS's "Search
Your Library" placeholder. **The recent rails are keyed apart from the
results'** (`recentKey`): sharing ids, the lazy stack kept a results rail on
screen once the field was emptied. Its tiles have no badges (search hints
carry no user data). **Choosing another page from the sidebar leaves Search,
which starts fresh** (Benjamin, 2026-10-04;
`TVShellNavigation.selectionLeavesSearch`); a detail page pushed from Search
keeps the query.

**Limitation: the system search UI must be full screen** (Benjamin,
2026-10-04). `.searchable`'s field, keyboard and hint are laid out for the
window's width: beside the rail, every inset, width and scale tried (tvOS 27)
lost the first keys, ran the hint off screen or cut it at the container. Our
own field would lose dictation, Continuity Keyboard and suggestions. So Search
uses the system's full-screen layout (`TVPageScaffold(layout: .fullScreen)`),
and the shell slides the collapsed rail off the left edge
(`TVShellNavigation.hidesCollapsedRail`; 400pt, since at its frame's width
some glass still showed), with a chevron mid-left saying where it went
(`TVEdgeChevron`, `showsEdgeChevron`). Menu, or Left from a result in a rail's
first column, slides the sidebar in on Search's row; Right hands focus back
as choosing the row does (`handFocusToPage`), since tvOS finds nothing right
of the row by itself. A page pushed from Search has the rail as usual.

The Simulator's on-screen remote sends Select as a keyboard Return, which the
system keyboard takes as a typed Return, so Select types nothing there; a
Siri Remote press (and XCUITest's remote) does.

## Profile and settings

**Profile is the only way to settings** (`TVProfileView`, prototype screen
11): the avatar, name, server, address and both versions on the left; the
settings as rows on the right (`TVSettingsRow`), in iOS's sections minus
Downloads, Theme and 3D Depth Effects: Account (Switch User, Approve Quick
Connect Code while the server has it on, Sign Out, Change Server), Apple TV
Users, Appearance (Auto Carousel), Playback (Next Episode Countdown, Chapters
in Scrubber, Advanced) and About (License, Privacy Policy), with iOS's
footers.

- **Select on an on/off row flips it; a setting with more choices opens a page
  of them** (`TVSettingsPicker`, Benjamin, 2026-10-05): the countdown,
  Streaming and Max Streaming Bitrate. The current choice is ticked and
  focused; Select picks and closes, Menu closes unchanged. Not a SwiftUI
  `Menu`, for its late focus return. A row's value is its accessibility value,
  which is localized, so journeys compare it before and after, never to "On".
- **A row that opens a page shows a chevron** (Benjamin, 2026-10-05), beside
  its value when it has one. Advanced has none to preview.
- **Sign Out forgets the account on this Apple TV**
  (`AppState.signOutForgettingAccount()`); Switch User keeps it, one press
  away on Who's Watching? (Benjamin, 2026-10-01). Sign Out and Change Server
  ask first (`TVConfirmation`, Cancel focused; Benjamin, 2026-10-05), and both
  rows are red: a red title on the resting glass, a red platter with a white
  title in focus. **The rows draw their own platter**
  (`TVDestructiveRowStyle`, sized to the system row's, measured on 26.5).
  The system can't: its destructive role draws a red title on a red platter
  at rest on tvOS 26 (Benjamin, 2026-10-11), and a red tint does the same.
  Taking the role only while focused showed the grey platter for a frame as
  focus left the row, on 26 and 27 (Benjamin, 2026-10-13): SwiftUI's focus
  moves a frame before the system's platter does, so a look that mixes the
  system's platter with focus state races it. Check a change here by
  recording the Simulator and reading it frame by frame.
- **Each sub-screen is a full-screen cover** (Advanced, Quick Connect
  approval, the two text pages, the two questions), so Menu closes it onto its
  row; a push would put the sidebar beside it.
- **License and Privacy Policy are cut into focusable paragraphs**
  (`TVTextPageView`), since a tvOS scroll view moves only with focus; both
  files are bundled into `DionysusTV` (`project.yml`).
- **Every Playback setting works on tvOS.** The chapters and stats keys live
  in `PlayerPreferenceKeys.swift` with the carousel's, since tvOS doesn't
  compile the iOS player views; Show Playback Stats Button keeps iOS's
  default (on in debug builds, off in release).

## Onboarding and accounts

**Find Your Server's Rescan** appears once a scan is over and scans again from
an empty list (`ServerSetupViewModel.rescan()`, Benjamin, 2026-10-05); iOS's
Scan Again keeps the old list until the first answer. Once the address field
is open, Enter Server Address heads it as text. **The field claims focus
until it holds**: the button it replaced goes, so tvOS hands focus to the
server list's default, which beat a claim made as the field appeared.

**Sign-in puts Quick Connect first** (`TVSignInRoute`): a user with a password
goes to a code, with "Use Password Instead" one press away; only a user the
server reports as passwordless signs in on Select.

**Each Apple TV user has their own session.** The target runs as the current
Apple TV user (`com.apple.developer.user-management` =
`runs-as-current-user-with-user-independent-keychain`), so `UserDefaults` and
the Keychain are per user, and tvOS terminates and relaunches the app on a
user switch: there is no in-app user-change event. The server configuration
is the household's: `ServerSessionStore.ServerLocation.platformDefault` puts
it in the keychain every user shares (`KeychainStore.Scope.allUsers`), where
it survives a reinstall. Credentials carry the server that issued them
(`StoredCredentials.serverID`) and are discarded at launch when another user
has changed it. **`DeviceIdentity.deviceID` must stay per user**: Jellyfin
revokes a user's older token on the same device id
(`SessionManager.GetAuthorizationToken`), so a shared id would sign one
person out whenever another signs in to the same account.

**Every account signed in is remembered, on tvOS only**
(`ServerSessionStore.RememberedAccounts`), as the fallback for the system bug
below, in the current user's keychain, not the shared one (which would hand
each person's session to everyone). Who's Watching? lists remembered accounts
for the configured server first, most recent first, five lockups to a row
("Other" included) before it scrolls (`TVWhosWatchingLayout`); one press signs
one in the way launch restores a session
(`AppState.signIn(rememberedAccount:)`: stored password, or a validated Quick
Connect token). Switch User keeps the list; Change Server clears it; holding
Select offers Forget This Account. An account the server now refuses goes to
its password screen with the reason (or a new code) and stays remembered; an
unreachable server says nothing about the account.

**Profile's "Follow Apple TV Users" can turn per-user sessions off**
(`SessionScopeSetting`, on by default), stored in the shared keychain, since a
per-container value would flip with the very bug it exists for: one setting
for the whole Apple TV. Changing it moves the session between the per-user
and shared keychains (`ServerSessionStore.moveSession(to:)`), written to the
destination before it's deleted from the source and merged, never
overwritten. Off, every remembered account moves and every user shares one
sign-in and list (PRIVACY.md says so). Back on, only the account in use moves,
ahead of that user's own; the rest of the shared list is deleted, since other
people's passwords don't belong in one person's keychain. It can't change
which container tvOS launches into; preferences and the device id stay per
container. Another user's per-user session left while it was off is untouched.
The UI-test reset clears the settings and the shared session too.

**With Follow off, "Select a User Every Relaunch" starts each launch at Who's
Watching?** (Benjamin, 2026-10-01; `WhoIsWatchingPolicy`, on by default,
shown only while Follow is off, stored beside it). `AppState.start()` signs
out the way Switch User does, with no request. With exactly one remembered
account it signs straight in; and since tvOS suspends the app through sleep,
returning to the foreground after 30 minutes counts as a relaunch
(`TVRootView` watches `scenePhase`, closes the player, signs out). Off, the
app stays on whoever was signed in. An unreachable server leaves the person on
Who's Watching?, where a launch otherwise resumes from cache.

**tvOS's user switching is unreliable, and no app can fix it.** On the
Bedroom Apple TV (tvOS 27.0, 2026-09-30) the per-user split worked (a
secondary user in `/var/PersonaVolumes/<id>/…`, the primary in
`/var/mobile/…`), but cold launches repeatedly ran in the *other* user's
container, and installing from the Mac made it worse. It's the system bug in
Firecore's "User Switching Broken (tvOS 26.4)" thread (fixed in 26.6, reported
recurring on 27). Don't debug it as an app bug or design anything that
assumes the container matches the Apple TV user. To check which container a
launch got, print `NSHomeDirectory()`.

## Accessibility

**A page's `.accessibilityHidden(false)` overrides every
`.accessibilityHidden(true)` inside it.** `TVMainView` once set
`.accessibilityHidden(!onShow)` on each page, which put the avatar and every
backdrop in the tree (found by the audit). Hidden pages stay out of the tree
without it; set a hidden modifier only where it is always `true`.

### Display settings

Checked by screenshot on the tvOS 26.5 Simulator, each setting alone (M5).

- **Under Reduce Transparency tvOS draws a default-style button's resting
  platter opaque light grey** under the label's white (about 2:1): every
  Profile row, filter pill and hero button. Forcing dark changed nothing.
  `TVOpaqueAtRestButtonStyle`, set once at the root, tints it to the grey
  Apple's Settings rows rest on and makes the label primary, since the tint
  colours it too; focus is the system's as before, and a button with a style
  of its own is untouched. It's a button style, not a root tint, because
  spinners follow the tint. Glass and materials go opaque by themselves.
- **Under Reduce Motion nothing slides** (`TVMotion.moving`): the sidebar
  opening, sliding off on Search and its Libraries group, Menu's scroll back
  to the top, the player's panel rising and the subtitles' lift land at once.
  Fades stay, the hero's page turn included.
- **Under Increase Contrast, translucent white over artwork is drawn solid**
  (`TVContrast.opacity`: the hero's, a box set's and a playlist's overview,
  the sidebar's server name, a grid poster's caption, Search's edge chevron);
  `.secondary` brightens by itself. Hand-made translucency doesn't, so new
  text drawn that way goes through `TVContrast` too.
- Bold Text clipped nothing.

### VoiceOver

Measured on the tvOS 26.5 Simulator, VoiceOver's speech read from its log
(`category == "VOTSpeech"`; `TESTING.md` has how). None of this is guessable:

- **Menu arrives as VoiceOver's escape command**, which SwiftUI still hands to
  `onExitCommand`. What broke was Menu-to-landing: a focus write naming a view
  the lazy stack tore down is refused, and under VoiceOver a `ScrollPosition`
  scroll never starts while focus stays put (20 refused writes; Benjamin,
  2026-10-10). So **a landing item must stay built**: Home's hero sits outside
  its `LazyVStack`. Asking the focus system as well only reached the nearest
  built tile.
- **VoiceOver reads what sits beside the focused button but skips an element
  with the header trait**, so `TVDetailHeader`'s title has none (the hero's
  and every detail title went unread). A grid's title is still never read:
  focus lands on a poster or a pill, and neither dropping the trait nor
  naming the grid a container for it changed that (M5 review, 26.5). It passes over a header-trait heading
  however it sits, so Profile's sections, its pickers, Advanced and Recent
  Searches are containers named for their headings, which also keeps the
  read-ahead inside them. (It still runs on into the collapsed rail after a
  section's last row and on arrival; sorting the rail first and making the
  page a container changed nothing.)
- **A disabled button is read as content** ("dimmed") after each move, so the
  collapsed rail hides the rows it can't focus
  (`TVSidebarLayout.isHiddenFromAccessibility`, unit-tested since XCUITest
  still lists them). On tvOS 27 the one row left reports the whole rail's
  frame, so journeys read collapsed or open from the sidebar container's
  width (`TVShellJourney.isCollapsed`).
- **A container's label is spoken as focus enters it** with
  `.accessibilityElement(children: .contain)`: the sidebar ("Sidebar") and each
  rail. Without `.contain` the label and identifier land on every child.
- **VoiceOver names only the innermost container focus enters, and a lazy
  stack or a scroll view is a container of its own.** So `TVRail`,
  `TVCastRail` and a long dropdown list name their lazy or scrolled rows as
  well; the two names are said once.
- **The open sidebar is modal** (`.isModal`), or VoiceOver read the dimmed
  page behind it.
- **VoiceOver's read-ahead passes over a tile that holds an image, and reads
  one without**: past a rail's end it spoke the tile whose artwork had failed.
  So on tvOS `AsyncRemoteImage`'s placeholder sits over an empty `Image` (an
  image trait instead made it read "Image" and an identifier).
- **A button's label joins every text inside it**, so a settings row read its
  value twice: `TVSettingsRow` labels itself with its title alone.
- **A footer is never reached** (focus moves only between buttons), so each
  settings footer is also its row's hint, and hidden itself.
- **Results and outcomes are announced** (`TVSearchGrouping.announcement`,
  a failed search's reason, Quick Connect's approval), since focus stays in
  the keyboard or on the button.
- **Compact text needs a spoken form** (Bedroom device pass, M5): on tvOS 27
  "1h 48m" was read "1 H 48 meters" (26.5 happens to expand it, so the
  Simulator hides this). Runtimes use `MediaItem.durationAccessibilityText`
  (`TVDetailFormat.metadata` carries both forms), and format abbreviations
  in track text go through `MediaItem.spokenFormats(in:)` ("DD+" → "Dolby
  Digital Plus", DTS-HD "MA"), shared with iOS's track rows. The player
  speaks its times and chapter starts in words (`TVPlaybackTimeFormat.spoken`)
  and "S1:E4" as "season 1 episode 4"
  (`MediaItem.numberedEpisodeNameAccessibilityText`).
- **A grid poster is read from its footer's labels**, not the poster's own
  label, so the spoken subtitle is set on the footer's subtitle label
  (`TVCaptionedPosterView.spokenSubtitle`).
- **A focusable `.contain` section read only its last line**, so each Full
  Details section is one element: its heading as label, every row as value.
- **In the accessible transport the player's title block is hidden**: never
  focused, it was read ahead after every move and state change. The times
  carry iOS's lead-ins ("Current position: …", "Remaining time: …"), and the
  scrubber is iOS's "Playback position".
- **Limitation: a focus move made by Menu isn't spoken properly.** Back to the
  landing item VoiceOver says "Button" and the read-ahead, not the label,
  though its cursor is right; Up speaks it. Layout- and screen-changed
  notifications, `@AccessibilityFocusState` and a delayed write all failed
  (Benjamin left it, 2026-10-11); announcing the item after each Menu move is
  the fallback if revisited.

**Onboarding with VoiceOver**: nothing that only shows text is reached by
focus, so what changes is announced (`TVOnboardingSpeech`): a found server
(once, as the list stops being empty), a scan ending with none, the Quick
Connect code's expiry (focus then goes to Get New Code) and every sign-in
error. Each Quick Connect code is announced with the screen's title and
instructions (only its buttons take focus, so landing read "Use Password
Instead" alone; Benjamin, on device), the code a digit at a time. Who's Watching?'s Change Server sits
in a full-width focus section (or Down reached it only from a lockup above
it). Under VoiceOver it isn't focusable while users load (or it was read
first); otherwise it is, as the way off a slow server. A
remembered lockup's value is "Signed in", and Forget This Account is also a
named action, since holding Select may not reach the menu. "Signing in to …"
carries one label: its bold server name was a run VoiceOver read after a
pause, though XCUITest reports one label.

## The player

**The host has three rules from AetherEngine's README and Sodalite**
(`DionysusTV/Player/`). It's presented with UIKit `present`, never
`fullScreenCover`, which takes Menu for itself. The engine's own
`AetherPlayerView` is hidden whenever `currentAVPlayer` is non-nil, because
AVKit draws the native route and the software route has no AVPlayer
(`TVPlayerSurfacePolicy`). And the engine is made with
`ownsNowPlayingSession: false`: AVKit runs Now Playing, from the item's
`externalMetadata`, which `setNowPlayingInfo` stages through the engine before
`load()` (`NowPlayingMetadata`, M6, after Sodalite). AVKit publishes only with
`showsPlaybackControls` on, so the chrome is hidden, not switched off; an
`MPNowPlayingSession` of the app's own conflicts with AVKit's (Sodalite:
CoreMediaErrorDomain -16046), and `updatesNowPlayingInfoCenter` doesn't exist
on tvOS. **tvOS 27's Control Center shows no Now Playing tile for a video
app**, Infuse included (Bedroom, 2026-10-14); it surfaces on a paired iPhone
(Lock Screen card, Apple TV Remote) with title, second line, artwork and
working play/pause, ±10s and scrubbing. AVKit publishes while the player is
still waiting to play and not again once it plays, so the iPhone's bar stood
still: `AVKitNowPlayingRepublisher` stages the metadata again each time
playback settles into `.playing`.
AVKit's chrome is hidden and the transport is ours (`TVTransportOverlay`),
inset by the safe area alone. The host keeps Select and Play/Pause away from
`AVPlayerViewController`'s own `pressesBegan`: passed up, AVKit toggled
playback before our recognizer fired, so a pause flashed Play (Benjamin, on
device).

**The player doesn't use the focus engine** (Benjamin, 2026-10-06, as
Sodalite does). The host's recognizers take every press and swipe and hand
them to `TVPlayerInputModel`, a pure reducer over `TVPlayerInputState` that
returns commands for `TVPlayerCommandRunner`, the only code that acts on
`PlayerViewModel`. The overlay takes no interaction and draws focus from the
state, so XCUITest reads it from a test-only marker
(`A11yID.TV.Player.focus`), not `hasFocus`.

- **Left/Right report down and up** (a long-press recognizer with no
  minimum), so the model tells a press (a 10s skip, on release) from a hold
  past 0.4s. `TVSwipeGate` turns a pan into a free scrub (paused only, after
  40pt at 200pt/s, so a resting thumb does nothing), one step per swipe
  elsewhere, or Up/Down.
- **Scanning mimics the native player** (Benjamin, 2026-10-06): playing, a
  hold or swipe pauses and scans at level 1; each further press or swipe steps
  -4…-1/stop/+1…+4 (8×, 32×, 64×, 128×, matched to Infuse on device), the
  opposite way slowing through a stop, and releasing a hold keeps scanning.
  Paused, a swipe scrubs freely and a press steps 10s. **The picture stays
  paused and only the trickplay preview moves**: AetherEngine's `setRate`
  caps video at 2× forward with no reverse (AetherEngine#39). Select or
  Play/Pause plays from the preview; Menu returns to where it started and
  resumes. Play, pause and each skip flash a glyph (`TVActionFlash`); the scan
  shows one more triangle per level (`TVScanIndicator`); a focused scrubber
  shows a knob at the playhead.
- **The transport fades 4s after the last press**, never while paused,
  loading or scrubbing, timed in the reducer from playback starting.
- **The HDR chip shows only while the engine reports HDR**
  (`videoFormatDescription`, nil for SDR); see "HDR and audio" below.
- **Subtitles are iOS's `SubtitleOverlayView`**, with `SubtitleOverlayMetrics.tv`
  (54pt text, matched to Infuse; a title-safe resting inset), libass
  included. Cues clear the transport's bar through `BottomChromeTopKey`. AVKit
  draws no copy of its own (checked with a forced SubRip track).
- **The swipe-down panel** (Info, Chapters, Audio, Subtitles; Chapters only
  when the title has them) opens with Down or an icon and lifts the scrubber
  to mid-screen. Tabs follow focus. Restart and a chapter play and close it; a
  track switch keeps it open. It closes on Menu, Up from the tabs, or 10s
  without a press; Menu closes it even while an audio switch reloads, when
  every other press is ignored. Info's art is a movie's poster, else an
  episode's thumb or still, else the nearest ancestor's Thumb
  (`MediaItem.parentThumbImageURL`: Jellyfin 10.11 sends `ParentThumbItemId`/
  `ParentThumbImageTag` on an episode, never `SeriesThumbImageTag`).
  **The panel is laid out in screen coordinates** (title at 60, scrubber at
  440, tabs at 560) in an overlay of a screen-sized view: inside the safe area
  that layer started at the screen's top, and the chrome's gradients must
  never total more than 1080pt, or the layer outgrows the screen and is
  re-centred.
- **Skip and Next Up share the bottom-right slot**, lifting above the
  transport when it's up. With the transport hidden Select skips; with it up,
  Skip is its own focus stop above the icon row (Benjamin, 2026-10-07). Menu
  with nothing else up hides the button until the transport returns. The Next
  Up card has focus while the transport is hidden, where Menu means Close and a
  swipe or hold moves along the card, never scans (`scrubCanOpen`); with the
  transport up it's the stop above the icons, and Menu returns to the
  scrubber. **The next item plays in the same player**
  (`TVPlayerHostController.advanceToNextItem()`): the session ends and is
  reported, a new view model and engine are bound to AVKit, nothing is
  dismissed. Never under an open scrub.
- **Playback stats is a toggle on its icon**, never a tab or modal: one glass
  page top-right with every row of iOS's three pages (`PlaybackStatsReport`,
  shared), named and defaulted as iOS's ("Show/Hide playback stats", on in
  debug builds, off in release). It gives way while the panel or the Next Up
  card is up (`statsPanelShows`; Benjamin, 2026-10-08). Each row is one
  element, name as label and reading as value (a reading alone fails the
  audit as not human-readable).
- **The two players share their glyphs and skips** (Benjamin, 2026-10-07):
  stats `chart.bar.xaxis`, 10s skips each way (`gobackward.10`/`goforward.10`,
  iOS's Now Playing too), Skip with a trailing `forward.fill`, Play Now a
  `play.fill`, Next Up's placeholder `play.tv`. Change one platform's, change
  the other.
- **The space bar is Play/Pause too** (`TVKeyboardCommand`): a keyboard and the
  Simulator's on-screen remote send it as a key press (type 2044, HID usage
  0x2C), never `.playPause`. XCUITest can't type into the player; check it
  with `idb ui key <udid> 44`.

### The accessible transport

While VoiceOver or Switch Control runs (`TVAccessibleTransport`;
`-UITestAccessibleTransport YES` forces it, since XCUITest can run neither),
the player is driven by the focus engine instead of the model's own focus.
Nothing hides the transport by itself and the panel never times out. Menu
closes the panel, then hides the controls (leaving one invisible "Show Player
Controls" button: Select, Up or Down bring the controls back on Play/Pause,
Left and Right skip 10s), then leaves (Benjamin, 2026-10-08). Up from the
scrubber lands on Play/Pause (the icon row's default focus at `.userInitiated`
priority). The icon row gains back 10s, Play/Pause, forward 10s and Info; the
scrubber is one adjustable element (10s a step, its spoken position as its
value); panel tabs and rows, Skip and Next Up are buttons, each sending a
`TVPlayerControl` through the same reducer, so `PlayerViewModel` doesn't
change. Play/pause, skips, track changes and Skip and Next Up arriving are
announced once each.

- **With VoiceOver on, every press still reaches the host's recognizers**, so
  in this mode all but Menu and Play/Pause stand down, or Select would act
  twice.
- **The controls are a layer presented over the player**
  (`TVAccessibleTransportLayer`), not part of its overlay: AVKit's container
  can take focus, and UIKit doesn't search inside a focusable view, so buttons
  in the overlay took focus once and never moved it. The player's overlay
  keeps the subtitles (`TVPlayerOverlay.Role`), so libass runs once; the
  transport's top reaches them through `TVPlayerInput.chromeTop`. The layer is
  dismissed with the player. It sits above the player, so code looking for
  the player searches the presented chain (`TVPlayerPresenter.player(in:)`),
  never its top: closing it on a return after 30 minutes once missed it.
- **VoiceOver turned on mid-scrub or mid-hold** ends the scrub the way Menu
  would and drops the held arrow on the next tick: nothing in this mode
  could end either.
- **Menu in the layer must be the overlay's** (`onExitCommand`): left to UIKit
  it dismissed the layer, leaving no controls. A bare `.focusable()` view was
  never reached by Down, so the scrubber is a button too (Select plays and
  pauses).

XCUITest reports an adjustable SwiftUI element as Other, so the scrubber's
swipe steps are checked by hand with VoiceOver on.

## HDR and audio on the Apple TV

**HDR plays through the HDR master as of AetherEngine 7.22.2** (Apple TV 4K
3rd gen, tvOS 27.0, HDR10-only TV, 2026-09-30). The engine requests the HDR10
mode and frame rate, and the TV takes about 2.9s to switch, longer than the
engine's 2s gate. Up to 7.22.1 the engine served the master mid-switch,
AVPlayer refused it (`-11868`) and the refusal latched until the app was
backgrounded (AetherEngine#588), so every HDR title fell back to the media
playlist: still HDR10 on screen, but with no subtitle or audio renditions.
7.22.2 waits for the switch (AetherEngine#667, filed and retested by this
app).

**The HDR label is one-sided**: AetherEngine claims HDR only on evidence
(AE#459, since 6.82.0): AVPlayer still playing an HDR master 500ms after it
was served, or EDR headroom above 1.00, which reads a flat 1.00 here. So it
can read SDR on an HDR picture for the first half second, after a fallback to
the media playlist, on the software route, and on a server transcode. **Trust
the TV's own info banner**, not `displayColorFormat` or EDR headroom. The
chip shows only while the engine reports HDR and says nothing rather than
SDR. `DisplayContext` passes the real Match Content setting and asserts
nothing about the panel's HDR state.

Measured on the Bedroom Apple TV (HDR10-only Hisense, AetherEngine 7.27.2,
2026-10-08), logging the display manager, the engine's formats and the decoded
picture's transfer function once a second:

- Direct play reads right once the master is taken, about 4s in: HDR10 (1917)
  and Dolby Vision on an HDR10 base (Cape Fear S1:E1) both said HDR10, as the
  TV did.
- **HDR10+ reads HDR10+ while the TV says HDR10** (The End of Oak Street; DV on
  an HDR10+ base): right, since the chip names the signal and the panel
  ignores HDR10+ metadata.
- **HLG reads HLG while the TV says HDR10** (Saving Private Ryan, DV on an HLG
  base): the Apple TV converts HLG to HDR10 for the panel, which nothing the
  app can read sees (AetherEngine#535's class); left as is.
- A server transcode is really SDR (Jellyfin tone-maps it to BT.709), so the
  chip's silence is right.
- Not checked: the software route with HDR (no AV1 or VP9 HDR title).
- Audio: DD+ Atmos is stream-copied with JOC intact; TrueHD is decoded and
  re-encoded to 5.1 E-AC-3, losing Atmos. End-to-end Atmos wasn't confirmed
  (the TV said "Dolby Audio" for both).
