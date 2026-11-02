# Apple TV App Review notes

The `TV_OS` version's Notes for Review in App Store Connect, kept here for the
record (App Review Information → Notes; 4,000 characters at most). Sign-in
account: `demo`, password left empty. Everything between the rules is pasted
verbatim.

---

Dionysus Player for Apple TV is a client for Jellyfin, the free, open-source media server that people install on their own hardware. The app has no content, catalogue or service of its own.

HOW TO SIGN IN (about a minute with the Siri Remote)
1. Choose Get Started.
2. If tvOS asks to allow access to devices on your local network, either answer works. The app looks for Jellyfin servers on the local network; there are none on the review network, so the list stays empty.
3. Choose Enter Server Address, type https://demo.jellyfin.org/stable and choose Connect.
4. On Who's Watching?, choose "demo".
5. The app offers Quick Connect first (a code approved from another signed-in device). Choose Use Password Instead, leave the password empty and choose Sign In.

demo.jellyfin.org is the Jellyfin project's official public demo server. Its library is public-domain and Creative Commons titles, published for exactly this purpose. It is one account shared by everyone, so if a request is ever refused, relaunch the app and sign in again.

WHAT TO TRY
The sidebar on the left (press Menu or Left to open it) holds Profile, Home, Search and the libraries. Choose any title, then Play. While playing, swipe down for info, audio and subtitles; press Menu to leave the player. Profile holds the settings, the privacy policy and Sign Out. The demo server's titles are SDR with stereo audio, so the Dolby Vision, HDR and Spatial Audio features in the description apply to a user's own files and can't be seen on it.

ACCOUNTS
The app creates no accounts. People sign in with an account that their own server's administrator made, so there is nothing to register or delete in the app. Sign Out removes the account from the Apple TV.

CONTENT
On first launch the app asks for the address of the user's own Jellyfin server and their credentials for it. Every request goes to that one address over the Jellyfin REST API. The app connects to no other media service, ships no default server, and offers no way to find or acquire content. Responsibility for the content on a server rests with the person who runs it, as for any personal media player. The Apple TV app has no downloads.

NETWORK SECURITY (ATS)
NSAllowsArbitraryLoads is enabled because the app connects to whatever server address the user enters, commonly a device on their home network reachable only over plain HTTP, or over HTTPS with a self-signed certificate its owner made. Neither is under our control, so an exception-domain list isn't possible. The app talks to nothing but that server.
