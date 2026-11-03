# The Apple TV App Store listing

The `TV_OS` version's `en-US` page in App Store Connect (version 1.2.0), kept
here for the record. The name ("Dionysus Player"), subtitle ("Your media,
native everywhere"), age rating and App Privacy are shared with the iOS app
and unchanged. Screenshots: `store-screenshots/appstore-appletv/`, uploaded
to the `APP_APPLE_TV` set in order.

## Promotional text

Your Jellyfin library, native on Apple TV: Dolby Vision and HDR, Dolby Atmos and DTS:X with their height channels, Top Shelf and a player made for the Siri Remote.

## Keywords

`server,client,media,video,tv,shows,movies,apple tv,top shelf,4k,dolby,hdr,streaming,home,atmos,dts`

iOS's list with `download` and `offline` (the Apple TV has no downloads)
replaced by `apple tv` and `top shelf`, plus `atmos` and `dts` for Spatial
Audio; 98 of 100 characters.

## Description

Dionysus is a native Apple TV client for Jellyfin, the free and open-source media server. It's built from the ground up for the big screen, with a fast, modern, fully native feel: no web wrapper, no ads, no subscriptions, no account beyond the Jellyfin server you already run.

REAL HDR PLAYBACK
Dionysus decodes Dolby Vision, HDR10, HDR10+ and HLG video. It is not a downscaled or tone-mapped approximation. It works with your Apple TV's Match Content settings, so your TV switches to the right mode for each title. When your server and network support it, you get the same picture quality as the original file, untouched.

DOLBY ATMOS AND DTS:X, HEIGHTS INCLUDED
Apple TV can't send Dolby TrueHD or DTS-HD Master Audio to a receiver, so most apps play Atmos and DTS:X films as a flat 5.1 mix and lose the overhead channels. Dionysus can decode the height channels and objects and re-encode them as Apple's Spatial Audio, which your Apple TV sends to an Atmos receiver or soundbar as Dolby Atmos. Choose your speaker layout, from 5.1.2 to 9.1.6. Turn it on in Profile & Settings → Spatial Audio.

SMART, SERVER-AWARE STREAMING
The app negotiates with your Jellyfin server every time you press play. It uses Direct Play when your Apple TV can handle the source natively, or a transcode when it can't. The app chooses automatically, or you can force Direct Play if you'd rather control it yourself.

A PLAYER MADE FOR THE SIRI REMOTE
• Scrub with the touch surface and see trickplay previews of the scene you're scrubbing to
• Skip back or forward 10 seconds with a press
• Swipe down for info, chapters, audio tracks and subtitles, without leaving the picture
• One-press Skip for segments your server marks, and a Next Up card that plays the next episode without leaving the player
• Embedded and external subtitles, and multi-track audio selection

AT HOME ON YOUR APPLE TV
• Top Shelf shows what you're watching and what's next, so a show is one press from the Home Screen
• Now Playing on your iPhone, with play, pause and scrubbing from the Lock Screen or the Apple TV Remote
• Each Apple TV user gets their own sign-in, and a "Who's Watching?" screen switches between remembered accounts in one press
• Sign in with Quick Connect: approve a code from your phone instead of typing a password with the remote
• Find your server automatically on your home network
• Playlists, box sets and full show pages with seasons and episodes
• VoiceOver support across every screen, plus Reduce Motion and Reduce Transparency

PRIVATE BY DESIGN
Dionysus only ever talks to the Jellyfin server you configure. There's no analytics SDK, no ad network and no third-party service in the loop. Your watch history and credentials stay between your Apple TV and your server.

REQUIRES A JELLYFIN SERVER
This app is a client, not a media library. You'll need a Jellyfin server to connect to (free, open-source and self-hosted). If you don't have one yet, you can try Dionysus right away against Jellyfin's public demo server. You are responsible for hosting your Jellyfin server and content, and for meeting the copyright rules that apply to you.

ALSO ON IPHONE AND IPAD
Dionysus is available across iPhone, iPad and Apple TV. On iPhone and iPad you can also download movies and episodes to watch offline.

## URLs

- Marketing: https://github.com/imbenjamin/dionysus-player
- Support: https://github.com/imbenjamin/dionysus-player/issues

## Apple TV Privacy Policy

App Information's "Apple TV Privacy Policy" field (`appInfoLocalizations.privacyPolicyText`,
shared app info, set 2026-11-02), which tvOS shows in place of a link. A
plain-text summary of `PRIVACY.md` for the Apple TV app; update both together.

```
Dionysus Player Privacy Policy (last updated October 14, 2026)

Dionysus Player is a client for Jellyfin media servers. It has no server of its own: everything it does happens on your Apple TV or between your Apple TV and the Jellyfin server you connect it to. The Dionysus Player team cannot see your library, your sign-in details or what you watch, and collects no data from you.

STORED ON YOUR APPLE TV
- Your Jellyfin username, password (none is stored if you sign in with Quick Connect) and access token, kept in the Keychain for each account you sign in with, so you can switch on the "Who's Watching?" screen. They are kept separately for each Apple TV user, unless you turn off Follow Apple TV Users in Profile; then every user of this Apple TV shares them.
- Your server's address.
- A copy of your session (server address, user ID, access token and device identifier), so the Top Shelf can show your Continue Watching, Next Up and recently added titles from your own server. It shows whoever used Dionysus last; signing out deletes it.
- A random identifier made on first launch, which identifies this app to your Jellyfin server, as every Jellyfin app does. It is not Apple's advertising identifier and is never sent anywhere except your own server.
- Your audio and subtitle choices, recent searches and audio offset. These are never sent to the server.

SENT TO YOUR JELLYFIN SERVER
To sign in, browse, search and play, the app talks to the server you configured and no other. It sends your sign-in details, the identifier above and your playback progress, so Continue Watching and Next Up work. That is a server you control, not the Dionysus Player team.

During setup, Find Your Server sends Jellyfin's standard discovery message to devices on your network and lists the servers that reply. Before you sign in, the app shows the users and login-screen branding your server makes public. Nothing about you is sent, and none of it is stored.

WHAT WE DON'T COLLECT
No analytics, crash reporting, telemetry, advertising or tracking of any kind. Playback uses the open-source AetherEngine, and styled subtitles are drawn with libass, both on your Apple TV.

DELETING YOUR DATA
There is no Dionysus Player account; your account belongs to your Jellyfin server. In Profile, Sign Out removes your stored sign-in from this Apple TV, and Change Server also forgets the server. Deleting the app removes everything it has stored.

CONTACT
dionysusplayerteam@gmail.com, or open an issue at github.com/imbenjamin/dionysus-player. The full policy is in the app under Profile.
```
