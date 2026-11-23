# Trusting a server's unverifiable HTTPS certificate (#466)

Benjamin, 2026-11-23. Both apps (iPhone/iPad and Apple TV).

## Why

A Jellyfin server whose HTTPS certificate can't be verified can today only
be reached by dropping to plain HTTP (`ServerSetupViewModel.connect(to:)`,
the #429 fallback), and only when it was discovered on the LAN; a typed
`https://` address just fails with "Couldn't reach". Letting the user vouch
for that server's certificate keeps the connection encrypted.

Two kinds of server matter, and both are in scope:

1. **A real certificate reached at the wrong name.** A server with a
   publicly valid certificate for `media.example.com` (Let's Encrypt behind a
   reverse proxy, say) reached at `https://192.168.1.50:8920`. Everything but
   the name checks out. Let's Encrypt renews every 60 to 90 days, usually
   with a new key.
2. **A self-signed (or unknown-CA) certificate.** Nothing vouches for it but
   the user.

## Goals

- The user can trust a server's certificate during server setup, typed or
  discovered, after seeing what they're trusting.
- From then on every network path in both apps (and the Top Shelf) accepts
  that server's certificate, and only that.
- A certificate that changes in a way the trust doesn't cover is never
  silently accepted and never silently fails: the user gets a warning page
  and decides.
- Renewals of a kind-1 certificate pass with no prompt.
- A server configured before this change (no trust stored) whose certificate
  starts failing gets the same trust offer, not the login screen.

## Non-goals

- Trusting any certificate wholesale, or a "turn off certificate checks"
  switch.
- Trust for hosts other than the configured server (redirect targets,
  third-party image hosts).
- Client certificates (mutual TLS).
- Editing or removing the trust outside of "Change Server".
- A "trust this CA" kind for private CAs that renew leaves daily (Caddy's
  `tls internal`, step-ca): pinning their leaf warns about daily, and the
  root usually isn't sent. Such setups are pointed to installing the CA as a
  configuration profile, in the setup copy and the docs; follow-up #499
  (Benjamin, 2026-11-23).

## Anti-goals (would be a failure even if it worked)

- Sign-in and browsing work while playback, images, downloads or the Top
  Shelf fail. Every path honours the trust or the feature isn't done.
- A kind-1 trust that accepts a publicly valid certificate for *some other*
  domain. It is bound to the names the trusted certificate carried.
- A changed self-signed certificate re-trusted without the user seeing it.

## Behaviour (decided with Benjamin)

**What is trusted.**

- **Kind 1, the name case** (the certificate passes every system check
  except the hostname): remember the certificate's DNS names. From then on
  accept, *at this server's address*, any certificate the system finds
  valid for one of those names. Renewals pass silently.
- **Kind 2, the pinned case** (anything else: self-signed, unknown root,
  expired public certificate): pin the exact leaf certificate (its SHA-256).
  Any change, a renewal included, raises the warning.
- **A pinned certificate past its expiry is still accepted**: the user
  vouched for those exact bytes, and self-signed certificates often outlive
  their dates.
- A server whose certificate later becomes publicly valid for the address
  in use keeps working: the system's own answer is always accepted.

**Where it's offered.** Any `https://` server whose certificate fails at
server setup, typed or discovered. Trusting is the first choice; for a
discovered server, today's "Use Unencrypted HTTP" stays as the second and
leads into the existing #429 fallback unchanged.

```
  Can't Verify "SavareseHillFlix"
  This certificate is valid for media.example.com,
  not 192.168.1.50.          ← kind 2: "is self-signed" / "isn't from a
  ─────────────────────────     trusted authority"
  Issued to   media.example.com
  Issued by   Let's Encrypt R11
  Expires     21 Feb 2027
  SHA-256     4F:A2:…:9C
  ─────────────────────────────────
  [ Trust This Certificate ]
  [ Use Unencrypted HTTP ]   (discovered servers only)
  [ Cancel ]
```

**A changed certificate.** A warning page over the app gives the old and
the new fingerprint, with "Trust New Certificate" (behind a confirmation),
"Change Server" and **"Not Now (Stay Offline)"** (Benjamin's wording). In
the name case it appears only when the new certificate isn't publicly valid
for any remembered name.

- **"Not Now (Stay Offline)"** puts the app in its existing offline state
  (what `AppState.start()` already resumes into when
  `ConnectivityMonitor.isOffline`), so Downloads keep working: a captive
  portal or a TLS-inspecting network raises this in ordinary use, and
  neither trusting nor changing server is right there.
- It comes back at the next launch, or when a *different* certificate is
  presented; never once per failed request. The registry reports once per
  presented fingerprint per launch.

**A server with no stored trust whose certificate starts failing** (a
lapsed renewal, a removed CA profile) gets the trust offer from setup
instead of falling to the login screen, with no old fingerprint to show and
the same three answers. This is also how existing installs reach the
feature.

**Afterwards.** Profile's account details (iOS `AccountDetailsSheet`, its
Apple TV counterpart) show a read-only "Certificate" row in the Server
section ("Trusted for media.example.com" / "Trusted (self-signed)").

**Apple TV.** Same flow, as pages, like `TVHTTPPortPage`: the trust page is a
cover with Cancel focused, the changed-certificate warning a full-screen
page. The server configuration is the household's (shared keychain), so a
trust decision covers every Apple TV user, as the server address already
does.

## Approaches considered

**The shape (one sensible way).** One pure trust policy, asked by every
session through one shared delegate method, and by AetherEngine through
`EngineTLS.serverTrustEvaluator`. Rejected:

- *`URLProtocol` interception*: can't answer a TLS challenge, and never
  reaches background sessions.
- *A configuration profile with the user's CA*: today's workaround. It fixes
  a self-signed certificate but never the name case, and needs Settings.

**How to prove it (Benjamin chose option 2).**

1. Certificate fixtures only: unit-test the policy with real certificates
   through `SecTrust`; UI journeys fake the failure. Cheap, but can't catch
   a session that forgot the delegate, the main risk.
2. **Chosen:** fixtures plus a real in-process TLS listener (Network.framework,
   self-signed identity) in the unit tests, so each app session's real
   handshake is checked: accepts the pinned certificate, refuses a changed
   one. Unproven on the Simulator, so it is the plan's first task; if it
   can't be made to run there, fall back to option 1 and say so.

Both get a manual end-to-end run against SavareseHillFlix through a local
TLS proxy (below), which is what covers playback through the engine.

## Design

### The pin

```swift
/// Stored with the server it belongs to.
enum ServerCertificateTrust: Codable, Equatable {
    /// Kind 1: accept a certificate the system finds valid for any of these names.
    case names([String])
    /// Kind 2: accept exactly this leaf certificate (DER), dates ignored.
    case certificate(Data)
}
```

- A new optional field on `ServerConfiguration` (`certificateTrust`), absent
  for every server today, so existing stored configurations decode
  unchanged. It goes wherever the configuration goes: `UserDefaults` on iOS,
  the shared keychain on tvOS. The Top Shelf doesn't read
  `ServerConfiguration`: it reads the `TopShelfSession` mirror in the same
  shared keychain, so the trust rides in that mirror too (an optional field,
  written wherever the mirror is).
- It is public material (a certificate or names, no secret), so integrity
  is what matters, and both stores are the app's own.
- Scope is the configured server's origin (scheme, host, port of
  `baseURL`). Nothing else is ever covered.
