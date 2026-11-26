# Downloads: how the current design was found

The incident write-ups behind `DOWNLOADS.md`'s rules, kept as a record. The
rules themselves are in `DOWNLOADS.md`, "Rules the incidents set";
read that first.

## Concurrent downloads could silently restart from scratch

  Testing two concurrent downloads surfaced a much bigger problem than the
  progress bar: one download visibly froze mid-transfer, then restarted from
  0% and re-transcoded from the beginning — confirmed live (2026-08-27) via
  the server's own logs, not inferred. The same episode produced **three
  separate, complete ffmpeg invocations** within four minutes, each targeting
  the same output file, each independently cut off after encoding only
  ~58% of the episode — matching what was visible on-screen. Sandwiched
  between each restart, the Jellyfin log read:

  ```
  Transcoding kill timer stopped for JobId ... PlaySessionId null. Killing transcoding
  ```

  The mechanism: Jellyfin arms a **10-second kill timer** on a progressive
  (non-HLS) transcode job the moment it thinks the client disconnected
  (`ActiveRequestCount` reaching zero). A download never sent a
  `PlaySessionId` or called `/Sessions/Playing/Progress`, so nothing was ever
  available to refresh that timer — the concept only exists for real
  playback clients. Under concurrent-download CPU contention (this server
  runs software `libx265` for quality, per the section above — genuinely
  expensive, and several running at once can start it), a transient stall
  long enough to trip this app's own `timeoutIntervalForRequest` (60s at the
  time) reads to Jellyfin as a real disconnect. Ten seconds later the
  still-wanted job is killed outright. The background `URLSession`'s own
  automatic reconnect (no app code involved) arrived roughly 40 seconds after
  that — by then the job was long dead, so Jellyfin could only start an
  entirely fresh transcode, wasting everything already encoded.

  The fix, both parts confirmed against Jellyfin's own source rather than
  guessed:
  - **A real `PlaySessionId`** (a UUID generated once per download) is now
    sent on the download's stream URL, the same as a real playback client
    would.
  - **A keep-alive ping** — `DownloadManager`'s existing progress-poll loop
    (every 2 seconds, well inside the 10-second window) now also posts to
    `/Sessions/Playing/Progress` with that `PlaySessionId` and a fixed
    `PositionTicks: 0` (there's no meaningful "position" for an in-progress
    transcode file — the kill-timer logic only cares that *a* ping with the
    right `PlaySessionId` arrived, not what position it reports). This
    applies to every download, including a stream-copied one — still a
    `Progressive`-type job server-side, still subject to the same timer.
  - `downloadRequestTimeout` was also raised 60s → 120s as a secondary
    margin, so a transient stall doesn't trip this app's *own* side of the
    connection as readily either.

  This closes the gap for any download the app is actively polling for —
  which, per the two known gaps above, means everything **except** a
  download reattached after a force-quit/relaunch (no live client that
  early, so no ping either). That specific case is now measurably more
  exposed to this failure mode than before the ping existed, not just stuck
  with a less-accurate progress bar — worth revisiting if it turns out to
  matter in practice.

  **A side effect fixed a second, previously-unsolved bug for free.** Before
  this change, retrying a failed/interrupted download could silently re-serve
  the same broken cached file instead of re-transcoding — Jellyfin computes
  its progressive-stream cache filename as
  `MD5(MediaPath + UserAgent + DeviceId + PlaySessionId)`
  (`Jellyfin.Api/Helpers/StreamingHelpers.cs`), and every prior request from
  this app used the same `DeviceId` and no `PlaySessionId` at all — so an
  identical retry hashed to the identical filename Jellyfin had already
  cached, truncated file and all. The only fix at the time was manually
  deleting the stale cache file on the server. Confirmed resolved live via
  the server's own transcode log for repeated "Captain Phillips" attempts on
  2026-08-27: two attempts *before* this fix (13:05, 13:28) landed on the
  identical output hash `d9628106…`; three attempts *after* (15:42, 15:45,
  16:55) each landed on a distinct hash. Since `enqueue(...)` mints a fresh
  UUID `PlaySessionId` on every call — first attempt or retry alike — every
  download now gets its own cache entry and can never collide with a
  previous attempt's leftover file. No separate code change was needed.

  This has a sharper consequence than a cosmetic progress bar: a chunked
  response with no length also means `URLSessionDownloadTask` has no way to
  tell a *complete* transfer from one that stopped early — confirmed live
  (2026-08-27, "Captain Phillips"): a server-side VideoToolbox filter crash
  killed ffmpeg 3:50 into a 134-minute film, and Jellyfin closed the HTTP
  stream the same way it would have on success. The download reported as a
  normal completion — a playable, HTTP-200, four-minute file with no error of
  any kind. `DownloadManager` now guards against exactly this:
  `finalizeCompletedDownload` loads the moved file's real duration
  (`AVURLAsset`) and compares it against the item's own `runtimeTicks` before
  trusting a `.success` result — anything under 95% of the expected runtime is
  routed to `.failed` instead, the truncated file is deleted, and the specific
  reason ("stopped early — only 4 of 134 minutes were saved") surfaces on the
  Downloads list row and via the Retry button there. 95%, not 100%: real
  transcode output can land a fraction of a second short of the source's own
  metadata (keyframe/mux rounding) without anything being wrong.

