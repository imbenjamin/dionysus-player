# Up Next for downloads, with Delete & Play Next (#274)

iOS and iPadOS only: the Apple TV has no downloads.

## Intent

Watching a downloaded show (on a flight, say), the next episode should cue
up as it does when streaming, and the viewer should be able to clear the
episode they've just finished in the same tap: **Delete & Play Next** plays
the next downloaded episode and deletes the download of the one just
watched. It frees space as you go without a trip to the Downloads tab.

Deleting is destructive, so it only ever happens on an explicit tap. A
countdown left to run plays the next episode and deletes nothing (#274).

## What exists today

- The offline player has **no Up Next at all**: `PlayerViewModel.startOffline`
  skips the next-episode lookup, so `nextEpisode` stays `nil` and the
  countdown never shows for a download.
- A download is played only from its own page, `DownloadedAssetDetailView`,
  which passes no `onRequestNextItem` to `PlayerView`.
- Live show pages chain episodes in `ShowDetailView`: `PlayerView`'s
  `onRequestNextItem` stages `pendingNextEpisode`, and the cover's
  `onDismiss` presents the next one (setting the cover's item while it's
  still presented doesn't reliably work).
- `DownloadManager.delete(itemID:)` deletes the device's files only, and keeps
  a row with an unsynced watched or resume write as `markedForDeletion` until
  `DownloadSyncManager` pushes it, so deleting a just-watched episode loses
  nothing.

## Goals

1. A downloaded episode cues up the next episode when, and only when, that
   episode is the **immediate** next one and is downloaded (complete, not
   marked for deletion), for the same user.
2. The Up Next card on such a session has two actions, **Cancel** and
   **Delete & Play Next**, which replaces Play Now (Benjamin, 2026-11-20).
   To play on without deleting, the viewer lets the countdown run.
3. Delete & Play Next plays the next episode and deletes the **device's**
   download of the one just watched. The server's file is never touched.
4. The countdown running out plays the next episode and deletes nothing.
5. Closing the player after it has moved on lands on the page of the episode
   last watched.

## Non-goals

- Up Next for a downloaded movie, or across a playlist or collection of
  downloads.
- A download as the next item of a *streamed* session, or the reverse.
- Auto-deleting watched downloads, or a setting for it.
- Anything on the Apple TV.

## Anti-goals (a failure even if it works)

- Deleting anything the viewer didn't tap Delete & Play Next for: the
  countdown, Cancel or closing the player never delete.
- Deleting the server's file, or anything beyond this device's copy.
- Losing the watched mark or resume point of the deleted episode before it
  syncs.
- Skipping an episode: with a gap (E4 not downloaded), E3 offers no Up Next
  (Benjamin, 2026-11-20).
- Landing on "This download is no longer available." after closing.

## What counts as the immediate next episode

Decided offline from the downloads alone (a pure function, unit tested):

- **Same season**: the download with the same `seriesID` and `seasonID` and
  `episodeNumber` one past the current episode's last number.
- **Across a season boundary**: only when the current download is recorded
  as its season's **last episode**. Then the next is episode 1 of the next
  season by `seasonNumber` (the lowest season number above this one in the
  same series), if downloaded. That season must also be the server's next
  season, so record that too (see below); a season gap gets no Up Next.
- **A double episode** (one file covering E1–E2) ends at its last number, so
  the next is E3. Jellyfin's `IndexNumberEnd` gives it; it's stored on the
  download.
- **Never cued**: specials (season 0), an episode with no season or episode
  number, a movie, and a download that isn't complete. A current episode
  that is itself a special never cues anything either.

### Recorded at download time (Benjamin, option 1 of 3, 2026-11-20)

Nothing on the device says how many episodes or seasons a show has, so
`DownloadManager.enqueue` records, for an episode, from the server it is
already talking to:

- `episodeNumberEnd` (`IndexNumberEnd`; `nil` for a single episode), and
- `nextEpisodeNumbering`: where the server's next episode is, as
  (season number, episode number), from the same logic as
  `JellyfinAPIClient.nextEpisode`. `nil` means unknown (the lookup failed,
  or the download predates this change); a stored "none" means the series
  ends here.

With that, "immediate next" is simply: a downloaded episode of the same
series whose (season number, first episode number) equals the recorded
next. Without a record (an old download, or the lookup failed), only the
same-season rule applies. This replaces the "last in season" flag with
something that covers season gaps too; it is the same idea as option 1, and
my call.

Both are new optional SwiftData properties on `DownloadedItem`
(lightweight migration; `nil` on old rows). Old downloads cue within a
season until downloaded again. A failed lookup never fails the download.

For a season download, the next-episode lookup can be answered from the
episode list the season scan already has, rather than one request per
episode. That's the builder's call.

## Approaches (Benjamin chose A, 2026-11-20)

- **A. The live pattern (chosen).** The player closes and the episode page
  presents the next download's player from `onDismiss`, as `ShowDetailView`
  does. The page then shows the episode now playing. Proven, tested; the page
  shows briefly between episodes, as it does for live shows.
- B. Swap episodes inside the open player. No flash, but a second path for
  progress, track memory and the delete ordering, unlike every other
  presenter.
- C. Replace the page in the navigation stack. Lands right, but animates
  behind the player and Back skips where you came from.

## Design

### Player (`PlayerViewModel`, `PlayerView`, `NextUpOverlay`)

- `startOffline` resolves `nextEpisode` locally from the `DownloadStore`
  with the rule above (no network): a `MediaItem` built the way
  `startOffline` builds its own, with the next download's thumb or still as
  the card's image (a local file, so `LocalFileImage`, not
  `AsyncRemoteImage`). The countdown, Cancel and `closesWhenPlaybackEnds`
  then work as they do online.
- The offline view model exposes whether it offers delete (an offline
  session with a resolved next download, which on this path is every one
  with a card). `NextUpOverlay` takes an optional `onDeleteAndPlayNext`;
  non-nil puts Delete & Play Next where Play Now is, so the card keeps two
  buttons. Streamed sessions are unchanged.
- `PlayerView` gains a way to tell its presenter the advance should delete
  the finished download: `onRequestNextItem` carries it, or a second
  callback does; the builder's call. The countdown passes "don't delete"
  (and so does Play Now, on streamed sessions, where nothing is deleted
  anyway).
- The version arguments of `onRequestNextItem` don't apply offline (a
  download is one version) and are ignored there.

