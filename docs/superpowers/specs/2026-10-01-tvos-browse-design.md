# Dionysus for Apple TV — Milestone 3: Browse

Status: design agreed in conversation with Benjamin on 2026-10-01; awaiting his review of this document.
Parent spec: `docs/superpowers/specs/2026-09-29-tvos-app-design.md` (milestone 3).
Prototype canvas: https://claude.ai/artifact/Wjp3J4eh4VGqMmmR7ntAKL, screens 5 and 7–11.

## Goal

Replace M2's stopgap browse screens with the prototype's: Home, detail pages, the collection grid, Search and Profile. After M3 a person can find anything in their library from the remote and reach playback through a detail page, as on iOS.

## Decisions (Benjamin, 2026-10-01)

| Area | Decision |
|---|---|
| Tiles | Every tile on Home, a grid or Search opens a detail page, never playback. The exceptions are the hero's Play, a detail page's own Play/Resume/Restart, and an episode tile on a show page. |
| Search input | The system `.searchable` keyboard, inset so its first key and hint stay on screen. Left stays in the keyboard; Menu opens the rail. Not the prototype's custom one-row keyboard. |
| Detail scope | Movie, show, box set and playlist pages. No Add to Playlist, no Remove from playlist, no Delete from server. With nothing to hold, the More button is left off. |
| Hero paging | Auto-advance plus Right/Left. |
| Settings | Profile shows the whole prototype list now, including the four settings whose player features arrive in M4. |
| Pushed pages | A path in the shell, with pages beneath the top kept alive up to a cap (below). |

## Navigation within the shell

Detail pages and See All grids are pushed on top of a top-level page, with the rail beside them.

- `TVShellNavigation` gains a path of `AppRoute` values (`assetDetail`, `collection`) for the current destination. Pages open a route through an environment action; they never reach the shell directly.
- **Menu pops the path. With the path empty it opens the rail on the destination's row**, as today.
- The rail's anchor stays the destination's row at any depth. Left from a pushed page's leftmost item opens the rail.
- Choosing a row in the rail drops the path and tears the page down, as today. "Only the page on show is built" still holds between top-level pages.
- A Libraries-rail tile on Home switches to that library's page. It does not push.
- The shell owns one view model per path entry, and the item that last had focus on each.

### Which pages stay alive

Pages beneath the top are kept built but hidden and unfocusable, as the page beneath the player is. Returning to one is immediate, with scroll position and focus where they were. This replaces "only the top is drawn", which is the rebuild that broke returning from the player: a lazy grid asked to focus a tile it had not built.

**The cap: the root page, the top page, and the two pages directly beneath the top stay alive. Anything deeper is torn down.** That is four live pages at most. It covers root → detail → More Like This detail → one more, all with instant return.

- A page torn down by the cap is always a detail page. Its view model is kept by the shell, so it rebuilds without a refetch, and its focusable items are at the top, not in a lazy container.
- A hidden page runs nothing: no timers, no ambient animation, no image loads it had not already started.

**Predicted cost, to be measured.** Hidden pages are not drawn, so the cost is memory, not frame time: roughly 20–50MB a page, mostly its backdrop. The first PR measures memory and scroll hitches on the Simulator at depth 1, 3 and 10. The Bedroom Apple TV is checked at the next authorised deploy, since the Simulator shows no real memory pressure. If the numbers are worse than predicted, the fallback is to keep only the root alive.

## Shared tiles

- `TVPosterTile` (250×375) and `TVLandscapeTile` carry iOS's corner badges: a heart top-left, an eye top-right, and a progress bar while part-watched. Captions follow the prototype: always shown in Search and on landscape tiles, shown on focus for posters on Home and in grids.
- The rule for which badges show moves out of iOS's `PosterCard` into a shared type both apps use, with one set of unit tests.
- `TVRail` is a titled horizontal rail with an optional See All tile at its end.
- Placeholders use `MediaPlaceholderBox` with the content type's glyph, as on iOS.

## Home (screen 5)

Replaces `TVBrowseLauncher`, on the shared `HomeViewModel`.

- **Hero:** full-bleed backdrop behind the rail, logo with a title fallback, a metadata line (year, rating, runtime, genres), a two-line overview, Play and More Info, and page dots.
- Play starts playback. For a series it resolves the next episode, the same way the show page does. More Info opens the detail page.
- **Paging:** the hero advances on a timer while it has focus. Right from More Info goes to the next item and Left from Play to the previous one; Left on the first item opens the rail. A manual press stops the timer for that visit. The timer does not run with Auto Carousel off, under Reduce Motion, under the UI-test harness, or while Home is hidden.
- **Rails** in the iOS order: landscape tiles for Continue Watching and Next Up, posters elsewhere, See All where the rail has a query, and the Libraries rail last.
- A failed load shows a message and Retry. This closes the M2 minor that Home did not retry.
- After the player closes, Home refreshes progress the way iOS does.

