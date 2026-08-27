# Offline download quality

How Dionysus Player decides what an offline download actually contains — the
resolution tiers, the bitrate ladder behind them, why the defaults differ
between iPhone and iPad, and what a download deliberately gives up.

This document exists because the ladder is a set of numbers that each look
arbitrary in isolation. They aren't: they're derived from a single design rule,
and "tidying" one of them to a rounder figure silently breaks the property that
makes the tiers comparable to each other. The reasoning lives here so it
survives the next person to look at the table.

**Source of truth is the code.** `DownloadResolution.videoBitrate(preset:)` in
`DionysusPlayer/Core/Downloads/DownloadTypes.swift` is what ships; this document
explains it. `DownloadTypesTests.test_videoBitrate_everyRungLandsOnItsPresetBitsPerPixelTarget`
asserts the design rule directly, so a change that abandons it fails the suite
rather than drifting quietly.

---

## How a download is actually built

A download is **not** a copy of the file on the server. Jellyfin can serve the
original bytes (`/Items/{id}/Download`), and this app deliberately doesn't use
that endpoint. Every download is a server-side transcode, requested through
`JellyfinAPIClient.downloadStreamURL`:

```
GET /Videos/{itemId}/stream.mp4
      ?Static=false
      &Container=mp4
      &VideoCodec=hevc
      &AudioCodec=aac&AudioBitrate=…&MaxAudioChannels=2
      &MaxWidth=…&MaxHeight=…&VideoBitrate=…&VideoProfile=main10
      [&MaxFramerate=30]            # Data Saver only
      [&AllowVideoStreamCopy=true]  # replaces the four video params above
```

The result is a single MP4 with one HEVC video track and one AAC-LC stereo audio
track. Subtitles are fetched separately as sidecar files, not muxed in.

This is a different path from **playback**, which is direct-play only
(`streamURL`, `Static=true`) — the server hands over the original stream and
AetherEngine decodes whatever it is. So the app both direct-plays *and*
transcodes, just in different places, and a statement like "this app doesn't do
transcoding" is only true of the playback half.

### Why transcode at all rather than copy the file?

Because the point of a download is a *device-sized* copy. A 4K HDR remux is
30–80 Mbps and tens of gigabytes; nobody wants that on a phone. Capping
resolution and bitrate is the entire feature.

The one exception is **stream-copy passthrough**: when the source video track
already satisfies everything the requested tier asks for, re-encoding it buys
nothing and costs twice — a second generation of lossy encoding, plus minutes of
server CPU. In that case the app sends `AllowVideoStreamCopy=true` and Jellyfin
muxes the existing video track into the output MP4 untouched. Audio is still
transcoded, so the output keeps the same MP4/AAC-stereo shape the rest of the
offline code assumes.