## A background session per download exhausted the transfer service

  Reported 2026-09-06: downloads were "more fragile" than they should be, most
  often failing with **"Lost connection to the background transfer service"**,
  mainly with a few downloads queued — and *regardless of the Max Simultaneous
  Downloads setting*. That last detail is the one that identifies the bug.

  The string is iOS's own `NSURLErrorBackgroundSessionWasDisconnected` (-997),
  surfaced verbatim because `friendlyDownloadFailureMessage` only translated
  `NSURLErrorCancelled` and passed everything else through as
  `error.localizedDescription`.

  The cause was structural. `DownloadManager` created **one background
  `URLSession` per download item**, with the identifier
  `"com.dionysus.downloads." + itemID`, at three separate sites (the normal
  start and both reattachment paths). Every background session is its own XPC
  channel to `nsurlsessiond` plus its own entry in that daemon's persistent
  store, and Apple's model is one background session per app, created once and
  kept for the process lifetime. This app churned them instead: each
  completion called `finishTasksAndInvalidate()` and then, in the *same*
  main-actor turn, admitted the next queued item and built another session —
  and background-session invalidation is asynchronous, so teardown and setup
  overlapped. Identifiers were never reused across items either, so the
  daemon's state grew without bound and anything orphaned by a force-quit was
  never reclaimed.

  **Confirmed live on a physical device (iPhone 16 Pro, iOS 26.6.1,
  2026-09-06)** rather than inferred — a 22-episode season bulk download with
  Max Simultaneous Downloads set to **1**, captured with `log collect
  --device-udid`. Three episodes completed with the app in the foreground;
  episodes 4 and 5 failed once it was backgrounded. In that ~14-minute window
  the daemon recorded:

  | app | distinct background sessions |
  |---|---|
  | **Dionysus** | **12** (5 alive simultaneously) |
  | WhatsApp | 1 |
  | Audible | 1 |
  | Amazon | 2 |

  Twelve sessions for one app against one, one and two for the others, and
  five still registered with the daemon at a single instant — **with the
  concurrency limit set to one**. Of those five,
  **four carried `XPC(N)` — no client connection at all**: dead-but-registered
  leftovers the app had created and never fully torn down. Only one was live
  and holding a transfer.

  That is the finding that matters, and it is stronger than the original
  hypothesis. Sessions were not merely churning, they were *accumulating*, and
  the concurrency limit never bounded them at all:
  it gates transfers, while `finishTasksAndInvalidate()` is asynchronous and
  the redownload and reattachment paths mint further sessions of their own.
  Hence "regardless of the number of simultaneous downloads set".

  The failure sequence, identical for all three -997s:

  ```
  10:30:40.848  Dionysus       BackgroundSession <A1ABAE7A…> client transitioning to background
  10:30:51.999  nsurlsessiond  NDSession <204CA73D…> notified … com.imbenjamin.dionysusplayer was suspended, XPC(N)
  10:30:51.999  nsurlsessiond  NDSession <F6026DFD…> notified … was suspended, XPC(N)
  10:30:51.999  nsurlsessiond  NDSession <A1ABAE7A…> notified … was suspended, XPC(Y)
  10:30:51.999  nsurlsessiond  NDSession <EF762F56…> notified … was suspended, XPC(N)
  10:30:51.999  nsurlsessiond  NDSession <80E967BC…> notified … was suspended, XPC(N)
  10:30:51.999  nsurlsessiond  NDSession <A1ABAE7A…> has 1 outstanding tasks
  10:30:52.000  nsurlsessiond  NDSession <A1ABAE7A…> Lost connection to app -- connection invalidated
  10:31:36.867  Dionysus       Task <98E474E4…> finished with error [-997]
  ```

  The session holding the live transfer is the one whose client connection the
  daemon drops on suspension. For contrast, WhatsApp's single session in the
  same archive logs `attempting to reconnect to background transfer daemon`
  → `background session setup complete` and carries on — which is what one
  long-lived session is *supposed* to do, and what this app could not do while
  its transfers were spread across a dozen of them.

  It also explains two earlier bugs this document and the code already carried
  scar tissue for — the -999 "Rushmore" case (a deleted row's orphaned session
  kept an identifier the OS still considered in use, cancelling a same-day
  redownload's brand-new task) and the two-sessions-racing-for-one-identifier
  guard in the reattach path. Both were symptoms of the same design rather
  than separate faults.

  The fix is one fixed identifier (`com.dionysus.downloads`), one session
  built lazily and **never invalidated**, and one long-lived
  `DownloadTaskRouter` as its delegate. Per-item routing moved onto the task
  itself (`taskDescription` = itemID, which a background session persists
  across an app relaunch, with a URL match against the row as a fallback);
  cancellation is now `task.cancel()` rather than session invalidation; and
  the three reattachment paths collapsed into a single `getAllTasks` sweep at
  launch that adopts live transfers, resolves rows whose transfer is gone, and
  cancels tasks whose row is gone.

  Three consequences worth recording:

  - **Wi-Fi Only moved from the session to the request.** A session that lives
    for the whole process can't have its configuration rewritten when the
    toggle flips, so `allowsCellularAccess` is set per `URLRequest` instead —
    which is also where `allowsExpensiveNetworkAccess` can be set, so "Wi-Fi
    Only" now correctly excludes a personal hotspot, which it never did before.
  - **Transient transport failures are re-armed, not failed.** -997, -996,
    `.networkConnectionLost`, `.timedOut` and `.cannotConnectToHost` get up to
    three automatic retries with backoff (2s/8s/20s — the first deliberately
    inside Jellyfin's 10-second transcode kill-timer window, so the re-arm can
    reconnect to the still-running job rather than provoking a fresh encode).
    `NSURLErrorCancelled` is deliberately *not* retryable: that is a real
    force-quit, and silently restarting a transcode the user may not still
    want would be worse than reporting it. The budget lives in memory rather
    than on the `DownloadedItem` row — it bounds one automatic loop against a
    process/daemon-lifetime fault, and a user reopening the app the next day
    should get fresh attempts rather than inherit an exhausted counter, which
    would make the feature weakest in exactly the launch-adoption case it is
    most needed for.
  - **A re-arm reuses the same URL, and therefore the same `PlaySessionId`**
    and the same server-side transcode cache entry (see the cache-hash
    discussion above). That is what we want when the job is still alive — the
    -997 case is the *client's* channel breaking, not the server's encode —
    and it is safe when it isn't, because `finalizeCompletedDownload` already
    rejects a short file via `durationValidationFailureReason`. Minting a
    fresh `PlaySessionId` needs a live `JellyfinAPIClient`, which this type
    deliberately never stores and which doesn't exist during launch adoption
    at all; that escape hatch stays on the user-initiated `retry(itemID:client:)`.

  **Verified fixed on the same device (2026-09-06)**, identical repro on the
  next season. The app now creates exactly one live background session, and at
  suspension it does what the old build never could:

  ```
  10:46:15  nsurlsessiond  NDSession <A9143869…> client disconnected (app suspended)
  10:47:23  Dionysus       BackgroundSession <A9143869…> attempting to reconnect to background transfer daemon
  10:47:23  Dionysus       BackgroundSession <A9143869…> background session setup complete
  10:47:23  Dionysus       BackgroundSession <A9143869…> Reconnection to existing session and state complete
  ```

  Zero -997 across the run (against three in the same-length before-run), and
  a transfer that began at 10:45:49 ran straight through the 10:46:15
  suspension and **completed at 10:47:23 while the app was still suspended** —
  Jellyfin logging `FFmpeg exited with code 0` 120ms earlier, i.e. a clean full
  transcode, not a truncated one. The daemon then woke the app, which processed
  the completion and admitted the next item 50ms later. That also settles the
  one assumption in this design that only a device could settle:
  **`taskDescription` does survive suspension and wake**, so the router's
  itemID routing holds across the case that matters most.

## iOS defers the *next* queued download when the app is backgrounded

  Found while verifying the fix above, and **pre-existing** — the -997 simply
  used to fire first and hide it. Background *continuation* of a running
  transfer works (proven above). Background *starting* of the next queued item
  does not:

  ```
  Task <F23E62AE…>.<20> current discretionary status for com.imbenjamin.dionysusplayer is discretionary (opt-in: 0)
  Task <F23E62AE…>.<20> adding delay of 60.000000
  ```

  A background-session task created while the app is not in the foreground is
  treated as **discretionary** by iOS regardless of what the app asked for
  (`opt-in: 0` — the app did not request it; the system imposed it), and gets
  scheduled at the system's convenience. The same archive shows Amazon and
  Audible getting identical treatment, so this is systemic iOS behaviour rather
  than anything specific to this app.

  Confirmed end-to-end against the server: Jellyfin started transcode jobs at
  10:42:40, 10:44:12 and 10:45:49, then **nothing at all until 10:49:10** — one
  second after the app was foregrounded. The queued episode's HTTP request
  never reached the server while the app was suspended. Nothing was lost or
  restarted; that download simply had not begun yet, which is why it then ran
  0→100 as a fresh transfer.

  `URLSessionConfiguration.isDiscretionary = false` does **not** override this;
  the rule is about when the *task* is created, not how the session was
  configured. The only real lever is to create the tasks while the app is
  still in the foreground.

  **The fix: release the whole queue when the scene leaves the foreground.**
  `DownloadManager.releaseQueueForBackgroundExecution()`, called from
  `DionysusPlayerApp`'s `scenePhase` handler, starts every remaining queued
  download at that last moment, ignoring `maxConcurrentDownloads`.

  Abandoning the limit there is deliberate, because it cannot be honored
  anyway. Measured on device: at the instant of suspension `nsurlsessiond`
  resumes **every** task the app has created and schedules them itself —

  ```
  11:39:43.207  task .<5>  resumeTaskWithIdentifier, props <private>   ← app resumed
  11:40:27.690  Application com.imbenjamin.dionysusplayer was suspended
  11:40:27.690  task .<7>  resumeTaskWithIdentifier, props (null)      ← daemon resumed
  11:40:27.690  task .<8>  resumeTaskWithIdentifier, props (null)
  11:40:27.690  task .<9>  resumeTaskWithIdentifier, props (null)
  11:40:27.690  task .<10> resumeTaskWithIdentifier, props (null)
  ```

  — with `props (null)` marking daemon-initiated resumes against the app's
  own `props <private>`. It ran up to **11** concurrent transfers against a
  configured limit of 2. Holding tasks back would therefore buy no reduction
  in server load at all, only a stalled queue. The limit stays meaningful
  while the app is open, which is what the Downloads settings footer now
  says.

  **Server cost measured, on the shipped code.** A 22-episode season released
  this way with the phone backgrounded and locked throughout, transcode cache
  cleared first so every request had to produce a real encode:

  | | throwaway experiment build | shipped |
  |---|---|---|
  | transcode jobs for 22 episodes | 32 | **24** |
  | duplicate encodes | 10 | **2** |
  | peak concurrent transcodes | 11 | **6** |
  | peak host load (10 cores) | ~70 | ~37 |
  | non-zero ffmpeg exits | 0 | **0** |
  | drain time | ~48 min | ~36 min |

  All 22 landed as completed downloads on the device. Most of the experiment
  build's waste was a bug in that throwaway code — it created two tasks per
  episode, having assumed `downloadTask(with:)` returns a `.suspended` task
  on a background session, which it does not — and halving the task count
  roughly halved the peak concurrency and host load with it.

  **Two duplicate encodes remain, and they are inherent rather than a
  defect.** Both had their first encode inside the release burst and were
  re-encoded ~32 minutes later:

  ```
  S01E04  14:01:49 -> 14:34:50
  S01E16  14:01:49 -> 14:33:04
  ```

  iOS opens more connections than it is ready to consume, Jellyfin encodes
  for each, the unread output is discarded, and a fresh encode is needed when
  the daemon finally services that transfer. The cost scales with burst size,
  so ~2 per season is the expected order. Reducing it would mean staggering
  task creation, which trades complexity — and some of the unattended
  completion this whole change exists for — against a few minutes of server
  CPU. Not worth it at this ratio; revisit if a much larger queue makes the
  burst materially worse.

  **Resume data is still deliberately absent.** `cancel(byProducingResumeData:)`
  needs a server that supports byte ranges and a stable validator. A Jellyfin
  progressive transcode (`Static=false`) is a chunked response with no
  `Content-Length` and no range support at all — the same property that forced
  the duration-validation fix above — so there is nothing to resume from. An
  interrupted transfer restarts, which is why the retry backoff is tuned to
  keep the *server's* job alive across the gap rather than to preserve bytes.

  Two smaller faults found and fixed alongside it, both of which got worse the
  more items were queued:

  - `adHocFetchSession` (subtitle/artwork/trickplay/chapter fetches) was a
    *computed* property that constructed a brand-new `URLSession` on every
    read and never invalidated any of them — four reads per item for artwork
    alone. A ten-episode season download leaked dozens.
  - The transcode-progress poll loop was started at `enqueue` for **every**
    item, including ones still queued behind the concurrency limit with no
    server-side job to ping yet. Besides the pointless traffic, the loop only
    trusts the device's single shared `TranscodingInfo` while exactly one poll
    loop is running — so merely *queueing* anything permanently suppressed the
    live completion percentage for the download that was actually running. It
    now starts at admission.

## A finished-but-never-played download could appear watched

  Reported after the fix above shipped: an item that finished downloading but
  was never actually opened started showing up in Home's Continue Watching
  rail at a nonzero watched percentage. That rail is entirely server-driven
  (`GET /Users/{userId}/Items/Resume`, filtered server-side on
  `UserData.PlaybackPositionTicks` — confirmed via `HomeViewModel`/
  `MediaItem.playedFraction`, no client-side filtering exists), so the nonzero
  position had to be persisted server-side, and the download's keep-alive
  ping — the only playback-progress-shaped call anywhere in the download path
  — was the only plausible cause, even though it always sent
  `PositionTicks: 0`.

  This was checked directly against Jellyfin server source
  (`github.com/jellyfin/jellyfin`, not guessed) rather than assumed. Tracing
  `PlaystateController.ReportPlaybackProgress` → `SessionManager
  .OnPlaybackProgress` → `UserDataManager.UpdatePlayState` confirms a literal
  `PositionTicks: 0` is written back as exactly `0`. The idle-timeout path
  (`SessionManager.CheckForIdlePlayback`, a 5-minute sweep that synthesizes a
  `Stopped` call for any session that's stopped checking in) also traced
  clean — it uses `SessionInfo.LastPlaybackCheckInPositionTicks`, a snapshot
  taken only at the last real check-in, never the separate, second-by-second
  dead-reckoning "now playing" position server sessions maintain internally
  (`SessionInfo.StartAutomaticProgress`/`OnProgressTimerCallback`, which does
  extrapolate a climbing position once a real check-in starts it — and which
  this download session, never sending an explicit `Stopped`, never told to
  stop either). That second, ever-climbing value never showed up written to
  persisted `UserData` in any path traced through `master`, so the *exact*
  mechanism that lands on a persisted nonzero value on whatever server
  version is actually deployed remains unreproduced from source alone —
  server internals can differ by version, and the download path is the only
  place in this app that ever sends an indefinite stream of `Progress` pings
  against a real `PlaySessionId` with no bracketing `Start` and no bracketing
  `Stop`, unlike every real playback session (`PlayerViewModel`).

  Rather than chase a version-specific mechanism further, the source search
  turned up something better: `PlaystateController` also defines a dedicated
  `POST /Sessions/Playing/Ping?playSessionId=...` endpoint
  (`PingPlaybackSession`) whose entire body is
  `_transcodeManager.PingTranscodingJob(playSessionId, null)` — no
  `SessionManager` call, no `NowPlayingItem`, no `PlayState`, no automatic-
  progress timer, nothing `UserData`-adjacent at all. It exists purely to
  reset a transcode job's kill-timer, which is the *only* thing the download's
  keep-alive ping was ever trying to do. `pingDownloadTranscode` now calls
  this instead of reusing `reportPlaybackProgress`'s
  `/Sessions/Playing/Progress` — a structural fix rather than a careful choice
  of position value: it doesn't just avoid creating a fake watched session, it
  can't create one, regardless of server version. `DownloadManager` no longer
  needs to pass an item or media source to the ping at all — the endpoint
  keys purely on `PlaySessionId`.

- **No `DeviceProfile` is sent.** The app hand-builds the stream URL rather than
  negotiating through `PlaybackInfo`, which bypasses Jellyfin's own stream
  selection entirely. That's what makes the ladder fully deterministic, but it
  also means `MediaStream.deliveryUrl` comes back empty and subtitle routes have
  to be constructed by hand.
- **Download quality depends on server configuration this app cannot set.** The
  ladder assumes a competent HEVC encoder; a server using hardware encoding will
  produce visibly worse output at the same bitrate, and nothing in the app can
  detect or compensate for that. See
  [The encoder matters more than the bitrate](#the-encoder-matters-more-than-the-bitrate).
- **`VideoProfile=main10` is ignored** when the server hardware-encodes, so the
  10-bit efficiency gain is theoretical rather than realised there. The scaling
  filter emits `format=nv12` (8-bit) regardless. See
  [The bitrates assume HEVC](#the-bitrates-assume-hevc).
- **Transcoding is slow enough to notice.** With software encoding, a 101-minute
  film takes roughly 20–25 minutes to transcode before the download can finish,
  against ~13 minutes on hardware. About 9 minutes of that is a fixed floor for
  decoding and scaling a 4K source and cannot be reduced. A bulk season download
  is measured in hours.

---
