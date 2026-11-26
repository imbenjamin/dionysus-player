# Networking: sign-in, discovery and certificate trust

Loaded when working in `Core/Networking/`. The root `CLAUDE.md`,
"Networking", has the API client, re-authentication and the playback and
download request paths; this file has Quick Connect, server discovery,
trusting a server's certificate (#466) and the discovered-server HTTP
fallback.

**Quick Connect** (`QuickConnectView`/`QuickConnectViewModel`, offered when
`/QuickConnect/Enabled` says so): the server issues a 6-digit code, another
signed-in client approves it, and the secret is exchanged at
`/Users/AuthenticateWithQuickConnect`. A code expires 10 minutes after it's
issued, and polling it then answers **404**, which is how expiry is detected
(`QuickConnectManager.cs`, 10.11 and 12.z). A Quick Connect session has no
password, which shapes three things:

- **`StoredCredentials.authMethod` says which kind of session it is.** A
  `.quickConnect` session validates its token with `GET /Users/Me` at launch
  instead of signing in. It's explicit, not inferred from `password == nil`,
  because passwordless accounts store `""`; absent, it decodes as `.password`.
- **A mid-session 401 can't recover.** `authenticateWithQuickConnect` clears
  `reauthCredentials`, so `sendRaw` surfaces `.notAuthenticated` at once and
  never replays an earlier password sign-in, which would swap users.
- **The instructions name no menu path** ("open Quick Connect"): where it
  lives differs between Jellyfin clients.

**Approving someone else's code** is on the Account screen
(`QuickConnectApprovalView`, pushed from `AccountDetailsContent`, shown only
while Quick Connect is enabled). On iPhone and iPad the sixth digit
submits the code (`setCode` says when an edit completes it): from iPadOS
27.2 the number pad is a popover whose first outside tap only closes it, so
Authorize took two taps. The button stays, for retrying a code.
`POST /QuickConnect/Authorize` (measured on 10.11.11) answers 200 `true`,
**404** for an unknown or expired code, **500** for one already approved
(indistinguishable from any server error, so the message says both), and 401
with Quick Connect off. It sends no `userId` (the server approves for the
caller; naming another user needs admin rights), and runs with
`maxReauthAttempts: 1`, since its 401 is a refusal;
`QuickConnectApprovalViewModel` asks `/QuickConnect/Enabled` again to tell
"turned off" from "session expired". There is no "approve this device?" step:
only the requesting device can see which device asked.

**Server discovery** (`ServerDiscovery.swift`, started as Find Your Server
appears) speaks Jellyfin's UDP protocol (`who is JellyfinServer?` to port
7359, answered with `{Address, Id, Name}`), **unicast to every host on the
subnet, never broadcast**: broadcast and multicast need the restricted
`com.apple.developer.networking.multicast` entitlement, and fail silently
without it, while the server (`AutoDiscoveryHost.cs`) answers the phrase in
any datagram. There's no
API to ask for Local Network access or read it, and **under the permission
prompt UDP sends are accepted and silently dropped** (seen on device), so the
reliable signal is the app going inactive: the scan keeps running and starts
over once active (`ScanSchedule`), and a scan whose every send is refused
reads as denied. A typed LAN address skips the scan, so its first HTTP request
raises the prompt and fails behind it; `probeAcrossLocalNetworkPrompt` waits
for the answer and retries once. The device's own address stays in the
sweep, which lets the Simulator find a server on its own Mac.

**A server whose HTTPS certificate fails can be trusted, from setup on** The user vouches for the certificate after seeing it; nothing is
ever switched off. What is stored with the server (`ServerConfiguration.
certificateTrust`, mirrored into `TopShelfSession`) is one of two kinds, chosen
when the offer is made (`ServerCertificateDetails`): **`.names`** when the
chain is fine except the hostname (a Let's Encrypt certificate reached by IP;
it renews with a new key every few months, so it is bound to the certificate's
DNS names, never to its bytes), else **`.certificate`**, the exact leaf's DER
(self-signed, unknown CA, expired). `ServerTrustPolicy.decide` answers every
challenge, in order: another origin than the configured server's, or a chain
the system already accepts, is the system's; `.names` accepts a chain the
system finds valid for one of the names (so a public certificate for some
*other* domain is refused); `.certificate` accepts an equal leaf, dates
ignored; anything else is **refused as `.performDefaultHandling`, never
`.cancel`**, so it still surfaces as the usual certificate `URLError` and every
error path keeps working, and is reported.

