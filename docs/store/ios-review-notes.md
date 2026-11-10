# iOS App Review notes

The `IOS` version's Notes for Review in App Store Connect, kept here for the
record (App Review Information → Notes; 4,000 characters at most). Sign-in
account: `reviewer` on the App Review server (`review-server.md`), its password
in App Store Connect's sign-in fields and Bitwarden, never here. Everything
between the rules is pasted verbatim, with `<review server URL>` and
`<review server host>` replaced by the real address, which is kept out of
this repo.

---

Dionysus Player is a client for Jellyfin, the free, open-source media server that people install on their own hardware. The app has no content, catalogue or service of its own.

HOW TO SIGN IN (about a minute)
1. Choose Get Started.
2. If iOS asks to allow access to devices on your local network, either answer works. The app looks for Jellyfin servers on the local network; there are none on the review network, so the list stays empty.
3. Choose Enter Address Manually, type <review server URL> and choose Connect.
4. On Who's Watching?, choose "reviewer", enter the password in the sign-in information above and choose Sign In.

<review server host> is a Jellyfin server run by the developer for App Review. Its library is Blender Foundation films under Creative Commons licences; the licences are attached.

WHAT TO TRY
Choose any title, then Play; Caminandes, under Shows, has two episodes, S1:E2 and S1:E3. Sintel has subtitles in several languages. Downloads are on a title's page and in the Downloads tab: Caminandes S1:E2, the shortest title, downloads in under a minute. Profile holds the settings, the privacy policy and Sign Out. The review server's films are SDR, so the Dolby Vision and HDR features in the description apply to a user's own files and can't be seen on it.

IPHONE DUO
Opening the phone lays a title's page out as two pages, and half folding it on a table puts the video above the fold and the controls below. To see it:
1. Sign in (above) and open any movie from Home.
2. With the phone open and held wide, the poster fills the left page and the details scroll on the right.
3. Choose Play, then half fold the phone and stand it on a table: the picture stays above the fold and the controls move below it. Home does the same in this pose: its large artwork ends at the fold.
Poses supported: closed, open (held wide and tall), book and tabletop. Playback, position and the screen you are on are kept when the phone folds or unfolds.

ACCOUNTS
The app creates no accounts. People sign in with an account that their own server's administrator made, so there is nothing to register or delete in the app. Sign Out removes the account from the device.

CONTENT
On first launch the app asks for the address of the user's own Jellyfin server and their credentials for it. Every request goes to that one address over the Jellyfin REST API. The app connects to no other media service, ships no default server, and offers no way to find or acquire content. The app contacts no metadata, catalogue or discovery service: titles, artwork and ratings come only from the user's server. Responsibility for the content on a server rests with the person who runs it, as for any personal media player.

DOWNLOADS
A download is an offline copy of a file already on the user's own server, made by that server as a device-sized transcode over the same signed-in session used for streaming, so nobody can download anything they couldn't already play. Downloads stay in the app's private storage: there is no file sharing, Files access, share sheet or export, and they are removed with the app. They are an offline playback cache, not files to extract or redistribute.

NETWORK SECURITY (ATS)
NSAllowsArbitraryLoads is enabled because the app connects to whatever server address the user enters, commonly a device on their home network reachable only over plain HTTP, or over HTTPS with a self-signed certificate its owner made. Neither is under our control, so an exception-domain list isn't possible. The app talks to nothing but that server.
