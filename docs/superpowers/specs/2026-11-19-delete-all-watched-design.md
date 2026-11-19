# Delete All Watched (#437)

Short design, 2026-11-19.

## Intent

On a show's page, Delete gains an **All Watched** row, on iOS and the Apple
TV, that deletes every episode of the show the user has marked Watched and
leaves the rest. It frees the space a finished part of a show takes without
deleting it episode by episode. The confirmation says how many episodes go
out of how many the show has, and that they go for every user of the server,
since Watched is the current user's status but deletion removes the file.

## Goals

- One row, show-wide: every season's watched episodes in one action.
- The confirmation gives the exact count ("12 of 40") and says the episodes
  are deleted for all users.
- Same targets and words on both platforms (`AssetActionTargets`).

## Non-goals

- No per-season All Watched (Benjamin, 2026-11-19: show-wide, as asked).
- Half-watched episodes (a resume point, not Played) are never deleted.
- No bulk-delete endpoint: Jellyfin has none; episodes go one request each.

## Anti-goals

- Deleting anything the confirmation didn't count: the episodes deleted are
  exactly the ones counted when the user confirmed.
- Offering it to a user who can't delete them all.

## Approaches

1. **Fetch the show's episodes when the page loads (chosen).** One
   `GET /Shows/{id}/Episodes?Fields=CanDelete` on a series page, refreshed
   when the page refreshes (after playback, a watched toggle, a deletion).
   The menu is built from what's held, so the row and its count are ready
   when the menu opens. Costs one request per show page, as
   `loadSeasonDeletability` already does for folderless seasons.
2. Fetch when the row is chosen, then confirm. No cost to pages where it's
   never used, but a SwiftUI menu can't wait on a request: the row would be
   offered blind (shown with nothing watched, or to a user who can't delete)
   and the confirmation would need a loading step on both platforms.
3. Ask the server for watched episodes only (`Filters=IsPlayed`). The total
   needs every episode anyway, so this is two requests for what one answers.

## Design

- **What counts.** Episodes with a file (`locationType != "Virtual"`); of
  those, the ones whose `UserData.Played` is true. Both numbers in the
  message come from that list: watched of total.
- **Where it sits.** Last in the Delete submenu, below a divider of its
  own (Benjamin, 2026-11-19): the show, the season, the episode, then
  **All Watched**. Hidden when no
  episode is watched, or when any watched episode's `CanDelete` is false
  (the folderless-season rule). Its presence makes Delete a submenu even
  where it was one row.
- **Confirmation.** Title "Delete Watched Episodes". Message (Benjamin,
  2026-11-19):
  "12 episodes that are watched will be deleted for all users. 28 episodes
  will remain for House of Games. This cannot be undone."
  Each count is a String Catalog plural ("1 episode that is watched will
  be…", "1 episode will remain…"). When every episode is watched the second
  sentence is "No episodes will remain, and House of Games will be removed."
  (builder's call: Jellyfin drops an emptied show).
- **Deleting.** Sequential through the snapshot, stopping at the first
  failure with the existing "Deleted N of M episodes, then stopped: …"
  (`PartialSeasonDeletionError`, generalised). Announced once through
  `DeletedItemBroadcaster`. The outcome is `DeletionOutcome`'s: the show
  emptied pops off its own page (to the root from a page beneath it); otherwise the page stays and repairs (Play moves
  on, the episode on show swaps back to the show).
- **Emptied seasons.** A season left with no episodes drops off the page
  (`emptiedSeasonIDs`), folder or not, since Jellyfin lists it until a scan.
- **Downloads (iOS).** Downloaded watched episodes add "Delete from Server
  and Device", as Delete Show does for the show's downloads.
- **Apple TV.** `TVMoreActionsButton` offers the row and `TVConfirmation`
  asks, with the same copy; the tabs retain only seasons that remain.

## Tests

- Unit: target building (shown, hidden, permission), the counts, the
  message, deleting only the snapshot, partial failure, emptied seasons,
  the outcome when every episode is watched.
- UI: an iOS journey and an Apple TV journey on the stub server deleting a
  show's watched episodes and checking the page after.

## Left to the builder

The stub scenario's shape, identifiers (`A11yID`), and how the snapshot is
carried from the menu to the confirmation.