## Detail pages (screens 7–8)

All four sit on the shared `AssetDetailViewModel`, with the page's backdrop behind the rail.

- **Movie.** Logo (title fallback), metadata line with the community rating, format badges from the media source (resolution, HDR format, Atmos, CC), a three-line overview where Select opens the full text, a starring and director line, then the actions: Resume or Play with a progress meter and time left, Restart (only when there is a resume point), Watched (eye, never a tick), Favorite. Below: Cast & Crew (not selectable; there is no person page), More Like This (posters opening detail pages), and a Details block.
- **Show.** The same header, with "Resume S1:E3" on the play button. Season tabs, then an episode rail of landscape tiles with badges; Select on an episode plays it. An episode tile from Home or Search opens its show page on that episode, as iOS does.
- **Box set.** Header and a poster grid of its items, each opening its detail page.
- **Playlist.** Header with Play/Resume and its item list, read-only. Select on an item follows iOS's behaviour for the same row.
- Watched and Favorite update optimistically through the view model. After the player closes, the page applies the playback outcome and refreshes, as iOS does.
- A failed load shows a message and Retry.

## Collection grid (screen 9)

Replaces `TVLibraryGridView`, for library pages and See All, on the shared `CollectionGridViewModel`.

- Title and item count; a sort pill (field and direction); the five cascading filter pills as menus (Genre, Studio or Network, Decade, Watched, Favorites), offering only what the view model reports as available.
- Six columns of poster tiles with captions and badges.
- **Alphabet jump bar** down the right edge, reached by Right from the last column. It lists `#` and A–Z, dims letters with no items, and moves focus to the first item for the chosen letter. It is shown only while sorted by title.
- No items after filtering: a message and Reset Filters. A failed load: a message and Retry. Both close the M2 minor that such a page showed only its title.

## Search (screen 10)

On the shared `SearchViewModel`.

- System `.searchable` in a `NavigationStack`, inset so the first key does not clip when focused and the hint does not run off the right edge.
- Results are grouped into rails by type, and every kind is listed now that each has a page. Selecting one records it and opens its detail page.
- **With the field empty: Recent Searches, as a rail of the results most recently opened, with Clear.** This is the history the shared view model already keeps and iOS shows. The prototype's typed-query pills would need a second history and are not built.
- No results: a message naming the query.

## Profile (screen 11)

The prototype's layout: a brand pane on the left (glyph, name, app version, AetherEngine version) and focusable rows on the right.

- **Account:** the account row (name, server name and address); Switch User; Approve Quick Connect Code, only when the server has Quick Connect on; Change Server, behind today's confirmation; Sign Out.
- **Sign Out forgets this account on this Apple TV, then goes to Who's Watching?.** Switch User keeps it remembered, as today.
- **Apple TV Users:** Follow Apple TV Users and, while that is off, Select a User Every Relaunch, unchanged from M2.
- **Home:** Auto Carousel.
- **Playback:** Next Episode Countdown, Chapters in Scrubber, and Advanced (streaming mode, maximum streaming bitrate, Subtitle Styling, Show Playback Stats Button). The footer text is iOS's. Next Episode Countdown, Chapters in Scrubber, Subtitle Styling and the stats toggle are stored but change nothing on tvOS until M4.
- **About:** License and Privacy Policy, each a scrolling text page from the same bundled files iOS uses.
- Not present: Downloads, 3D Depth Effects, Theme.

## Out of scope

Add to Playlist, Remove from playlist, Delete from server, a person page, the prototype's custom search keyboard and typed-query history, and every player feature (M4).

## Testing

- **Unit:** the path and its keep-alive cap, hero paging and its timer rules, the alphabet index, search grouping, the shared badge rule, Sign Out against Switch User.
- **tvOS UI journeys**, against the stub server: tile → detail → Menu back with focus restored, from Home, a grid and Search; a More Like This chain past the cap and back; hero paging; filter pills and the alphabet bar; season tabs and episode playback; each Profile row. M2's journeys that expect a tile to play are updated.
- **Accessibility audit** over every new screen. Identifiers follow `A11yID`'s rules: never a label, never on a screen-root container.
- Suites before each sign-off: tvOS unit, tvOS UI, iOS unit, iOS smoke, never concurrently.

## Documentation

CLAUDE.md's tvOS section (the path, the keep-alive cap, the pages), `TESTING.md`, the parent spec's milestone line, and `Localizable.xcstrings` are updated in the PR that changes what they describe. `PRIVACY.md` needs no change: M3 adds no stored identifier, permission, dependency or network destination.

## Delivery

One PR per step, cut from `develop`, each signed off before commit:

1. The path with its keep-alive cap, shared tiles, the movie page, and the memory measurement.
2. Show, box set and playlist pages.
3. Home.
4. Collection grid with the alphabet bar.
5. Search.
6. Profile.

Detail pages come first so every later screen's tiles have somewhere to go.