- The leaf's DER is kept (not only its hash) so the details can be shown
  again later and in the warning, and the hash is derived.

### The policy

`ServerTrustPolicy` (pure, `Core/Networking/`, in the Top Shelf's slice of
`Core/`): given a challenge's `SecTrust`, its host and port, and the trust
for that origin, answer:

| Situation | Answer |
| --- | --- |
| No trust stored for this origin | system default (`.performDefaultHandling`); a certificate refusal for the configured server's origin is reported (no old certificate), so the offer can show |
| The system accepts the certificate as is | system default |
| `.names`: valid for one of the names (`SecPolicyCreateSSL(true, name)`, wildcard names checked with a synthetic label) | accept (`.useCredential`) |
| `.certificate`: leaf DER equal | accept |
| Otherwise | system default, which refuses it, **and report a changed certificate** |

Refusing is "system default", never "cancel", so a refused certificate
surfaces as the usual `URLError` certificate failure (not `-999 cancelled`,
which reads as a task the app cancelled) and every existing error path
keeps working. The engine's evaluator returns `true` only in the two
"accept" rows; `false` there is AetherEngine's default handling.

**Classifying at setup.** The failed probe's `URLError` carries the peer
trust (`NSURLErrorFailingURLPeerTrustErrorKey`). Re-evaluate a copy with
`SecPolicyCreateSSL(true, nil)` (no hostname): if that passes, it's kind 1,
and the names are the leaf's DNS subject-alternative names that the
certificate verifies for; otherwise kind 2. A kind-1 certificate whose
names can't be read falls back to kind 2.

