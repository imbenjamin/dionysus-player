# Dionysus for Apple TV — Milestone 4: Player features

Status: design agreed in conversation with Benjamin on 2026-10-06; awaiting his review of this document.
Parent spec: `docs/superpowers/specs/2026-09-29-tvos-app-design.md` (milestone 4).
Prototype canvas: https://claude.ai/artifact/Wjp3J4eh4VGqMmmR7ntAKL, screens 12–15 (`Player`, `PlayerTabs`, `PlayerSkip`, `PlayerNextUp`).

## Goal

Bring the Apple TV player up to the iOS player's features and to Infuse's standard for scrubbing: scrubbing and scanning with trickplay, the swipe-down tabs, audio and subtitle choice, libass subtitles, Skip Intro/Credits, the compact Next Up card and Stats for Nerds. After M4 the four Profile settings that do nothing on tvOS today (Next Episode Countdown, Chapters in Scrubber, Subtitle Styling, Show Playback Stats Button) take effect.

Most of the logic already exists in the shared `PlayerViewModel`: track switching and memory, the libass pipeline, media segments, the Next Up countdown, chapters, Jellyfin trickplay tiles and `PlaybackStats`. Core and libass already compile and link into `DionysusTV`. M4 is mostly tvOS views and a model of the remote.

## Decisions (Benjamin, 2026-10-06)

| Area | Decision |
|---|---|
| Remote handling | The player's own input model. The tvOS focus engine is not used inside the player: the host's recognizers take every press and touch-surface swipe and the model decides what each means, as Sodalite (AetherEngine's author's tvOS client) does. The overlay draws its own focus highlight. |
| Accessibility | VoiceOver navigation in the player is not part of M4. It moves to a new **M5: accessibility**, with a pass over the whole TV app; the old M5 becomes M6. M4 still passes the structural accessibility audit (labels and traits). |
| Scrubbing | Native-style (revised after the Simulator review, 2026-10-06). Playing: a press of Left/Right skips 10s; a hold or a swipe pauses and enters scanning at level 1 in its direction; each further press or swipe steps the level, -3/-2/-1/stop/+1/+2/+3, the opposite direction slowing through a stop. Paused: a swipe scrubs freely, a press steps 10s. The picture stays paused while scanning; only the trickplay preview moves. Select or Play/Pause plays from the preview; Menu returns to where it started and resumes. |
| Feedback glyphs | A glyph flashes mid-screen for play, pause and each 10s skip; the scan shows its direction and speed beside the preview's caption. A focused scrubber shows a knob at the playhead. |
| Scanning and buffered range | In M4 (Benjamin asked for both). Scan levels are 8x, 32x and 64x of real time (Benjamin, after trying them on the Simulator), tuned again on the device in Task 11. |
| HDR chip | Shown only while the engine reports the picture as HDR; nothing while it reads SDR. Best effort to know the presented format: investigate further evidence on the device (below). |
| Info tab | Like the system player's, with a Restart button. Artwork: a movie's portrait poster; otherwise the episode's landscape thumb, falling back to the show's thumb. |
| Audio and Subtitles | Two lines per track with the iOS picker's text. |
| Stats for Nerds | A toggle on the Stats icon, never a tab and never modal: the panel takes no presses, and the rest of the player works as usual around it. Gated by "Show Playback Stats Button", which is **Off by default on tvOS in every build**. |
| Skip Intro/Credits | Menu hides the button while nothing else is up; a second Menu closes the player. The button is always shown while the transport is up, so a hidden one can still be reached. |

## Architecture

### `TVPlayerInputModel`

A pure, `@MainActor` state machine, unit-tested by table. It holds the player's UI state:

- the chrome: hidden, or the transport up;
- transport focus: the scrubber, or one of the icons (Chapters, Audio, Subtitles, Stats);
- an open scrub or scan: where it started, the preview time, the scan direction and speed, and the play state to restore on cancel;
- the tabs panel, if open: the tab, and the focused row or tile;
- whether the stats panel is on;
- whether the current skip segment's button has been hidden;
- Next Up card focus: Play Now or Close.

