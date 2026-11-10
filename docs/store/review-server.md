# The App Review server

A Jellyfin server run by the developer for App Review, so a reviewer never
depends on a third party's server or content. It exists because the Apple TV
app was rejected under guideline 5.2.3 (2026-11-09): the review notes pointed
at `demo.jellyfin.org`, whose library includes films still under copyright
(Dracula, 1931; Sahara, 1943), and App Review asked for documentary evidence
of rights to everything a reviewer can play. The plan is
`docs/superpowers/plans/2026-11-09-app-review-server.md`.

## What it holds

Only Blender Foundation open movies under a Creative Commons Attribution
licence, each confirmed on an official Blender page. The page, captured to PDF
with its URL and capture time, is in `review-evidence/`. The PDFs were rendered with WebKit, then compressed
through a copy of macOS's "Reduce File Size" Quartz filter (JPEG quality
0.5, 72 dpi, images at most 1000 px). Their text stays selectable. Files came from
`download.blender.org` and `video.blender.org` only.

| Title | Licence | Evidence (`review-evidence/`) | Source file |
|---|---|---|---|
| Big Buck Bunny (2008; 2013 "Sunflower" re-render) | CC BY 3.0 | `big-buck-bunny-license.pdf` (peach.blender.org/about); the file's own metadata says the same | download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_normal.mp4.zip |
| Sintel (2010) | CC BY 3.0 | `sintel-license.pdf` (durian.blender.org/sharing) | download.blender.org/durian/movies/Sintel.2010.1080p.mkv (md5 matches Blender's) |
| Tears of Steel (2012) | CC BY 3.0; soundtrack CC BY-ND 3.0 | `tears-of-steel-license.pdf` (mango.blender.org/sharing), `tears-of-steel-soundtrack-license.pdf` | download.blender.org/demo/movies/ToS/tears_of_steel_1080p.mov.zip, subtitles from …/ToS/subtitles/ |
| Cosmos Laundromat: First Cycle (2015) | CC BY 3.0 | `cosmos-laundromat-license.pdf` (gooseberry.blender.org/about) | video.blender.org, video f507dfdc…, 804p |
| Spring (2019) | CC BY 4.0 | `spring-license.pdf` (studio.blender.org/projects/spring/pages/about) | video.blender.org, video 3d95fb3d…, 804p |
| Sprite Fright (2021) | CC BY (the page says "Attribution 1.0") | `sprite-fright-license.pdf` (studio.blender.org/projects/sprite-fright/pages/about) | video.blender.org, video a69d68a5…, 804p |
| Charge (2022) | CC BY 4.0 | `charge-wikimedia-commons.pdf`, `charge-project-page.pdf`, `blender-studio-terms.pdf` | video.blender.org, video 04da454b…, 1080p |
| Caminandes 2: Gran Dillama (2013) | CC BY 4.0, from Blender Studio's terms | `caminandes-2-project-page.pdf`, `blender-studio-terms.pdf` | download.blender.org/demo/movies/caminandes_gran_dillama.mp4.zip |
| Caminandes 3: Llamigos (2016) | CC BY ("Licence: Attribution") | `caminandes-3-video-blender-org.pdf`, `caminandes-3-project-page.pdf`, `blender-studio-terms.pdf` | video.blender.org, video 23f3ef79…, 1080p |

`blender-studio-terms.pdf` says: "Unless notified otherwise, all digital
content (webpages, video, artwork, 3D data) is available under the Creative
Commons Attribution 4.0." Trademarks and logos are excluded. It is the main
evidence for Charge and Caminandes 2, whose own pages state no licence, and
for the artwork.

Left out:

- **Elephants Dream**: its credits say only "a Creative Commons License", with
  no version, and name a co-owner (Netherlands Media Art Institute).
- **Caminandes 1: Llama Drama**: no official Blender copy exists, only
  third-party uploads.
- **Anything public-domain or CC BY-NC**, by rule.

## Layout and metadata

`/Volumes/MediaStore/dionysus-review/`:

- `Movies/<Title> (<Year>)/`: the film, `poster.jpg`, `backdrop.jpg`, `movie.nfo`, and for Tears of Steel `.en/.de/.fr/.es.srt`.
- `Shows/Caminandes (2013)/`: `tvshow.nfo`, `poster.jpg`, `backdrop.jpg`, and `Season 01/` holding episodes 2 and 3, each with an `.nfo` and a `-thumb.jpg`.
- `source/`: not served. It holds Blender's `copyright.txt` and Sintel md5, `SHA256SUMS` (the downloads) and `LIBRARY-SHA256SUMS` (the served files).

Every NFO sets `<lockdata>true</lockdata>`, and its plot ends with the title's
attribution line. Posters and backdrops are Blender Studio's own key art
(the `_o.webp` original behind each project page's `og:image`), cropped to 2:3
for posters. Charge's key art carries the film's title logo, which the CC grant
excludes, so its poster is cropped clear of the logo and its backdrop is a
frame of the film at 3:00. No image comes from TMDB or any other catalogue.

Sprite Fright's attribution reads "Creative Commons Attribution", without a
version, as its page gives "1.0", which is likely a typo for 4.0.

## Adding a title

1. Confirm its licence is CC BY on an official Blender page.
2. Save that page to PDF in `review-evidence/`.
3. Add its NFO, with the attribution line and `lockdata`.
4. Take its artwork from Blender's own release, never from a catalogue.
5. Add a row to the table above.

## The server

A Jellyfin 12.4 container, `jellyfin-review`, defined in
`~/Docker compose/jellyfin-review/compose.yaml` on the Mac mini (outside the
repo, beside the other stacks), running under OrbStack:

- It listens on `127.0.0.1:8097` only, so nothing on the LAN reaches it;
  the tunnel is its only way in.
- It sees `Movies/` and `Shows/` read-only, and no other host path:
  `source/` and the personal library stay out of reach.
- Its configuration and cache are in named volumes
  (`jellyfin-review_config`, `jellyfin-review_cache`), separate from the
  personal server on 8096.
- The image tag is pinned. Update it on purpose, and run the checks after.

Checks: `curl http://127.0.0.1:8097/System/Info/Public` answers, the same
request to the Mac's LAN address fails, and `touch` inside `/media/Movies`
or `/media/Shows` in the container fails with "Read-only file system".

## Settings

Set through the API on 2026-11-10; rebuild them by hand from this list.

- **Wizard:** server name "Dionysus Review", metadata language English,
  country GB, remote connections allowed, UPnP off.
- **Accounts** (passwords in Benjamin's Bitwarden, never in the repo):
  - `review-admin`: the administrator. Hidden from the sign-in screen, and
    remote access off, so it signs in only from this Mac.
  - `reviewer`: the only visible user. Plays, transcodes and downloads, but
    can't administer or delete anything. Public sharing, SyncPlay, shared
    device control and Live TV are off. Its password is lowercase letters
    only, so it's easier to type on an Apple TV.
  - **No lockout** for `reviewer`. The username is public (the sign-in
    screen lists it), and the hostname can be guessed or seen in the
    review notes' path through Apple. Anyone could make five bad guesses
    and lock the account in the middle of a review. A 20-letter random
    password is safe from guessing anyway.
- **Quick Connect:** on (the Apple TV notes use it).
- **Proxy:** `KnownProxies` is `192.168.148.1`, the Docker network's
  gateway, where cloudflared's requests come from. Without it every visitor
  looks local (a private address), and "remote access off" for the admin
  does nothing. With it, Jellyfin takes the visitor's address from the end
  of `X-Forwarded-For`, which Cloudflare appends, so a visitor can't pass as
  local. If OrbStack ever gives the network a different gateway, update
  this setting.
- **Libraries:** Movies (`/media/Movies`) and Shows (`/media/Shows`). For
  every item type: no metadata fetchers, no image fetchers and no metadata
  savers, with the NFO reader on. Real-time monitoring and automatic refresh
  are off. Chapter image extraction is on, during scans too (2026-11-10), so
  Sintel's eight chapters, the only chapters in the library, have
  thumbnails made locally by FFmpeg. Without them the chapter rows showed
  placeholders in the store screenshots.
- **Server-wide metadata options** (these cover people and studios, which
  the library options don't): TheMovieDb, The Open Movie Database,
  TheAudioDB, MusicBrainz and Studio Images are off for every item type.
- **Plugins:** the bundled ones (TMDb, OMDb, AudioDB, MusicBrainz,
  ListenBrainz, Studio Images) can't be disabled: Jellyfin re-enables them
  on restart. The settings above keep them from being used. Install no
  other plugin.
- **Scheduled tasks:** the triggers are removed from "Refresh People",
  "Refresh upcoming and missing episodes (TheMovieDb)" and "Update Plugins".

## Checks

`Scripts/review-server/check.sh <base-url>` signs in as the reviewer and checks:

- the server is set up, and `reviewer` is its only public user;
- the reviewer's policy, and that admin-only endpoints refuse it;
- the library holds exactly the 9 titles, each with its attribution;
- no title, series, season, person or studio carries an online ID, an
  online image or a community rating;
- deleting an item is refused.

It exits non-zero at the first failure. It takes the reviewer password from
`REVIEW_PASSWORD`, or else from this Mac's login keychain (service
`dionysus-review`, account `reviewer`; add it with
`security add-generic-password -s dionysus-review -a reviewer -w`). (Any signed-in user may *read*
`/System/Configuration` in Jellyfin, so the script doesn't probe that.)

A forced "replace all metadata and images" refresh of both libraries
(2026-11-10) left every title, overview and poster unchanged, and each
served poster matched the `poster.jpg` on disk byte for byte.

## Publishing: the tunnel

The server's public HTTPS address reaches the container through a
Cloudflare named tunnel, `dionysus-review`, made on 2026-11-10. There's no
port forwarding, and Caddy isn't involved. **The hostname and its domain
are kept out of this repo**: they're in this Mac's
`~/.cloudflared/config.yml`, in App Store Connect's review notes, and in the
maintainer's local notes. Pass the address to `check.sh` as `<base-url>`.

- **Config:** `~/.cloudflared/config.yml` has one ingress rule, the
  hostname to `http://127.0.0.1:8097`, and a 404 for anything else. The
  tunnel credentials are beside it, also outside the repo.
- **Startup:** a LaunchAgent in `~/Library/LaunchAgents/` (its file name
  ends `dionysus-review-tunnel.plist`) runs `cloudflared --config ~/.cloudflared/config.yml tunnel run` at login
  and restarts it if it stops. It logs to
  `~/Library/Logs/dionysus-review-tunnel.log`. It runs at login, not at
  boot, because the container needs OrbStack, which starts at login; the
  Mac logs in automatically.
- **The other tunnel:** this Mac also runs the account's `flix` tunnel, a
  system LaunchDaemon (`com.cloudflare.cloudflared`) from a token, with its
  routes set in the dashboard. Don't run `sudo cloudflared service install`:
  it would take that daemon's name.
- **Certificate:** Cloudflare's wildcard certificate for the domain, so the
  hostname never appears in Certificate Transparency logs. It's still
  guessable, though, so the reviewer's lockout stays off.
- **Caching:** a Cloudflare Cache Rule bypasses the cache for this
  hostname. Without one, Cloudflare would cache video URLs ending `.mp4`.

**Checked on 2026-11-10 through the tunnel:**

- The certificate validates, and `/Users/Public` lists only `reviewer`.
- The paths of the Mac's other services (`/flix/`, `/qbittorrent/`,
  `/prowlarr/`, `/sonarr/`, `/radarr/`, `/reboot`) all return 404.
- A user without remote access is refused when signing in through the
  tunnel. Jellyfin logs "remote access disabled and user not in local
  network" with the Mac's public address, and the same sign-in works over
  loopback.
- A visitor can't pass as local by sending their own
  `X-Forwarded-For: 192.168.…`.
- From an iPhone on cellular, `/web/` shows Jellyfin's sign-in, and the
  other paths give Jellyfin's empty 404. Safari offers that as an empty
  download.
- The router forwards no ports to this Mac. It had a port 53 forward,
  with nothing listening there, and that was removed on 2026-11-10.
- After a restart, with nothing started by hand, the Mac logged in, OrbStack
  brought the container back, the tunnel came up, and `check.sh` over the
  public URL passed.

One gap: Jellyfin's admin-only endpoints skip the remote-access test for a
token issued earlier. An admin token minted on this Mac still works through
the tunnel. Since the admin can't sign in remotely, no such token can be
issued from outside.