- **`ServerTrustRegistry`** holds the trust (and setup's *candidate*, used
  while it re-probes before anything is saved). It loads from
  `ServerSessionStore` at launch, since a background download relaunch can
  raise a challenge before `AppState.start()`. A refusal is reported **once
  per presented leaf per launch**, never per failed request; a leaf counts as
  reported only once a hook was told, so one refused before the hook was set
  is reported later.
- **A new `URLSession` takes `ServerTrustDelegate`**, as the session delegate
  on a session the app owns (`RemoteImageLoader`, downloads, the Top Shelf's,
  bound to a registry of its own; `DownloadTaskRouter` for the background
  ones). **A task passes `ServerTrustDelegate.forTasks(on: session)`, never
  `.shared`**: a per-task delegate replaces the session's for challenges, so
  passing `.shared` on the Top Shelf's session asked the extension's
  unconfigured registry and the shelf never loaded from a trusted server. On
  `URLSession.shared` (`data(for:delegate:)`, which delivers the challenge, as
  spiked) it gives `.shared`. A session without the delegate fails against a
  trusted server while sign-in works, the failure mode to look for.
  `ServerTrustSessionCoverageTests` drives the API client (on a session with
  a private registry) and the player's fetch against a real in-process TLS
  listener; the image loader and ad-hoc download session are type checks, the
  router a synthetic challenge. `TopShelfLoaderTests` drives the API client on
  the Top Shelf's own session.
- **AetherEngine is reached through `EngineTLS.serverTrustEvaluator`**, set by
  `ServerTrustEngineBridge` (in `Core/Playback/`, so `Core/Networking` and the
  Top Shelf's slice never import the engine) **only while a trust is stored**:
  with any evaluator set the engine adds a system-trust handshake to every
  `https` transcode load, a cost a server with no trust shouldn't pay. Direct
  play and the transcode's AVPlayer bypass both go through it (the engine
  mounts its `HLSOriginRelay` for an origin the system refuses).
- **Setup** (`ServerSetupViewModel`, typed or discovered) publishes a
  `CertificateTrustOffer` on a certificate failure carrying a peer trust:
  Trust This Certificate re-probes and signs in under the candidate before
  saving. For a discovered server, Use Unencrypted HTTP is the second answer
  and enters the opt-in HTTP fallback below, unchanged. A server saved before
  this change whose certificate starts failing gets the same offer instead of
  the login screen.
- **The warning** (`AppState.certificateWarning`, shown by
  `CertificateWarningPresentation` from `RootView`/`TVRootView`) is raised by
  the registry when a stored trust no longer covers the certificate (*changed*:
  both fingerprints) or none was stored (*untrusted*). A trust by name whose
  certificate still carries a trusted name but no longer verifies (expired, its
  CA removed) is *changed* too, but reads "…’s Certificate Is No Longer Valid"
  naming them, not "Has a New Certificate" (`CertificateWarning.lapsedNames`,
  matched by `ServerTrustPolicy.dnsName(_:covers:)`). Three answers: Trust
  New Certificate (confirmed; re-classified, saved, session restarted), Change
  Server (confirmed with Profile's own question), and **Not Now (Stay Offline)**, which resumes into the offline state
  with Downloads working, since a captive portal raises this in ordinary use.
  It **closes any other sheet or cover first**, but **never dismisses a
  player**: playback fails with `.sourceCertificateRejected` (its own message)
  and the warning shows once the player has gone. **Trust's restart signs in
  again on the same `JellyfinAPIClient`** (`start(isRelaunch: false)`): the
  signed-in views keep the client they were built with, and a new one left
  them on a revoked token whose re-authentication revoked the token just
  saved, so the Top Shelf's mirror 401'd. A refusal decided under a trust
  since replaced is dropped and handed back (`raiseCertificateWarning`).
- **Dependencies**: names are read with Apple's `swift-asn1` only. iOS and tvOS
  have no API for a certificate's subject alternative names, and
  `swift-certificates` would pull in swift-crypto's `_CryptoExtras`, which links
  BoringSSL into the app. It is linked to the two apps, never the Top Shelf.
- A private CA that renews leaves daily isn't covered (#499): install its root
  as a configuration profile.

**A discovered `https://` server whose certificate fails also gets an opt-in
HTTP fallback** (`ServerSetupViewModel.connect(to:)`), the second answer
after the trust offer. A server with HTTPS on and
no published URL advertises `https://<LAN IP>:<port>`, which a certificate
for a domain name (or a self-signed one) never validates. Nothing a
signed-out client can read reveals the HTTP port, so 8096 is tried first and
the user is asked if it's silent. The port that answers must report the
discovery reply's `SystemId` over `/System/Info/Public`, and nothing connects
until the user confirms going unencrypted. Only certificate failures
(`URLError.isCertificateFailure`) trigger it.