**Reading the certificate.** iOS has no public API for a certificate's
subject-alternative names or issuer (`SecCertificateCopyValues` is
macOS-only). Use Apple's `swift-certificates` (`X509`, Apache-2.0, with
`swift-asn1`), pinned `exact:` like every package, linked into
`DionysusPlayer` and `DionysusTV` only (the Top Shelf never parses: it
compares names and bytes). It needs `THIRD-PARTY-NOTICES` entries and
`LicenseDocumentTests` updated. (My call over a hand-written DER parser:
less code of ours on a security path.)

### The registry

`ServerTrustRegistry`, a lock-guarded shared object (`Core/Networking/`):

- Holds the trust for the configured server's origin, read per challenge,
  so changing it needs no session rebuilt. `AppState` sets it on start,
  after setup and on Change Server (cleared). Server setup sets a
  *candidate* trust while it re-probes after "Trust This Certificate", so
  the probe and sign-in run under it before anything is saved.
- It must be filled before any session can raise a challenge, including a
  background relaunch for downloads (`AppDelegate`'s
  `handleEventsForBackgroundURLSession` can run before `AppState.start()`),
  so it loads from `ServerSessionStore` at launch, not lazily from
  `AppState`.
- It publishes a changed-certificate event (origin plus the presented
  leaf), main-actor observable, for the warning page.
- It sets `EngineTLS.serverTrustEvaluator` only while a trust is stored, and
  clears it otherwise (my call): with any evaluator set, AetherEngine adds a
  system-trust handshake to every `https` transcode load
  (`prepareRemoteHLSStandIn`), a cost servers with no trust shouldn't pay.

### Every path

| Path | Today | Change |
| --- | --- | --- |
| `JellyfinAPIClient` | `URLSession.shared` default | its own session with the shared delegate (tests that inject a session keep doing so) |
| `RemoteImageLoader` | own session, no delegate | add the delegate |
| `PlayerViewModel` font attachments, ASS script | `URLSession.shared` | the client's session (or one shared app session) |
| Downloads, ad-hoc fetch | own session | add the delegate |
| Downloads, background (iOS) | `DownloadTaskRouter` | the router answers the session-level challenge through the same method |
| Top Shelf | own ephemeral session | add the delegate; registry filled from `TopShelfSession` |
| Top Shelf artwork | already composed by the extension through its own session (`TopShelfArtworkComposer`) and handed to tvOS as App Group file URLs | nothing, once the session has the delegate; but the fallback `setImageURL(art ?? entry.image2x, …)` hands tvOS the server URL when composing fails, which tvOS fetches itself and would refuse: skip the server-URL fallback for a server with a stored trust |
| Playback, direct play and engine fetches | AetherEngine sessions | `EngineTLS.serverTrustEvaluator` |
| Playback, server transcode (AVPlayer) | `nativeRemoteHLS` | the same evaluator: AetherEngine 7.66.0 mounts its `HLSOriginRelay` for an origin the system refuses (docs/api.md, "EngineTLS") |

`URLProtocol`-based UI-test stubbing keeps reaching every session it reaches
today: the delegate changes nothing about which protocol classes a session
uses. Check that the sessions moving off `URLSession.shared` don't move
outside the harness's reach (`UITestHarness`, `TestHostDetection`).

### Setup flow

- `ServerSetupViewModel`: both the typed `connect()` and `connect(to:)`
  catch a certificate failure with a peer trust and publish a
  `CertificateTrustOffer` (server name, address, classified kind, display
  details). Accepting sets the registry's candidate, re-probes, and on
  success returns the configuration with `certificateTrust` set. "Use
  Unencrypted HTTP" (discovered only) enters today's
  `offerInsecureFallback` unchanged.