### The episode page (`DownloadedAssetDetailView`)

- Its subject becomes `@State` seeded from the route's `itemID`, so the page
  can follow playback: after an advance it shows the episode now playing, and
  that's where closing lands (Benjamin, 2026-11-20). Back still returns to
  wherever the viewer came from.
- `onRequestNextItem` stages the next item (and whether to delete);
  `onDismiss` then:
  1. deletes the finished download, if asked, with
     `downloadManager.delete(itemID:)`. This runs only after `PlayerView`'s
     teardown, whose `stop()` writes the session's final watched and resume
     state, so the row survives as `markedForDeletion` until it syncs;
  2. switches the page's subject to the next episode; and
  3. presents the player for it, from the start, not resuming (unless it
     has its own resume point: the same as Play on its page would do).
- A delete that does nothing (the row's already gone) is not an error. If the
  next download vanished between the cue and the dismiss, the page shows the
  finished episode (or, if that was deleted, pops) rather than the
  "no longer available" state.

### Copy

- Button: "Delete & Play Next", with a `trash` symbol, in Play Now's place
  and style (`.borderedProminent`), beside Cancel. Through the String
  Catalog. (My call: prominent, since it is the card's one way forward.)
- VoiceOver: hint "Deletes this episode's download from this device." No
  confirmation dialog: the button's label says what it does, and a dialog
  over a running countdown would race it.
- Afterwards, a toast is no use (the player covers `ToastHost`), so nothing
  more is said. The Downloads tab simply no longer lists the episode.

### Layout

The card keeps its two-button row (260pt wide, small controls). "Delete &
Play Next" is longer than "Play Now": the builder checks it fits beside
Cancel at the default text size and at accessibility sizes (if not, the row
may stack or the card widen; the label is never cut to the symbol alone).
Fits the fold layouts as the card does today (it moves with the player's
overlay).

## Tests

- Unit: the next-download rule (same season, double episode, season
  boundary with and without a record, season gap, episode gap, special, no
  numbers, incomplete or marked-for-deletion next, another user's download,
  another series); `enqueue` records the next numbering, and a failed lookup
  still downloads; the offline view model resolves `nextEpisode` and offers
  delete only offline; the page deletes only on Delete & Play Next and only
  after `stop()` wrote progress.
- UI (`DionysusPlayerUITests`): a stub scenario with two consecutive
  downloaded episodes. Journeys: the card shows Cancel and Delete & Play Next
  and no Play Now; Delete & Play Next plays E2, closing lands on E2's page, E1
  is gone from Downloads; the countdown plays E2 and E1 stays; a gap shows no
  card. A streamed episode's card still shows Play Now. Accessibility audit covers the new button.
- `TESTING.md` lists the scenario and journeys. A `nextUpDeleteAndPlayNext`
  identifier in `A11yID.Player`.

## Docs

- `DOWNLOADS.md`: Up Next offline, the immediate-next rule, what is recorded
  at download time, and that Delete & Play Next deletes the device's copy
  only.
- `Core/Playback/CLAUDE.md` or the root `CLAUDE.md`: one paragraph on the
  rule and why deleting never happens on the countdown.
- `PRIVACY.md`: nothing new is collected or sent (the lookup goes to the
  user's own server, at download time). No change.

## Left to the builder

- How the delete flag travels from `PlayerView` to the page.
- Whether a season download answers the next-episode lookup from its scan.
- The exact `MediaItem` shape for the offline next episode, as long as the
  card shows its number, title and image.