It reads what it needs from `PlayerViewModel` (play state, duration, current time, chapters, tracks, `currentSkipSegment`, `nextEpisode`, `nextUpSecondsRemaining`). It takes remote inputs (Select, Play/Pause, Menu, Up, Down, Left/Right pressed and released, a horizontal swipe's translation and velocity, a swipe ending, clock ticks) and returns commands: seek, toggle play, pause, play, commit scrub, skip segment, play next, dismiss Next Up, choose an audio or subtitle track, restart, toggle stats, close. Time is injected so holds and scan ramps are testable without waiting.

### The host

`TVPlayerHostController` keeps its AVKit binding and the three host rules in CLAUDE.md. It changes as follows:

- Up and Down presses are added. Left/Right move from tap recognizers to `pressesBegan`/`pressesEnded`, so a press and a hold can be told apart without delaying the press: a press still acts on release. The hold threshold is about 0.4s.
- A `UIPanGestureRecognizer` restricted to indirect touches reports horizontal swipes. It commits to an axis after 40pt and starts a scrub only above 200pt/s, so a resting thumb never pauses playback (Sodalite's measured thresholds).
- Every press goes to the model; the host carries out the commands on `PlayerViewModel`. The host itself never decides what a press means.
- Moving to the next item happens in place: the session ends and reports its outcome, a new view model and engine are built for the next item and bound to AVKit, and nothing is dismissed. Every finished item reaches `RecentPlaybackBroadcaster`, so Home and the page beneath are current; `onClose` reports the last one.

### Layers

From the bottom: the video; subtitles; the stats panel; the transport or the tabs panel; Skip and Next Up. None takes interaction. Each draws focus from the model.

### Shared code

- iOS's `SubtitleOverlayView` (text and bitmap cues plus the libass layer) is compiled into `DionysusTV`, with TV sizes.
- The stats panel reads the same `PlaybackStats` as iOS's `PlaybackStatsOverlay`.
- New tvOS views: the scrub preview, the icon row, the tabs panel and its four tabs, the stats panel, the Skip button and the Next Up card.

## Transport and scrubbing

### Playing

- **Select and Play/Pause** pause or resume and show the transport (the system player and Infuse both do this). Today's Select only shows the transport.
- **A press of Left/Right** skips 10s, playback continuing.
- **Holding Left/Right** pauses and starts a scan in that direction.
- **A horizontal swipe** pauses and starts a scrub at the playhead.
- **Up** shows the transport. **Down** opens the tabs panel on Info.
- **Menu**: see the cascade below.

### The transport

As screen 12. The scrubber has focus by default. The icon row sits above it on the right: Chapters (only with chapters), Audio (only with more than one track), Subtitles (only with subtitle tracks) and Stats (only with its setting on). No dead stops.

- Up from the scrubber goes to the first icon; Left/Right move between icons; Down returns to the scrubber. Select on an icon opens the tabs panel on that tab; Select on Stats toggles the stats panel.
- The focused icon is a white capsule with a dark glyph.
- Elapsed time on the left (the preview time while scrubbing), remaining on the right, and the HDR chip between them under the rule above.
- The transport fades 4 seconds after the last press, as today, but never while paused, scrubbing or scanning, or with the panel open. When it fades, focus returns to the scrubber.
- **The buffered range** is a lighter fill from the playhead to the end of what is buffered, as in the prototype, drawn from the buffered-ahead reading Stats shows. Where a route reports none, there is no fill. The plan establishes which routes report it.
- **Chapters in Scrubber** (on by default) draws chapter ticks and makes a scrub snap to a nearby chapter start, as on iOS. Off, neither.

### Scrubbing and scanning

Revised after Benjamin's Simulator review of PR 1 (2026-10-06), to mimic the native player.

- A scrub moves a **preview**, never playback: the picture stays paused. The played fill stays at the playhead; a knob marks the preview, overlapping the track without changing its height. Above it: a 400×225 trickplay thumbnail and "52:15 · Chapter name". Without trickplay, the time and chapter alone. A focused scrubber shows the same knob at the playhead.
- **Scanning.** Playing, a hold of Left/Right (past 0.4s) or a horizontal swipe pauses and scans at level 1 in that direction. Releasing the hold leaves the scan running. Each further press or swipe steps the level: the same direction speeds up, the opposite slows, through a stop at level 0, then scans the other way: -3/-2/-1/stop/+1/+2/+3, at 8x, 32x and 64x of real time. A scan reaching either end stops there. The caption shows the direction as two, three or four triangles for levels 1 to 3, with no speed number, or a pause glyph at a stop.
- **Paused**, a swipe scrubs freely (a full-width swipe covers a quarter of the title, snapping to chapters with Chapters in Scrubber on) and a press of Left/Right steps the preview 10s. This is the path XCUITest drives.
- **Select or Play/Pause** seeks to the preview and plays. **Menu** cancels: the preview returns to the playhead and playback resumes if the scrub paused it.
- **Glyphs.** Play, pause and each 10s skip flash a glyph mid-screen, as the native player does.
- Scanning moves the preview rather than the picture: AetherEngine caps video playback at 2x forward with no reverse (`setRate`, AetherEngine#39), and Benjamin chose a paused picture over a partial real fast-forward.

### Menu, by what is open

1. A scrub or scan: cancel it.
2. The tabs panel: close it.
3. An icon focused: focus returns to the scrubber.
4. Next Up showing with the transport hidden: Close (below).
5. A skip button showing with nothing else up, not yet hidden: hide it.
6. Otherwise: close the player.

## The tabs panel

Screen 13, without its Stats tab: **Info, Chapters, Audio, Subtitles**.

- **Opening:** Down from the transport or with it hidden opens Info; Select on an icon opens that tab. Playback continues.
- **Layout:** the picture dims under a gradient, the scrubber and times rise to mid-screen, the tabs sit beneath them and the tab's content below.
- **Movement:** Left/Right along the tabs switches the tab as focus moves (as M3's season tabs follow focus). Down enters the content, Up returns to the tabs, Up from the tabs closes the panel with focus on the scrubber.
- **Closing:** Menu from anywhere in the panel, or 10 seconds without a press.
- **Focus look:** a focused row is a white capsule with dark text; a focused chapter tile has a white border and lifts slightly, as in the prototype.

### Info

The artwork on the left: a movie's portrait poster; for an episode its landscape thumb, falling back to the show's thumb. Then the title (an episode adds "S1:E3 · Name"), the metadata line (year · rating · runtime · genres) and the synopsis, cut to 4 lines. One button, **Restart**: Down lands on it, and Select seeks to 0:00, plays and closes the panel.

### Chapters

A rail of 380×214 chapter images captioned with the name and start time. A chapter without an image shows the trickplay frame at its start, else the film glyph (`MediaPlaceholderBox`). The current chapter carries the NOW chip and a bar for progress through it, and Down from the tabs lands on it. Select seeks to the chapter's start, plays and closes the panel.

### Audio and Subtitles

Lists of tracks, two lines each, with the iOS picker's text: `PlaybackTrack.title` over `PlaybackTrack.metadata`. Subtitles starts with Off, worded as on iOS. The chosen track is ticked. Select switches track, moves the tick and leaves the panel open so the change can be seen or heard. The choice is remembered per title in `TrackPreferenceStore`, as on iOS (`PlayerViewModel.selectAudioTrack` / `selectSubtitleTrack` already record it).

## Stats for Nerds

- The Stats icon toggles the panel; nothing else closes it. It takes no presses: Up, Down, Select and Menu do what they would without it. It stays through the transport fading and the tabs panel opening.
- **Top-right**, not the prototype's top-left, where the title block sits with the transport up. iOS anchors its panel top-right too.
- One glass page, not three: a 1920×1080 screen holds every row of iOS's three pages (video, audio, presented format, route and streaming, buffer, frames, server and AetherEngine version). Refreshed twice a second from `PlaybackStats`.
- The icon exists only while "Show Playback Stats Button" is on. tvOS takes its own default, Off in every build; iOS keeps its default (on in debug, off in release). Profile's Advanced page reads the same tvOS default.

## Subtitles

- **Placement:** cues sit above whatever chrome is up, using the same chrome-top measurement as iOS (`BottomChromeTopKey`): the transport, or the raised scrubber while the panel is open, so a subtitle just chosen in the panel shows above it. With the chrome gone they settle inside the title-safe area.
- **Size:** text cues are scaled for the viewing distance as a fraction of the picture's height, set against Infuse on the same title.
- **libass:** placement, margins and font scale are shared. On the TV the picture usually fills the screen, iOS's landscape case.
- **Subtitle Styling** already works through `PlayerViewModel`'s one gate; M4 tests it on tvOS.
- **Checked first, in the Simulator:** whether `AVPlayerViewController` draws a selected subtitle rendition itself, which would double every subtitle; if it does, suppress it the way the transcode path does (`setNativeSubtitleCapture`). Also that CoreText registers embedded ASS fonts on tvOS.

## Skip Intro/Credits

- A white capsule bottom-right, as in screen 14, with iOS's wording for each segment type, shown while `currentSkipSegment` is set.
- **Select skips** while the button shows with the transport hidden. With the transport up the button is its own focus stop above the icon row (Up from the icons, or from the scrubber when there are none; Down returns to the rightmost icon), and Select on the scrubber plays and pauses as usual (revised 2026-10-07: skipping from the scrubber drew the knob and the button focused at once). While Select would skip, the button is drawn focused. Play/Pause still pauses.
- **Hiding:** Menu with the transport hidden and nothing else up hides the button for the rest of the segment; a second Menu closes the player. With the transport up the button always shows, hidden or not, and is reached with Up. Hiding is the TV model's state, not iOS's `dismissSkipSegment`, which removes the button for good.

## Next Up

- The compact card, as in screen 15: a 420×236 thumb with a seconds chip, the countdown bar along its foot in the brand amber, "S1:E4 · Title" on one line, then **Play Now** and **Close**.
- Timing comes from the shared view model (`nextUpSecondsRemaining`, `nextUpTotalCountdownSeconds`, the end-credits anchor), so **Next Episode Countdown** takes effect. A playlist's next item comes from the queue, as on iOS.
- **With the transport hidden the card has focus**: Play Now first; Left/Right move between its buttons instead of skipping; Select activates. Menu means Close. With the transport up the card is the stop above the icon row, as Skip is (Up from the icons, or from the scrubber when there are none; Down to the rightmost icon); Menu there returns to the scrubber without closing the card (revised 2026-10-07).
- **Close** hides the card and cancels the countdown (`dismissNextUp()`); the episode plays to its end and the player closes.
- Up or a swipe shows the transport with focus on it; the card stays on screen unfocused. When the transport fades, focus returns to the card.
- **Play Now**, or the countdown reaching zero, moves to the next item in place (Architecture, The host).

## HDR: best effort on the presented format

What AetherEngine does, checked across every 7.x release (7.0.0–7.28.0) and in the 7.28.0 source:

- `videoFormat` claims HDR only on evidence, under AE#459 (since 6.82.0): AVPlayer still playing an HDR master 500ms after it was served, or EDR headroom above 1.00. Without evidence it reads SDR, by design.
- 7.x reduced the cases that read SDR wrongly: a DV source with an HDR10+ layer now reads HDR10+ (7.1.0); a refused master no longer labels every later title SDR for the life of the process (7.10.1); a master is no longer refused mid display-mode switch (7.22.2, AE#667, this app's report); a DV master on a source stating HEVC level 5.2 is no longer refused (7.23.2). 7.28.0's HDR Vivid detection leaves the label alone.
- It can still read SDR on an HDR picture: the first half second; a session that fell back to the media playlist; the software route (AV1/VP9 HDR), where only the headroom answers; and a server transcode, where the engine serves no master.

M4 shows the chip from `videoFormat` alone. On the Bedroom Apple TV it then investigates evidence for the software route and transcodes: the Match Dynamic Range state (`AVDisplayManager`), the completion of the mode switch the engine requested, and the transfer function of the stream being decoded. Whatever proves reliable goes to AetherEngine as an issue, so the engine stays the one place that decides the label. CLAUDE.md's HDR paragraph is corrected with these findings.

## Testing

**Unit tests** (`DionysusTVTests`) carry the weight:

- the input model as tables: every state and input against the commands returned, including the Menu cascade, Select with Skip, Next Up or icons up, and what Left/Right mean in each state;
- swipe travel to seconds, the axis and velocity thresholds, press versus hold, the scan's speed steps on an injected clock, chapter snapping, and restoring the play state on cancel;
- icon availability, the buffered fraction, the HDR chip's visibility and the tvOS stats default;
- the host carrying out commands against the harness's fake engine, and the in-place move to the next item.

**UI journeys** (`DionysusTVUITests`) on the stub server and fake engine, with new fixtures for chapters, several audio and subtitle tracks, intro and credits segments and a next episode:

- pause, Right ×3, Select: the elapsed time moves 30s; a hold of Right scans; Menu cancels to where playback was;
- Down opens Info and Restart returns to 0:00; a chapter jumps there; a track switch moves the tick and survives reopening the title;
- Skip appears and Select skips; Menu hides it; it returns with the transport; a second Menu closes the player;
- Next Up's Play Now loads the next episode; Close lets the episode end and closes the player;
- the Stats icon is absent by default; with the setting on it toggles the panel;
- the player's states join `AccessibilityAuditTests`' structural audit.

XCUITest and idb cannot send touch-surface swipes, so the swipe path is covered by unit tests feeding translations, then checked by hand on the device.

**Simulator** (by Claude): layout, focus, the panel, subtitle placement and the AVKit double-subtitle check. **Bedroom Apple TV** (with Benjamin): the HDR evidence investigation; scrub and scan feel against Infuse (swipe ratio, scan steps); subtitle size against Infuse; libass cost over a 4K picture; switching to an Atmos track.

Suites per PR: tvOS unit and UI; iOS unit and smoke too where a shared file changes (`SubtitleOverlayView`, `PlayerPreferenceKeys.swift`, `PlayerViewModel`).

## PRs

1. The input model, the host's press, hold and swipe routing, transport v2 (icon row, focus highlight, chapter ticks and snapping, buffered range, the HDR chip) and scrubbing and scanning with the trickplay preview.
2. Subtitles: the cue overlay and libass on tvOS, Subtitle Styling, and the AVKit double-subtitle check.
3. The tabs panel: Info with Restart, Chapters, Audio and Subtitles.
4. Skip Intro/Credits, the Next Up card, Next Episode Countdown and the in-place move to the next item.
5. Stats for Nerds and its setting, the device pass (HDR evidence, scrubbing against Infuse, subtitle size), and the docs that close the milestone.

Each PR updates CLAUDE.md's tvOS player section for what it adds, syncs the string catalog, and updates TESTING.md where it adds fixtures. PRIVACY.md is unaffected: no new data is stored or sent anywhere new.

## Out of scope

VoiceOver navigation inside the player (M5); Now Playing and Top Shelf (M6); AetherEngine's I-frame fast-forward. Not discussed for M4 and left out unless Benjamin asks: subtitle search and download, playback speed, and Picture in Picture.