- iOS shows the offer as a sheet (it needs the detail rows, which an alert
  can't hold); tvOS as a cover page mirrored by `TVServerSetupView` the way
  `httpPortRequest`/`insecureFallbackOffer` are.

### The changed-certificate warning

- Raised by the registry's event, wherever the failing request came from.
  `AppState` holds it; `RootView` / `TVRootView` present the page over
  everything. At launch, a silent sign-in that fails this way shows the
  warning instead of falling to the login screen.
- After setup the warning has two variants, *changed* (old and new
  fingerprints) and *untrusted* (no trust stored yet: the setup offer's
  details), both with the three answers above. "Not Now (Stay Offline)"
  enters the offline state; dismissing at launch resumes offline rather than
  falling to the login screen.
- If the player is up, playback fails with AetherEngine's
  `.sourceCertificateRejected` (given a message of its own in
  `PlayerViewModel`), and the warning shows once the player closes.
- "Trust New Certificate" (confirmed) re-classifies the presented
  certificate (it may now be either kind), saves it and restarts the session
  (`AppState.start()`). "Change Server" is the existing Change Server.

## Testing

- **First task, a spike:** an in-process TLS listener (`NWListener` with a
  self-signed identity from a committed PKCS#12 fixture) inside the iOS unit
  test host, answering a canned Jellyfin response. If it runs on the
  Simulator, keep it; if not, fall back to fixtures only and record why.
- **Unit tests (both test targets):** the policy's table, row by row, with
  committed fixtures: a self-signed certificate, a second one standing for a
  "changed" certificate, and a captured publicly-valid chain evaluated with
  `SecTrustSetVerifyDate` inside its validity (name match, name mismatch,
  wildcard). Classification at setup, SAN reading, `ServerConfiguration`
  decoding with and without the field, the registry's candidate and event.
- **Integration (option 2):** each session in the table that a unit test can
  build (`JellyfinAPIClient`'s, `RemoteImageLoader`'s, the player fetch's,
  the downloads' ad-hoc one, the Top Shelf's) against the listener: accepts
  under the matching trust, refuses with a certificate error and reports
  under a changed one, refuses with no trust. The background session and the
  engine can't be driven from a unit test; the background router is covered
  by a test that its challenge method is the shared one, the engine by the
  manual run.
- **UI journeys, both apps** (new stub scenarios; the stub fails requests
  with a certificate `URLError` carrying a fixture peer trust until a trust
  is stored):
  - self-signed at setup: the offer shows the details, Trust signs in;
  - name mismatch at setup: the offer names the domain;
  - discovered server: "Use Unencrypted HTTP" still reaches the #429 flow;
  - changed certificate at launch: the warning, then each of Trust New
    Certificate, Change Server and Not Now (Stay Offline), the last leaving
    Downloads reachable;
  - no stored trust, certificate now failing: the offer instead of the
    login screen;
  - Profile shows the Certificate row.
  Accessibility audits cover the new pages.
- **Manual, Simulator:** SavareseHillFlix behind a local TLS proxy on
  another port (self-signed certificate; **the server's own configuration
  is not touched**): set up, browse, images, direct play, a forced
  transcode (`mode=transcode` link), a download, the Top Shelf; then swap
  the proxy's certificate and see the warning. The name case with a private
  CA added to the Simulator (`xcrun simctl keychain booted add-root-cert`)
  and a certificate for a made-up name, reached by IP.

## Docs in the same change

- Root `CLAUDE.md`, Networking: the trust model, the registry, "every new
  session takes the shared delegate".
- `DionysusTV/CLAUDE.md`: the line that says "Trusting the certificate itself
  instead is #466", plus the pages.
- `PRIVACY.md`: a line that a trusted server's certificate (or its names) is
  stored with the server's address. Privacy manifests: no new required-reason
  API expected; check.
- `TESTING.md`: the new scenarios and the TLS listener.
- `THIRD-PARTY-NOTICES`: `swift-certificates`, `swift-asn1`.
- `Localizable.xcstrings` synced in the same PR.

## Left to the builder

- Names and file layout of the new types, the sheet's and pages' exact copy
  and layout within the sketch above, and how the fingerprint is shortened
  on screen (full value for VoiceOver).
- How the UI-test stub fakes a certificate failure and a stored trust.
- Which TLS proxy runs the manual check.
- Whether the player's two fetches share `JellyfinAPIClient`'s session or one
  app-wide session.

## Risks

- **The in-process listener may not run in the Simulator test host**
  (identity import, local network). The spike decides early.
- **AetherEngine's relay is new territory for this app.** Only the manual
  run proves direct play and transcodes behind a self-signed certificate.
