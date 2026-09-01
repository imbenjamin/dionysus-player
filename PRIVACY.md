# Privacy Policy

**Last updated: August 25, 2026**

Dionysus Player is a client for [Jellyfin](https://jellyfin.org) media
servers. It has no backend of its own: everything the app does happens
either on your device or between your device and the Jellyfin server *you*
configure it to connect to. The development team and contributors behind
Dionysus Player do not operate a server, cannot see your media library,
credentials, or viewing activity, and do not collect any data from you.

## Information We Collect

**We** don't collect anything — there's no Dionysus Player server for data
to be collected *to*. What exists instead:

### Data stored on your device

All of the following stays on your device, in Apple's Keychain or app
storage, and is never sent anywhere except where noted:

- **Account credentials** — your Jellyfin username, password (if your
  account has one), and access token, stored in the iOS Keychain.
- **Server address** — the URL of the Jellyfin server you configured.
- **A random device identifier** — a UUID generated once on first launch,
  used only to identify this app installation to your Jellyfin server (the
  standard way Jellyfin/Emby clients identify themselves). It is not
  Apple's advertising identifier (IDFA) or vendor identifier, isn't linked
  to your Apple ID, and is never sent anywhere except to your own server.
- **Playback preferences** — your chosen audio/subtitle tracks, media
  version selections, download settings, and recent search history, scoped
  to your Jellyfin account and never sent to the server.
- **Downloaded content** — video, subtitles, and artwork you choose to
  download for offline playback, stored in the app's local storage and
  excluded from iCloud/iTunes backups.

### Data sent to your Jellyfin server

The app communicates with the Jellyfin server you configure — and only
that server — to sign in, browse and search your library, request and
report on playback, and download media for offline viewing. This includes
your credentials (to authenticate), the device identifier above (standard
client identification), and playback progress (so "continue watching" and
"next up" work). This is data flowing to a server *you* control, not to
the Dionysus Player development team or contributors.

## What We Don't Collect

Dionysus Player contains no analytics, crash reporting, telemetry, or
advertising software of any kind. It does not use Apple's advertising
identifier or any cross-app tracking. It does not request access to your
camera, microphone, location, contacts, photo library, or health data —
it doesn't use any of those on iOS at all. The only device permission it
requests is local-network access, used solely to discover a Jellyfin
server on your Wi-Fi network.

## Third-Party Components

Dionysus Player's playback is built on [AetherEngine](https://github.com/superuser404notfound/AetherEngine)
and its own dependencies (FFmpegBuild, LibDovi, SMBClient), which decode
and play media on-device. We have no indication that these components make
network connections of their own beyond what Dionysus Player itself
directs (streaming or downloading from your configured server), but as
with any third-party software, we can't audit their internals directly.
The app also uses [SwiftUI-Shimmer](https://github.com/markiv/SwiftUI-Shimmer),
a small open-source loading-animation effect with no network access of its
own. See the in-app **License** screen (Profile → License) for the full
set of licenses involved.

## Data Retention & Deletion

There is no Dionysus Player account to delete, because there is no
Dionysus Player account — your account belongs to your Jellyfin server.
Within the app:

- **Sign Out** removes your stored credentials from the Keychain.
- **Change Server** does that and also forgets the configured server
  address.
- Neither clears downloaded content, saved preferences, or the random
  device identifier described above — those persist until you delete
  downloads individually, or delete the app entirely, which removes
  everything the app has stored on your device.

## Children's Privacy

Dionysus Player is not directed at children and does not knowingly collect
information from children — as above, it doesn't collect information from
anyone, of any age.

## Changes to This Policy

This policy is maintained in the open-source repository alongside the
app's source code and license, and will be updated there if the app's data
practices ever change. The date at the top of this document reflects the
last revision.

## Contact

Questions about this policy or how the app handles data can be sent to
**dionysusplayerteam@gmail.com**, or raised as an issue on the
[GitHub repository](https://github.com/imbenjamin/dionysus-player).