Passthrough requires **all** of: source codec is H.264 or HEVC; source width,
height and bitrate all already inside the tier; and the source is SDR. Unknown
metadata counts as ineligible — guessing wrong means handing the user an uncapped
original, which is the exact failure the capping path exists to prevent. The SDR
condition is not a technical limit but a bookkeeping one: a copied HDR source
would faithfully *preserve* HDR, which contradicts `DownloadedItem.isHDR` being
hardcoded `false` (see [Limitations](#limitations)). Lifting it is the obvious
next step, and needs the offline UI to become HDR-aware at the same time.

Two details here were established by probing a real server, and both are
counter-intuitive enough to be worth stating outright:

- **`VideoCodec` must list the source's own codec** — hence `hevc,h264` on the
  copy path. Jellyfin only copies a stream whose codec the client actually asked
  for. Requesting `hevc` alone against an H.264 source makes it *silently decline
  the copy* and transcode instead.
- **The resolution and bitrate caps are still sent**, even though a copy ignores
  them. They are the only thing bounding the fallback if the copy is declined.
  The first version of this code omitted them on the assumption they'd conflict
  with the copy; against a 1280×720 1.24 Mbps source that combination produced a
  **416×234, 343 Kbps** file — the copy was refused and nothing was left to
  constrain what replaced it.

---

## The ladder

Two independent axes: a **resolution tier** and a **quality preset**. Video
bitrate is a function of both; audio bitrate depends only on the preset.

| Tier | High | Normal | Data Saver |
|---|---|---|---|
| **4K UHD** 3840×2160 | 16 Mbps | 10 Mbps | 6 Mbps |
| **1080p Full HD** 1920×1080 | 4.5 Mbps | 3 Mbps | 1.5 Mbps |
| **720p HD** 1280×720 | 2.25 Mbps | 1.5 Mbps | 750 Kbps |
| **480p SD** 854×480 | 1.1 Mbps | 700 Kbps | 350 Kbps |

Audio, all tiers: **160 / 128 / 96 Kbps** AAC-LC stereo.
Data Saver additionally caps frame rate at 30fps.

### The design rule: constant bits per pixel

Every rung is derived from a **bits-per-pixel-per-frame** target, not chosen
independently. At 24fps:

```
bitrate = bpp_target × tier_factor × width × height × 24
```

| Preset | bpp target | What it means for HEVC |
|---|---|---|
| High | 0.095 | At/just past the quality knee — more bits stop buying visible improvement |
| Normal | 0.062 | Solidly good; the intended default experience |
| Data Saver | 0.032 | Deliberately lean — visibly compressed on hard content, and that's the trade being asked for |

Smaller tiers carry a **higher** bpp target, because there's less spatial
redundancy per pixel for the encoder to exploit at low resolutions — real-world
encoding ladders are not linear in pixel count:

| Tier | factor |
|---|---|
| 4K | ×0.85 |
| 1080p | ×1.00 |
| 720p | ×1.08 |
| 480p | ×1.15 |

That factor is why 480p Normal is 700 Kbps and not the 600 a linear ladder would
give. Resulting actual bpp per rung:

| Tier | High | Normal | Data Saver |
|---|---|---|---|
| 4K | 0.080 | 0.050 | 0.030 |
| 1080p | 0.090 | 0.060 | 0.030 |
| 720p | 0.102 | 0.068 | 0.034 |
| 480p | 0.112 | 0.071 | 0.036 |

The payoff is that **"Normal" means the same thing at every resolution.** A user
who switches tier changes how much detail is captured, not how well it's
compressed. Break that and the presets stop being comparable across tiers.

### The bitrates assume HEVC

`VideoCodec=hevc` is always requested, and the numbers are sized for it. HEVC
needs roughly 40% fewer bits than H.264 for equivalent quality — Jellyfin's own
`ScaleBitrate` uses that same factor internally. An earlier version of this
ladder used H.264-shaped numbers (1080p at 6/3/1.5 Mbps, ~0.12 bpp at the top),
which put the High rungs well past HEVC's quality knee and was the main reason a
default download ran roughly double the size of the equivalent tier on a
commercial streaming app.

`VideoProfile=main10` is requested unconditionally, including for SDR sources.
The theory: 10-bit HEVC encodes a few percent more efficiently than 8-bit
regardless of the source's own bit depth (more headroom in the encoder's internal
precision, less banding to spend bits correcting), and every iOS device that can
hardware-decode HEVC can decode Main10.

**In practice it is currently a no-op, and the docs should not pretend
otherwise.** Probing the reference server returns `Main` / `yuv420p` 8-bit output
whether the parameter is sent or not — VideoToolbox hardware encoding ignores it.
The request is kept because it costs nothing, is the correct thing to ask for, and
a server using software `libx265` would honour it. But no measured saving is
attributable to it today.

### Never upscale, never inflate

Two caps apply on top of the ladder, in `DownloadTranscodeCalculator.target`:

1. **Dimensions** never exceed the source's own.
2. **Bitrate** is looked up from the tier that matches the *achieved* resolution,
   not the requested one, and is additionally capped to the source's own video
   bitrate.

So requesting 1080p for a source only available in 480p gets 480p's rung
(700 Kbps), not 1080p's (3 Mbps). Both caps matter independently: a source can
easily have a bitrate above the requested tier's rung — an old, inefficient SD
encode — so the source-bitrate cap alone never pulls the number down to match the
achieved resolution.

The source bitrate used for that comparison is the **video stream's own**, not
`MediaSource.bitrate`. The latter is the whole container including every audio and
subtitle track, and comparing it against a video-only target made the cap too
generous by however much the audio weighed — far from negligible on a source
carrying a couple of lossless surround tracks.

---

## Benchmarking against commercial streaming apps

The ladder was calibrated against what the major streaming services actually
ship, because they have spent far more on perceptual tuning than this project
ever will.

| Service | Middle tier | Resolution | Data rate |
|---|---|---|---|
| Disney+ | "Medium" | 720p | ~1.0 GB/hr |
| Prime Video | "Better" | 720p | ~0.8 GB/hr |
| Netflix | mobile HEVC rungs | 720p | 1.1–1.75 Mbps |
| **Dionysus Player** | **720p / Normal** | **720p** | **~0.73 GB/hr** (1.63 Mbps) |

The single most important observation: **every one of them puts its middle,
recommended tier at 720p, not 1080p.** Before the 720p tier was added, this app's
ladder went straight from 1080p to 480p — so the default sat a full tier above
the industry norm, and the only alternative was too coarse to be a real choice.

### Worked example: *Elemental* (2023)

The source on the reference server, for grounding:

```
mkv, 22.50 GB, 101.5 min
  video  hevc  3840×2076  29.57 Mbps  Main 10  DOVIWithHDR10  23.81 fps
  audio  truehd  8ch  3888 Kbps
  audio  ac3     6ch   640 Kbps
```

Three real downloads, in the order they were measured:

| Download | Size | Effective rate | Looks like |
|---|---|---|---|
| 1080p / Normal, H.264-era ladder, hardware encode | **2.42 GB** | 3.18 Mbps | acceptable |
| 720p / Normal, new ladder, **hardware** encode | **1.25 GB** | 1.64 Mbps | visibly blocky |
| 720p / Normal, new ladder, **software** x265 | **1.15 GB** | 1.51 Mbps | good |
| *Disney+ "Medium" for reference* | *1.20 GB* | *1.58 Mbps* | — |

The first row is the load-bearing measurement for the *sizing* model: 3.0 Mbps
video + 160 Kbps audio over 6090 seconds predicts 2.41 GB, and the server
delivered 2.42 GB — a 0.5% overshoot that is essentially muxing overhead. Download
size is therefore fully determined by the ladder, and a size problem is always a
tier-selection problem rather than an encoder-settings one.

The second row is why the ladder alone was not enough. It hit its predicted size
almost exactly (1.24 GB predicted, 1.25 GB delivered) and looked *worse than the
2.42 GB file it replaced*. Size model right, quality wrong — see
[The encoder matters more than the bitrate](#the-encoder-matters-more-than-the-bitrate).

The third row is the shipping configuration, and it is **smaller than the second
while looking substantially better**. That is the content-adaptive behaviour a
CRF-governed software encode buys: it came in at ~1.38 Mbps of video against a
1.5 Mbps ceiling, spending less than it was allowed because the content did not
need it. The hardware encoder spent its full allowance every time.

Net against where this started: **2.42 GB → 1.15 GB, a 52% reduction**, at
noticeably better quality.

It also illustrates how much a download discards on a title like this: a 22.5 GB
4K Dolby Vision source with a lossless 7.1 TrueHD track becomes a 1.24 GB 720p
SDR file with a 128 Kbps stereo track — a 94% reduction, almost all of it before
the ladder is even involved.

Full predicted sizes at 101.5 minutes:

| Tier | High | Normal | Data Saver |
|---|---|---|---|
| 4K | 12.3 GB | 7.7 GB | 4.6 GB |
| 1080p | 3.6 GB | 2.4 GB | 1.2 GB |
| 720p | 1.8 GB | **1.24 GB** | 0.6 GB |
| 480p | 1.0 GB | 0.6 GB | 0.3 GB |

Note this source is 2.35:1 scope (3840×2076), so the 720p tier's 1280×720 box
actually yields 1280×692. Jellyfin preserves aspect ratio itself, so the output is
correct — but it means fewer pixels than the tier nominally implies, and slightly
*more* bits per pixel than the ladder targets. Letterboxed content gets a small
free quality bonus.

### Cross-check: Jellyfin's own resolution logic

Jellyfin ships a `ResolutionNormalizer` that picks an output resolution from a
requested bitrate. This app never invokes it — it hand-builds the stream URL
rather than negotiating through `PlaybackInfo` + `DeviceProfile` — but it's a
useful sanity check on whether a given rung is a sane operating point.

**Its thresholds are expressed in H.264 terms, and misreading this is easy and
consequential.** The table's own comment states the values are "in the scale of
SDR h264 bitrate at 30fps", so an HEVC figure has to be converted *up* before
lookup — divide by ~0.6. Comparing an HEVC bitrate directly against the table
understates the resolution it implies by roughly one full rung.

Worked through correctly, at the old 1080p/Normal setting: 3 Mbps HEVC ≈ 5.0 Mbps
H.264-equivalent, which lands in the `(1280, 6_000_000)` bucket — meaning
**Jellyfin's own logic would also have chosen 720p at that bitrate**, not 1080p.
Reaching 1920 wide requires 13.5 Mbps H.264-equivalent, about 8.1 Mbps HEVC.

One honest caveat: the current 720p/Normal rung of 1.5 Mbps HEVC ≈ 2.5 Mbps
H.264-equivalent, which sits just *below* the ~1.8 Mbps HEVC that table would want
for a 1280-wide output. Jellyfin's numbers are tuned for realtime-preset live
streaming with safety margin, and Disney+ ships 720p at this rate to hundreds of
millions of people, so the empirical anchor was preferred. If 720p/Normal ever
looks soft in practice, 1.8 Mbps is the fallback rung.

---

## The encoder matters more than the bitrate

**Read this before changing any number in the ladder.** The bpp targets above
assume a *competent* HEVC encoder. If the server is configured with one that
isn't, the ladder is not the thing to fix.

> **Scope.** Everything in this section was measured on one specific server:
> a **Mac mini (Apple M4)** running Jellyfin 10.11.11 with **Apple VideoToolbox**
> acceleration and its bundled ffmpeg 7.1.4-Jellyfin. The conclusions are
> **specific to VideoToolbox and do not generalise to hardware encoding as a
> category.** NVIDIA NVENC (Turing and later) and recent Intel QuickSync are
> considerably better encoders than Apple's, and unlike VideoToolbox they expose
> real multi-step preset ladders — so on those servers the preset lever genuinely
> works and switching to software may cost a great deal of time for little gain.
> If you run this app against different server hardware, treat the numbers below
> as a worked example of the *method*, not as settings to copy.

This was learned the expensive way. The first download at 720p/Normal came out at
exactly the predicted size and looked visibly blocky. The bitrate was not the
problem — the encoder was. Same source, same tone-map, same 1.5 Mbps target, VMAF
against a lossless tone-mapped reference:

| Encoder | VMAF | Transcode (101-min film) |
|---|---|---|
| `hevc_videotoolbox`, hardware | **77.7** | ~13 min |
| `libx265 superfast` (+ Jellyfin's own x265 overrides) | **87.8** | ~19–25 min |
| `libx265 medium` | 88.6 | ~33 min |
| `libx265 slow` | 91.6 | ~54–70 min |
| `SVT-AV1 preset 8` | 90.8 | ~24 min |

VMAF below 80 is noticeably impaired; 90+ is near-transparent on a phone. **Apple's
hardware HEVC encoder tops out around 77.7 no matter how it is configured** — it
is built for realtime capture, not for archival encoding. Matching software output
would need roughly double the bitrate, which cancels the entire point of the ladder.

Two things that look like they should help, and don't:

- **The encoding preset does nothing on hardware.** Jellyfin maps its nine presets
  onto VideoToolbox as a single boolean, `-prio_speed`: `veryslow`/`slower`/`slow`/
  `medium` set it to 0, everything else (including the `Auto` default) sets it to 1.
  Measured difference between the two: **+0.49 VMAF**. Not a lever.
- **The CRF settings do nothing on hardware.** Jellyfin's own UI says so directly
  under those fields. VideoToolbox has no constant-quality mode at all — it takes a
  target bitrate and spends it.

One question this investigation raised but didn't resolve: the ffmpeg command
Jellyfin generates (`scale_vt=...color_transfer=bt709`) has no separately visible
tone-map filter despite "Enable VideoToolbox Tone mapping" being on, which left
open whether `scale_vt` was doing a real tone-map or a naive BT.2020→BT.709 matrix
conversion that would flatten HDR highlights independently of the blockiness
above. **Confirmed on device after the encoder fix (2026-08-27): no washed-out or
flattened look** — the HDR→SDR tone-mapping is working correctly. That rules the
second failure mode out; the encoder was the whole story.

### Measuring your own server

Rather than copying the settings below, spend twenty minutes getting the number
that applies to your hardware. Extract a ~40-second clip from a demanding title,
build a lossless reference at the target resolution, encode it with your server's
encoder and with `libx265` at the same bitrate, and score both:

```sh
ffmpeg -i candidate.mp4 -i reference.mkv \
  -lavfi "[0:v]setpts=PTS-STARTPTS[d];[1:v]setpts=PTS-STARTPTS[r];[d][r]libvmaf" \
  -f null -
```

A gap of a point or two means keep hardware encoding. Ten points, as measured
here, is a different decision entirely.

### Recommended server configuration for *this* bench

Apple VideoToolbox specifically — see the scope note above before applying these
elsewhere. On Jellyfin's Playback → Transcoding page:

- **Enable hardware encoding: OFF.** This is the whole fix. Leave *Hardware
  acceleration: Apple VideoToolbox* and every hardware **decoding** box ticked —
  decode and Metal tone-mapping stay accelerated and free; only the encode moves
  to software.
- **Encoding preset: `superfast`.** This is the knee of the curve. `medium` costs
  ~70% more time for +0.8 VMAF; `slow` costs ~3× for +3.8. Not worth it.
- **H.265 encoding CRF: `23`** (Jellyfin's default of 28 stops early — it produced
  only 931 Kbps of a 1500 Kbps budget and gave up 5.6 VMAF for it).

The payoff is that CRF-governed software encoding is *content-adaptive*: it comes
in under the cap on easy scenes and spends the budget on hard ones. Hardware
encoding spends the full budget unconditionally, which is why the old files hit
their bitrate target to within 1% every time.

Note Jellyfin injects its own `-x265-params` on top of whatever preset is chosen
(`no-sao=1`, `no-scenecut=1`, `subme=3`, `rc-lookahead=10`, and others). Those cost
about 1 VMAF versus a plain preset and save time, so the trade is reasonable — but
it means a bare `x265 -preset superfast` benchmark run outside Jellyfin will read
about a point optimistic.

**AV1 is the interesting road not taken.** SVT-AV1 preset 8 scored highest of
anything under 30 minutes. It is not used because the app hardcodes
`VideoCodec=hevc`, AetherEngine's AV1 path is unverified, and only iPhone 15 Pro
and newer can hardware-decode it. Worth a separate experiment.

## Why the default differs between iPhone and iPad

**iPhone defaults to 720p. iPad defaults to 1080p.**
(`DownloadResolution.deviceClassDefault`)

This is grounded in angular resolution, not taste. What matters for perceived
sharpness is not the pixel count but **pixels per degree** of the viewer's visual
field — a function of video size and viewing distance together. Human visual
acuity tops out around **60 ppd**; beyond that, additional pixels cannot be
resolved at all.

| Device | Video width | Typical distance | 720p | 1080p |
|---|---|---|---|---|
| iPhone 16 Pro | 4.6" | ~32 cm | **62 ppd** | 94 ppd |
| iPad mini 8.3" | 7.0" | ~35 cm | 45 ppd | 68 ppd |
| iPad Pro 13" | 10.4" | ~45 cm | 39 ppd | **58 ppd** |

On a phone, 720p already sits at the acuity limit — 1080p there is spending
storage on detail the eye physically cannot separate. On any iPad, 720p falls
well short and 1080p is the rung that lands right at the limit.

The consequence is deliberate and worth stating plainly: **iPad downloads barely
shrink.** A 13" tablet genuinely needs the bits. iPads get their savings from
stream-copy passthrough and the video-bitrate cap instead of from the ladder.

The check branches on `userInterfaceIdiom` rather than hardcoding a phone
assumption, because the planned tvOS and macOS ports will both want 1080p or
higher. Download preferences are device-wide `UserDefaults` and never synced to
the server, so a per-device default cannot produce a cross-device conflict.

Both the default in `DownloadPreferencesStore` and the `@AppStorage` default in
`DownloadsSettingsView` declare this, and **nothing catches drift between them** —
change them together.

---

## Limitations

- **HDR is always lost.** Any download of an HDR10/HDR10+/Dolby Vision source
  comes back SDR. This is a hard limitation of Jellyfin's server-side transcoder,
  not of this app's request: Jellyfin tone-maps to SDR on every transcode and has
  no HDR-to-HDR path, regardless of profile or device capabilities.
  `DownloadedItem.isHDR` is hardcoded `false` to reflect this honestly rather
  than mislabel a tone-mapped file. Stream-copy passthrough is the one route that
  *could* preserve HDR, which is exactly why it is currently gated to SDR sources.
- **Audio is always AAC-LC stereo.** Surround, Atmos, TrueHD and DTS are all
  downmixed on download (`MaxAudioChannels=2`). Only the *source track* is
  selectable, not its format. Live playback is unaffected and passes surround
  through normally.
- **Image-based subtitles are dropped.** PGS, VobSub and DVB tracks are bitmap
  formats with no text to extract; they're skipped and recorded on the download
  row so the UI can say so.
- **No `Content-Length`, so progress is an estimate.** A `Static=false` response
  is chunked, so the real output size isn't known until the transfer finishes.
  Progress is computed against `(videoBitrate + audioBitrate) × runtime`, which
  is why a download can sit at 100% briefly while the last bytes arrive.
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

## Changing the ladder

If you need to move a number:

1. Work out the bpp it implies (`bitrate ÷ (width × height × 24)`) and check it
   against its preset's target in the table above.
2. Run `DownloadTypesTests` — the bpp rule is asserted directly, so a rung that
   drifts off its target fails rather than passing quietly.
3. Update the tables in this document in the same change. Nothing in CI compares
   the two, the same gap `PRIVACY.md` has.
