# Store screenshots

Loaded when working in `Scripts/store-screenshots/`. These scripts make the
two copies of the screenshot sets in `store-screenshots/`
(`gen.py`, `shot.swift`, run through `Scripts/render-store-screenshots.sh`).

`store-screenshots/` holds two copies of the screenshot sets, made by
`Scripts/store-screenshots/{gen.py,shot.swift}` through
`Scripts/render-store-screenshots.sh`; README.md's "Store screenshots" has the
capture-then-render workflow. What the scripts don't say:

- **Two copies, two servers, never a personal one** (Benjamin, 2026-11-10):
  `store-screenshots/apple-app-store/` is captured against the App Review
  server (user `reviewer`; `docs/store/review-server.md`; **neither its
  hostname nor its domain ever goes in the repo**, only in App Store Connect
  and local notes) and is the **only** copy uploaded to App
  Store Connect. `store-screenshots/demo-jellyfin-org/` is captured against
  `demo.jellyfin.org/stable` (user `demo`, no password) and is shown only in
  README.md. The demo server isn't all public domain (Dracula and Sahara got
  tvOS 1.2.0 rejected under 5.2.3), so its images never go to the store.
  Each copy keeps its raw captures in its own `raw/`.
- **Neither server has HDR content** (all SDR). The review server has
  chapters and Sintel's ten subtitle tracks; the demo server has neither. A
  slide about Dolby Vision either describes the app's real capability or
  skips the claim; never fake HDR-looking video.
- **`xcrun simctl` has no orientation control.** Rotate through the
  Simulator's Device ▸ Orientation menu (`osascript` can drive it). `gen.py`'s
  landscape frame expects an upright image: Xcode 27's Device Hub (one window
  showing the device selected in its source list) saves it upright; the older
  Simulator needed `sips -r 270 <file>`.
- **iOS defers a download created while the Simulator is in the
  background**: foreground its window (`osascript` `perform action "AXRaise"`)
  and wait real time before capturing the Downloads slide.
- **The demo server's transcodes restart mid-download** for larger titles;
  wait out another cycle or pick a shorter title.
- `gen.py`'s `MAGENTA`/`ROSE_GOLD` are copies of `BrandColors.swift`; update both
  if the palette changes.
- **No alpha channel**: App Store Connect rejects one, so `shot.swift` renders
  into an opaque context; the render script's report shows `alpha:no` per file.
- **The iPhone Duo set** (`appstore-iphone-duo`, `gen.py`'s `DUO_SLIDES`) is one
  `APP_IPHONE_DUO` set holding outer (1398×2034) and inner landscape
  (2853×2007) frames together (tested by upload, 2026-10-31). Capture each
  display with `simctl io --display=primary-1|primary`: both save upright and
  both show the status bar override. Xcode's MCP taps land only inside the
  outer display's 466×678pt box, so navigate closed and unfold; and launch
  fresh closed rather than signing in there, or unfolding leaves the app tall.
- **Only iOS 27 Simulators take Xcode's MCP taps**, so the iPhone set comes
  from the iPhone 18 Pro Max (1320×2868, the 6.9" size) and the iPad set from
  the iPad Air 13-inch (M4). `orientation landscapeLeft` rotates them (not
  the Duo). Raw captures for every set are kept in each copy's `raw/`.
- **Go easy on the demo server's downloads**: ten parallel transcodes across
  two Simulators coincided with it answering 503 (2026-10-31). Download the
  short Caminandes films, one Simulator at a time.
- **Book and tabletop slides show the phone folded in 3D** (`pose=` in
  `DUO_SLIDES`; Benjamin, 2026-11-01), the capture split at the fold and
  each half turned (`BOOK_ANGLE`, `TABLETOP_BACK`/`TABLETOP_BASE`).
  `shot.swift`'s WKWebView snapshot flattens CSS 3D transforms to 2D, so
  `gen.py` projects them itself with Pillow and places the result as an
  image; don't move it back to CSS. Capture book slides in book pose: the
  grid's fold split only shows there, not open flat.
- **The Apple TV set** (`appstore-appletv`, `gen.py`'s `TV_SLIDES`, no device
  frame) is captured with `xcrun simctl io <udid> screenshot`, which works on
  tvOS with no rotation or status bar to handle; the 4K Simulator saves
  3840×2160, kept downscaled to 1920×1080 in each copy's `raw/appletv/`
  so the set can be re-rendered.
- **On the demo server the Top Shelf can show only Recently Added**: the demo
  user has no Continue Watching or Next Up (progress doesn't stick on the
  shared account). The store set has no Top Shelf slide: when it was made
  the shelf showed the static image, and its Recently Added fix (#351) hasn't
  been checked against the demo. Never capture it against a personal server.
- **The Apple TV player slide's subtitle names capabilities, not what's
  on screen**: Dolby Vision, HDR10+, Dolby Atmos and DTS:X (2026-10-20,
  after Spatial Audio shipped in #364). The frame is plain SDR, since the
  demo server has no such tracks; the subtitle is the claim, so never fake
  it in the picture. Atmos and DTS:X reach a receiver as Atmos only with
  Spatial Audio turned on (`DionysusTV/CLAUDE.md`, "HDR and audio on the Apple TV"), which
  the listing's description says. Avoid frames with burnt-in on-screen
  text behind the player's panel.
