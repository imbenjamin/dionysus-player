# Trusting a Server's Unverifiable Certificate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user trust a Jellyfin server's unverifiable HTTPS certificate (a real certificate reached at the wrong name, or a self-signed one) on iPhone/iPad and Apple TV, honoured by every network path, with a warning when it changes.

**Architecture:** A stored `ServerCertificateTrust` travels with `ServerConfiguration` (and the Top Shelf's `TopShelfSession` mirror). A pure `ServerTrustPolicy` decides each TLS challenge; a lock-guarded `ServerTrustRegistry` holds the current server's trust, reports refusals, and feeds one `ServerTrustDelegate` used by every app session and, through `EngineTLS.serverTrustEvaluator`, by AetherEngine. Setup offers the trust; `AppState` raises a warning when a trusted (or untrusted) server's certificate is refused later.

**Tech Stack:** Swift 6, SwiftUI, Security.framework (`SecTrust`, `SecPolicyCreateSSL`), CryptoKit (SHA-256), Security (`SecCertificateCopySubjectSummary`, `SecCertificateCopyNotValidAfterDate`) and Apple's `swift-asn1` for reading names and issuer, Network.framework (`NWListener`) in tests, AetherEngine 7.66.0 `EngineTLS`.

**Spec:** `docs/superpowers/specs/2026-11-23-server-certificate-trust-design.md`

## Global Constraints

- iOS floor 18.0, tvOS floor 26.0; the Top Shelf extension stays UI-free and compiles `Core/Networking` (less its listed excludes), `Core/Models` and `Core/Persistence/TopShelfSession.swift`: nothing there may import `SwiftASN1`, `AetherEngine`, SwiftUI or UIKit.
- Packages are pinned `exact:` in `project.yml`; regenerate with `xcodegen generate` whenever `project.yml` or the file set changes.
- Shared code naming a Downloads type sits inside `#if DOWNLOADS`.
- Never select on an accessibility label in UI tests; identifiers go in `A11yID`; no identifier on a screen-root container.
- Every toolbar button has a symbol and a title (`.toolbarTitleUnlessVertical()`).
- User-facing strings: plain literals in SwiftUI views, `String(localized:)` elsewhere; sync `Localizable.xcstrings` in the same PR via an Xcode.app build.
- Decorative `Image(systemName:)` gets `.accessibilityHidden(true)`.
- Copy fixed by the spec: "Trust This Certificate", "Use Unencrypted HTTP", "Cancel", "Trust New Certificate", "Change Server", **"Not Now (Stay Offline)"**; Profile row "Certificate" with "Trusted for <name>" / "Trusted (self-signed)".
- A pinned certificate is accepted after it expires; a name trust is bound to the names the trusted certificate carried, at the configured server's origin only.
- Refusal is always `.performDefaultHandling` (a normal certificate `URLError`), never `.cancelAuthenticationChallenge`.
- `EngineTLS.serverTrustEvaluator` is set only while a trust is stored, `nil` otherwise.
- A refusal is reported once per presented certificate fingerprint per launch.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and never carry a session URL. **Ask Benjamin before each commit** (his standing rule); the commit steps below are where to ask.

## Review Focus

1. **Port normalisation:** a server configured as `https://host` (no port) and a challenge reporting port 443 are the same origin; `https://host:8920` and port 443 are not. Tested in Task 3.
2. **Another origin, same host:** a stored trust for `192.168.1.50:8920` must not accept a self-signed certificate at `192.168.1.50:443`, nor at another host a redirect lands on. Tested in Task 3.
3. **Home's fan-out:** ten requests refused at once raise one warning, not ten; a second, different certificate raises it again. Tested in Task 4.
4. **Background relaunch:** a download's background session can raise a challenge before `AppState.start()`; the registry must already hold the stored trust. Tested in Task 4.
5. **Host spelling:** `MEDIA.lan` in the configuration and `media.lan` in the challenge (and an IPv6 literal with brackets) are the same host. Tested in Task 3.

---

### Task 1: Spike: a real TLS listener in the unit-test host, and TLS fixtures

Decides option 2 of the spec. If the listener can't run on the iOS Simulator test host, stop, record why in the spec's Risks section, and continue the remaining tasks with fixture-only tests (skip every "integration" step).

**Files:**
- Create: `Scripts/generate-tls-fixtures.sh`
- Create: `DionysusPlayerTests/Fixtures/TLS/` (`selfSignedA.der`, `selfSignedA.p12`, `selfSignedB.der`, `selfSignedB.p12`, `testCA.der`, `nameLeaf.der` and `nameLeaf.p12` for `media.dionysus.test` and `*.wild.dionysus.test`, `nameLeafOther.der` for `other.dionysus.test`, all issued by `testCA`, `README.md`)
- Create: `DionysusPlayerTests/Support/TLSTestServer.swift`
- Create: `DionysusPlayerTests/Support/TLSFixtures.swift`
- Test: `DionysusPlayerTests/Support/TLSTestServerTests.swift`

**Interfaces:**
- Produces:
  - `enum TLSFixtures { static func certificate(_ name: String) -> SecCertificate; static func der(_ name: String) -> Data; static func identity(_ name: String) -> SecIdentity; static func trust(leaf: String, anchors: [String], host: String?) -> SecTrust }` (`trust` evaluates nothing; `anchors` set with `SecTrustSetAnchorCertificatesOnly`).
  - `final class TLSTestServer { init(identity: String) async throws; var port: UInt16 { get }; var baseURL: URL { get } /* https://127.0.0.1:<port> */; func replaceIdentity(_ name: String); func stop() }` answering every request `200` with body `{"ServerName":"TLS Test","Version":"10.11.0","Id":"tls-test"}` and `Content-Type: application/json`.

- [ ] **Step 1: Write `Scripts/generate-tls-fixtures.sh`** with Homebrew `openssl` (4.x): two RSA-2048 self-signed certificates (CN `selfsigned-a.dionysus.test`, `selfsigned-b.dionysus.test`, 20-year validity from 2026-11-01), a test CA, and two CA-issued leaves with DNS SANs (`media.dionysus.test` + `*.wild.dionysus.test`; `other.dionysus.test`). Export DER and a PKCS#12 (password `dionysus`, `-legacy`-free AES so `SecPKCS12Import` accepts it). The README records the command and that these are test-only keys.
- [ ] **Step 2: Run it** and check: `openssl x509 -in DionysusPlayerTests/Fixtures/TLS/nameLeaf.der -inform der -noout -ext subjectAltName` prints both names.
- [ ] **Step 3: Write the failing test** `TLSTestServerTests.testURLSessionWithPerTaskDelegateReceivesTheServerTrustChallenge`: start `TLSTestServer(identity: "selfSignedA")`, call `URLSession.shared.data(for: URLRequest(url: server.baseURL), delegate: spy)` where `spy` accepts any server trust; assert status `200` and `spy.challengeHosts == ["127.0.0.1"]`. Second test `testWithoutADelegateTheHandshakeIsRefused`: plain `URLSession.shared.data(from:)` throws a `URLError` whose code is one of `.serverCertificateUntrusted`, `.serverCertificateHasUnknownRoot`, `.secureConnectionFailed`, and whose `userInfo[NSURLErrorFailingURLPeerTrustErrorKey]` is a `SecTrust`.
- [ ] **Step 4: Run and see them fail** (types missing): `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DionysusPlayerTests/TLSTestServerTests`
- [ ] **Step 5: Implement `TLSFixtures` and `TLSTestServer`** (`NWListener` with `NWProtocolTLS.Options` and `sec_identity_create`, bound to loopback, a minimal HTTP/1.1 response writer; `replaceIdentity` restarts the listener on the same port). Run `xcodegen generate` first so the fixtures land in the test bundle's resources.
- [ ] **Step 6: Run the tests** and make sure they pass on the iOS Simulator, then on tvOS: `xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV -testPlan TVUnitTests -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)' -only-testing:DionysusTVTests/TLSTestServerTests`. The per-task delegate result decides Task 5's approach for `URLSession.shared`; if it fails, say so before continuing.
- [ ] **Step 7: Ask, then commit** `Add a TLS test listener and certificate fixtures (#466)`.

### Task 2: The trust model on the configuration and the Top Shelf mirror

**Files:**
- Create: `DionysusPlayer/Core/Models/ServerCertificateTrust.swift`
- Modify: `DionysusPlayer/Core/Models/ServerConfiguration.swift`
- Modify: `DionysusPlayer/Core/Persistence/TopShelfSession.swift` (`make(server:…)` copies the trust)
- Test: `DionysusPlayerTests/Core/Models/ServerConfigurationTests.swift`, `DionysusTVTests/TopShelfSessionTests.swift`

**Interfaces:**
- Produces:
  - `enum ServerCertificateTrust: Codable, Equatable, Sendable { case names([String]); case certificate(Data) }` with `var fingerprint: Data? { get }` (SHA-256 of the DER, `nil` for `.names`) and `static func fingerprintText(_ sha256: Data) -> String` (uppercase hex pairs joined by `:`).
  - `ServerConfiguration.certificateTrust: ServerCertificateTrust?` (default `nil`) and `ServerConfiguration.origin: ServerOrigin`.
  - `struct ServerOrigin: Hashable, Sendable { let host: String; let port: Int; init?(url: URL); init(host: String, port: Int) }`: host lowercased with IPv6 brackets removed; port from the URL or 443/80 by scheme.
  - `TopShelfSession.certificateTrust: ServerCertificateTrust?`.

- [ ] **Step 1: Write the failing tests**: `testDecodesAConfigurationSavedBeforeCertificateTrust` (JSON `{"name":"S","baseURL":"https://h:8920"}` decodes with `certificateTrust == nil`); `testRoundTripsBothTrustKinds`; `testFingerprintTextIsColonSeparatedUppercaseHex` (`Data([0x4f, 0xa2, 0x0c])` → `"4F:A2:0C"`); `testOriginDefaultsTheSchemePort` (`https://h` → port 443, `http://h` → 80); `testOriginLowercasesAndUnbracketsTheHost` (`https://MEDIA.lan:8920` → `media.lan`; `https://[fe80::1]:8920` → `fe80::1`); `TopShelfSessionTests.testMakeCopiesTheServersCertificateTrust`; `testDecodesAMirrorSavedBeforeCertificateTrust`.
- [ ] **Step 2: Run to see them fail** (`-only-testing:DionysusPlayerTests/ServerConfigurationTests`, and the TV scheme for `TopShelfSessionTests`).
- [ ] **Step 3: Implement** the three types and fields (`decodeIfPresent` for both new optionals).
- [ ] **Step 4: Run the tests** and make sure they pass on both schemes.
- [ ] **Step 5: Ask, then commit** `Store a server's certificate trust with its configuration (#466)`.

### Task 3: `ServerTrustPolicy`

**Files:**
- Create: `DionysusPlayer/Core/Networking/ServerTrustPolicy.swift`
- Test: `DionysusPlayerTests/Core/Networking/ServerTrustPolicyTests.swift`

**Interfaces:**
- Consumes: `ServerCertificateTrust`, `ServerOrigin` (Task 2); `TLSFixtures` (Task 1).
- Produces:
  - `enum ServerTrustDecision: Equatable { case systemDefault; case accept; case refuse(presentedLeaf: Data) }` (`.refuse` is answered with `.performDefaultHandling` by callers, plus a report).
  - `enum ServerTrustPolicy { static func decide(trust: SecTrust, origin: ServerOrigin, serverOrigin: ServerOrigin?, stored: ServerCertificateTrust?) -> ServerTrustDecision }`.
  - `static func systemAccepts(_ trust: SecTrust, host: String?) -> Bool` (copies the trust, sets `SecPolicyCreateSSL(true, host)`, `SecTrustEvaluateWithError`).
  - `static func leafDER(_ trust: SecTrust) -> Data?` (`SecTrustCopyCertificateChain` first element).
  - `static func probeHost(for name: String) -> String`: a leading `*.` becomes `dionysus-check.` (a wildcard name can't be passed to `SecPolicyCreateSSL`); any other name is returned as is.

The decision table, in order:

| Condition | Result |
| --- | --- |
| `origin != serverOrigin` | `.systemDefault` |
| `systemAccepts(trust, host: origin.host)` | `.systemDefault` |
| `stored == .names(ns)` and some `n` in `ns` passes `systemAccepts(trust, host: probeHost(for: n))` | `.accept` |
| `stored == .certificate(d)` and `leafDER(trust) == d` | `.accept` |
| otherwise | `.refuse(presentedLeaf:)` (also when `stored == nil`: Task 9's "untrusted" warning) |

- [ ] **Step 1: Write the failing tests**, one per row and Review Focus item. Name-trust tests build trusts with `TLSFixtures.trust(leaf: "nameLeaf", anchors: ["testCA"], host: "192.168.1.50")`.
  - `testAnotherOriginIsLeftToTheSystem`: server `192.168.1.50:8920`, challenge `192.168.1.50:443`, stored `.certificate(der("selfSignedA"))` → `.systemDefault`.
  - `testSchemeDefaultPortMatchesAnExplicit443` (server `https://h`, challenge port 443, pinned A, presented A) → `.accept`.
  - `testHostCaseDoesNotMatter` → `.accept`.
  - `testPinnedCertificateMatchIsAccepted` → `.accept`.
  - `testPinnedCertificateIsAcceptedAfterItExpires`: `SecTrustSetVerifyDate` to 2060-01-01 → `.accept`.
  - `testChangedPinnedCertificateIsRefused`: pinned A, presented B → `.refuse(presentedLeaf: der("selfSignedB"))`.
  - `testNameTrustAcceptsARenewedCertificateForTheSameName`: stored `.names(["media.dionysus.test"])`, presented `nameLeaf` → `.accept`.
  - `testNameTrustAcceptsAWildcardName`: stored `.names(["*.wild.dionysus.test"])` → `.accept`.
  - `testNameTrustRefusesAValidCertificateForAnotherName`: stored `.names(["media.dionysus.test"])`, presented `nameLeafOther` → `.refuse`.
  - `testNoStoredTrustRefusesAndReports`: stored `nil`, presented A → `.refuse(presentedLeaf: der("selfSignedA"))`.
  - `testASystemTrustedCertificateIsLeftToTheSystem`: anchors include the leaf's CA and host `media.dionysus.test` → `.systemDefault`.
- [ ] **Step 2: Run to see them fail** (`-only-testing:DionysusPlayerTests/ServerTrustPolicyTests`).
- [ ] **Step 3: Implement** the table above. Security and Foundation only (the Top Shelf compiles this file).
- [ ] **Step 4: Run the tests** and make sure they pass, on both schemes.
- [ ] **Step 5: Ask, then commit** `Add the server trust policy (#466)`.

### Task 4: `ServerTrustRegistry`, the shared delegate and the engine bridge

**Files:**
- Create: `DionysusPlayer/Core/Networking/ServerTrustRegistry.swift`
- Create: `DionysusPlayer/Core/Networking/ServerTrustDelegate.swift`
- Create: `DionysusPlayer/Core/Playback/ServerTrustEngineBridge.swift` (imports AetherEngine; not in the Top Shelf)
- Modify: `DionysusPlayer/App/AppDelegate.swift` (`didFinishLaunching` loads the registry before anything else); `DionysusTV/DionysusTVApp.swift` (the same at its init)
- Test: `DionysusPlayerTests/Core/Networking/ServerTrustRegistryTests.swift`

**Interfaces:**
- Consumes: Task 2, Task 3.
- Produces:
  - `final class ServerTrustRegistry: @unchecked Sendable` with `static let shared`; `init()` (tests make their own);
    `func configure(server: ServerConfiguration?)` (sets the origin and trust, and calls the bridge hook);
    `func setCandidate(_ trust: ServerCertificateTrust?, for origin: ServerOrigin)` (setup's pending trust; a candidate overrides the configured server's for its origin);
    `func decide(_ trust: SecTrust, host: String, port: Int) -> ServerTrustDecision` (runs the policy; on `.refuse` records a `ServerTrustRefusal` once per presented fingerprint per launch);
    `var onRefusal: (@Sendable (ServerTrustRefusal) -> Void)?` (called once per new fingerprint, off the main actor);
    `var hasStoredTrust: Bool { get }`;
    `func loadFromStore(_ store: ServerSessionStore)` (launch).
  - `struct ServerTrustRefusal: Equatable, Sendable { let origin: ServerOrigin; let presentedLeaf: Data; let previous: ServerCertificateTrust? }`.
  - `final class ServerTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable` with `static let shared`, `init(registry: ServerTrustRegistry = .shared)`, implementing both the session-level and the task-level `didReceive challenge` through `static func handle(_ challenge: URLAuthenticationChallenge, registry: ServerTrustRegistry) -> (URLSession.AuthChallengeDisposition, URLCredential?)`: `.accept` → `.useCredential` with `URLCredential(trust:)`; anything else (and non-server-trust challenges) → `.performDefaultHandling, nil`.
  - `enum ServerTrustEngineBridge { static func apply(registry: ServerTrustRegistry) }`: sets `EngineTLS.serverTrustEvaluator` to `{ space in space.serverTrust.map { registry.decide($0, host: space.host, port: space.port) == .accept } ?? false }` while `registry.hasStoredTrust`, else `nil`. The registry calls a hook `static var didChange: (@Sendable (ServerTrustRegistry) -> Void)?`, which the app sets to the bridge (keeps AetherEngine out of `Core/Networking`).

- [ ] **Step 1: Write the failing tests**:
  - `testRefusalIsReportedOncePerFingerprint`: ten `decide` calls with B against pinned A → `onRefusal` called once; then one with a third certificate (`nameLeafOther`) → called a second time.
  - `testCandidateIsUsedForItsOriginBeforeAnythingIsSaved`.
  - `testLoadFromStoreFillsTheTrustBeforeAppStateStarts`: a `ServerSessionStore` (test suite name) saved with a pinned configuration → `registry.loadFromStore(store)` → `decide` with A answers `.accept`.
  - `testBridgeSetsTheEngineEvaluatorOnlyWhileATrustIsStored`: configure with trust → `EngineTLS.serverTrustEvaluator != nil`; configure with `nil` trust → `nil`.
  - Integration (option 2): `testDelegateAcceptsThePinnedListenerAndRefusesAChangedOne`: `TLSTestServer(identity: "selfSignedA")`, registry configured with the server at `server.baseURL` and `.certificate(der("selfSignedA"))`, `URLSession.shared.data(for:delegate: ServerTrustDelegate(registry:))` → 200; `server.replaceIdentity("selfSignedB")` → throws a certificate `URLError` and `onRefusal` fired with B.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement** the registry (one `NSLock`), the delegate and the bridge; call `ServerTrustRegistry.shared.loadFromStore(_:)` and set `didChange` in `AppDelegate.application(_:didFinishLaunchingWithOptions:)` and in `DionysusTVApp.init()`.
- [ ] **Step 4: Run the tests** and make sure they pass on both schemes.
- [ ] **Step 5: Ask, then commit** `Add the server trust registry and delegate (#466)`.

### Task 5: Every app session asks the registry

**Files:**
- Modify: `DionysusPlayer/Core/Networking/JellyfinAPIClient.swift:1221` (and every other `session.data`/`session.bytes` call in the file)
- Modify: `DionysusPlayer/Core/Networking/RemoteImageLoader.swift:74`
- Modify: `DionysusPlayer/Features/Player/PlayerViewModel.swift:1439,1593`
- Modify: `DionysusPlayer/Core/Downloads/DownloadManager.swift:138-145`, `DionysusPlayer/Core/Downloads/DownloadTaskRouter.swift`
- Test: `DionysusPlayerTests/Core/Networking/ServerTrustSessionCoverageTests.swift`

**Interfaces:**
- Consumes: `ServerTrustDelegate.shared` (Task 4).

Decision (deviates from the spec's "moves off `URLSession.shared`", with the same effect): calls on `URLSession.shared` keep it and pass `delegate: ServerTrustDelegate.shared` per task, because the unit tests' `MockURLProtocol` reaches only `.shared`. Task 1's spike proves a per-task delegate receives the server-trust challenge. Owned sessions (`RemoteImageLoader`, the downloads' ad-hoc one) get `delegate: ServerTrustDelegate.shared` at construction. The background session's delegate is `DownloadTaskRouter`, which adds the session-level challenge method and answers it with `ServerTrustDelegate.handle(_:registry:)` (`#if DOWNLOADS` as the file already is).

- [ ] **Step 1: Write the failing integration tests**, each against `TLSTestServer(identity: "selfSignedA")` with `ServerTrustRegistry.shared` configured for it (reset in `tearDown`):
  - `testAPIClientReachesAPinnedServer`: `JellyfinAPIClient(baseURL: server.baseURL).publicSystemInfo().serverName == "TLS Test"`.
  - `testAPIClientRefusesAChangedCertificate`: pinned B → throws a certificate `URLError`.
  - `testImageLoaderUsesTheTrustDelegate`: `RemoteImageLoader()`'s session `delegate is ServerTrustDelegate` (an image fixture over TLS isn't needed).
  - `testPlayerFetchesPassTheTrustDelegate`: a font-attachment fetch through `PlayerViewModel`'s internal fetch helper against the listener returns data (expose the helper `static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse)` used by both call sites).
  - `testDownloadAdHocSessionUsesTheTrustDelegate`, `testDownloadRouterAnswersServerTrustThroughTheSharedHandler` (call the router's challenge method with a challenge built from a `URLProtectionSpace` the listener's trust can't supply; assert it calls `ServerTrustDelegate.handle` via a spy registry).
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement** the changes above.
- [ ] **Step 4: Run the whole unit plan** on both schemes (`UnitTests`, `TVUnitTests`) and make sure everything passes: this is where a session slipping out of `MockURLProtocol` or `UITestHarness.decorate` would show.
- [ ] **Step 5: Ask, then commit** `Route every app session through the server trust delegate (#466)`.

### Task 6: The Top Shelf

**Files:**
- Modify: `DionysusTV/TopShelf/TopShelfLoader.swift:55-60` (`makeSession(registry:)` with the delegate)
- Modify: `DionysusTV/TopShelf/TopShelfCarousel.swift:40` (no server-URL fallback while a trust is stored)
- Modify: `DionysusTVTopShelf/ContentProvider.swift` (configure a registry from the `TopShelfSession` before loading)
- Test: `DionysusTVTests/TopShelfCarouselTests.swift`, `DionysusTVTests/TopShelfLoaderTests.swift`

**Interfaces:**
- Consumes: `TopShelfSession.certificateTrust` (Task 2), `ServerTrustRegistry`/`ServerTrustDelegate` (Task 4).
- Produces: `ServerTrustRegistry.configure(serverURL: URL, trust: ServerCertificateTrust?)` overload for the extension.

- [ ] **Step 1: Write the failing tests**: `TopShelfLoaderTests.testSessionUsesTheTrustDelegate`; `TopShelfCarouselTests.testATrustedServerGetsNoServerImageURLWhenArtIsMissing` (session with `.certificate(…)`, no composed art → `item.imageURL(for: .screenScale2x) == nil`); `testAnUntrustedServerKeepsTheBackdropFallback` (unchanged behaviour); integration `testLoaderReachesAPinnedListener` with `TLSTestServer`.
- [ ] **Step 2: Run to see them fail** (`-scheme DionysusTV -testPlan TVUnitTests`).
- [ ] **Step 3: Implement**; write the trust into the mirror wherever `TopShelfRefresh` writes it (it already goes through `TopShelfSession.make`, Task 2).
- [ ] **Step 4: Run the tests** and make sure they pass, and build the `DionysusTVTopShelf` target alone to prove it still compiles without SwiftASN1 or AetherEngine.
- [ ] **Step 5: Ask, then commit** `Trust the server's certificate in the Top Shelf (#466)`.

### Task 7: Classifying a refused certificate and offering trust at setup

**Files:**
- Modify: `project.yml` (`packages:` add `SwiftASN1`, url `https://github.com/apple/swift-asn1`, `version:` the newest 1.x release at the time, linked to `DionysusPlayer` and `DionysusTV` only). Not swift-certificates: its `X509` pulls in swift-crypto's `_CryptoExtras`, which links BoringSSL on Apple platforms too. Security reads the subject, issuer, expiry and self-signed check; swift-asn1 only the SAN DNS names.
- Create: `DionysusPlayer/Core/Security/ServerCertificateDetails.swift`
- Modify: `DionysusPlayer/Features/ServerSetup/ServerSetupViewModel.swift` (`connect(to:)` at 187, `testConnection()` at 332, `probe` at 401)
- Modify: `THIRD-PARTY-NOTICES` (`# swift-asn1`), `DionysusPlayerTests/Core/Models/LicenseDocumentTests.swift`
- Test: `DionysusPlayerTests/Core/Security/ServerCertificateDetailsTests.swift`, `DionysusPlayerTests/Features/ServerSetup/ServerSetupViewModelTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces:
  - `struct ServerCertificateDetails: Equatable, Sendable { let leaf: Data; let subject: String; let issuer: String?; let notAfter: Date?; let dnsNames: [String]; let fingerprint: Data; let kind: Kind; enum Kind: Equatable { case nameMismatch(validFor: [String]); case selfSigned; case untrustedIssuer }; var trust: ServerCertificateTrust { get } /* .names(validFor) or .certificate(leaf) */; init?(trust: SecTrust) }`. `nameMismatch` when `ServerTrustPolicy.systemAccepts(trust, host: nil)` and at least one DNS name passes `systemAccepts(trust, host: ServerTrustPolicy.probeHost(for: name))`; `selfSigned` when the chain is one certificate whose issuer equals its subject; else `untrustedIssuer`. `validFor` is the passing names. `issuer` is the second chain element's subject summary, else `nil`.
  - On `ServerSetupViewModel`: `struct CertificateTrustOffer: Equatable { let serverName: String; let configuration: ServerConfiguration; let details: ServerCertificateDetails; let offersHTTP: Bool }`, `private(set) var certificateTrustOffer: CertificateTrustOffer?`, `func trustOfferedCertificate() async -> ServerConfiguration?` (sets the registry candidate, re-probes, returns the configuration with `certificateTrust`; on failure clears the candidate and sets `errorMessage`), `func declineCertificateTrust()`, `func useUnencryptedHTTPInstead() async` (enters today's `offerInsecureFallback(for:port:)` unchanged).
  - `probe` and `lookUpVersion` pass the registry's delegate (Task 5's per-task approach applies, since they build `JellyfinAPIClient`s).

- [ ] **Step 1: Write the failing tests**:
  - Details: `testNameMismatchListsTheNamesItIsValidFor` (`nameLeaf` with `testCA` anchored, host `192.168.1.50` → `.nameMismatch(validFor: ["media.dionysus.test", "*.wild.dionysus.test"])`, `trust == .names([...])`); `testSelfSignedIsPinned` (A → `.selfSigned`, `trust == .certificate(der("selfSignedA"))`, `subject == "selfsigned-a.dionysus.test"`); `testUnknownIssuerIsPinned` (`nameLeaf` with no anchors → `.untrustedIssuer`); `testFingerprintIsTheLeafsSHA256`.
  - View model (inject the probe as today's tests do, failing with a `URLError(.serverCertificateHasUnknownRoot, userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: trust])`):
    `testTypedHTTPSAddressWithAnUnverifiableCertificateOffersTrust` (`offersHTTP == false`);
    `testDiscoveredHTTPSServerOffersTrustBeforeHTTP` (`offersHTTP == true`, `insecureFallbackOffer == nil` until `useUnencryptedHTTPInstead()`);
    `testTrustingReprobesUnderTheCandidateAndReturnsTheTrust` (second probe succeeds → returned `certificateTrust == .certificate(der("selfSignedA"))`);
    `testTrustingThatStillFailsClearsTheCandidateAndExplains`;
    `testACertificateErrorWithoutAPeerTrustKeepsTodaysFlow` (the old discovered behaviour).
  - `LicenseDocumentTests` expects the two new `# ` sections.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Add the package** (`xcodegen generate`; a cold resolve in fresh DerivedData if "declares no traits" appears), read its licence, add the notices, then implement.
- [ ] **Step 4: Run the tests** and make sure they pass on both schemes.
- [ ] **Step 5: Ask, then commit** `Offer to trust an unverifiable server certificate at setup (#466)`.

### Task 8: The trust offer's UI, iOS and Apple TV, with journeys

**Files:**
- Create: `DionysusPlayer/Features/ServerSetup/CertificateTrustSheet.swift`
- Create: `DionysusPlayer/Shared/Components/CertificateDetailsRows.swift` (the four rows, shared by the sheet, the warning and Profile; on tvOS a focusable section per `DionysusTV/CLAUDE.md`'s Full Details rule)
- Create: `DionysusTV/Onboarding/TVCertificateTrustPage.swift`
- Modify: `DionysusPlayer/Features/ServerSetup/ServerSetupView.swift`, `DionysusTV/Onboarding/TVServerSetupView.swift` (one more case in the cover it already mirrors), `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift`
- Modify: `DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift:49-55`, `UITestFixtureIdentity.swift`, `UITestConfiguration.swift` (scenarios), plus a bundled copy of the fixture DERs for the app's DEBUG harness (`DionysusPlayer/Core/UITestSupport/Fixtures/`, excluded from Release)
- Test: `DionysusPlayerUITests/Journeys/AuthJourneyTests.swift` (update the three fallback journeys, add new), `DionysusPlayerUITests/Screens/Screens.swift`, `DionysusTVUITests/OnboardingJourneyTests.swift`, both `AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: `ServerSetupViewModel.certificateTrustOffer` and its three actions (Task 7).
- Produces: `A11yID.ServerSetup.certificateTrust{Sheet,TrustButton,HTTPButton,CancelButton,Fingerprint}` and `A11yID.TV.Onboarding.certificateTrust…` equivalents; UI-test scenarios `.selfSignedCertificate`, `.nameMismatchCertificate`.

The stub: an `https://` request fails with the certificate `URLError` **carrying a peer trust** built from `selfSignedA` (scenario `.nameMismatchCertificate`: `nameLeaf` with `testCA` anchored), unless `ServerTrustRegistry.shared` has a trust or candidate for that origin, in which case it serves the fixture as it serves `http://` today. Copy per the spec's sketch: title `Can't Verify "<server>"`; the reason line ("This certificate is valid for <names>, not <host>." / "This certificate is self-signed." / "This certificate isn't from a trusted authority."); for kind 2 a line pointing to a configuration profile for private CAs that renew often (#499).

- [ ] **Step 1: Write the failing journeys** (iOS): `testTrustingASelfSignedCertificateReachesLogin` (details show the fingerprint row; Trust → login screen); `testNameMismatchOfferNamesTheDomain` (`nameMismatchCertificate`: the reason row's identifier has the name in its value); `testDiscoveredServerStillOffersUnencryptedHTTP` (Use Unencrypted HTTP → today's confirmation → login); `testCancellingTheTrustOfferStaysOnServerSetup`. Update `testAcceptingTheHTTPFallbackForAnUnverifiableServerReachesLogin`, `testHTTPFallbackAsksForTheHTTPPortWhenTheDefaultIsSilent` and `testCancellingTheHTTPFallbackStaysOnServerSetup` to pass through the offer's HTTP button first. tvOS: the same four in `OnboardingJourneyTests` (Cancel focused on arrival). Audit: the sheet and the page.
- [ ] **Step 2: Run to see them fail**: `xcodebuild test … -scheme DionysusPlayer -testPlan UITests-Full -only-testing:DionysusPlayerUITests/AuthJourneyTests`, and `-scheme DionysusTV -testPlan TVUITests -only-testing:DionysusTVUITests/OnboardingJourneyTests`.
- [ ] **Step 3: Implement** the stub change, the sheet, the page and the wiring.
- [ ] **Step 4: Screenshot the sheet (iPhone 17) and the page (Apple TV), send both to Benjamin and wait for his OK** before running the suites (his rule for visual changes).
- [ ] **Step 5: Run the journeys and the audits** on both platforms and make sure they pass.
- [ ] **Step 6: Ask, then commit** `Show the certificate trust offer on iOS and the Apple TV (#466)`.

### Task 9: `AppState`: launch, refusals, the three answers, and playback's message

**Files:**
- Modify: `DionysusPlayer/App/AppState.swift` (`start()` at 63, `completeServerSetup` at 155, `changeServer` at 296)
- Modify: `DionysusPlayer/Core/Playback/AetherPlaybackEngine.swift:716` and `PlayerViewModel`'s failure copy
- Test: `DionysusPlayerTests/App/AppStateTests.swift`, the player's existing failure-mapping tests

**Interfaces:**
- Consumes: Tasks 2, 4, 7 (`ServerCertificateDetails(trust:)`).
- Produces:
  - `struct CertificateWarning: Equatable, Identifiable { enum Kind: Equatable { case changed(previous: ServerCertificateTrust); case untrusted }; let kind: Kind; let details: ServerCertificateDetails; var id: Data { details.fingerprint } }`.
  - On `AppState`: `private(set) var certificateWarning: CertificateWarning?`; `func trustPresentedCertificate() async` (saves `details.trust` into the configuration, reconfigures the registry, clears the warning, `await start()`); `func stayOfflineForNow()` (clears the warning; if signed-in credentials exist, enters `.main` the way the offline resume does and marks `ConnectivityMonitor` offline; otherwise stays on `.login`); `changeServer()` also clears the warning and the registry.
  - `AppState.init` sets `ServerTrustRegistry.shared.onRefusal` to hop to the main actor and set `certificateWarning` (the refusal for the configured origin only, when no warning is up).
  - `PlaybackFailure.Category` mapping: `.sourceCertificateRejected` → a non-retryable category with "This server's security certificate has changed." (a new case if none fits).

- [ ] **Step 1: Write the failing tests** (`AppStateTests`, with an injected registry and probe client as the file's tests already inject):
  - `testRefusalOfATrustedServerRaisesTheChangedWarning`.
  - `testRefusalOfAServerWithNoTrustRaisesTheUntrustedWarning`.
  - `testARefusalAtLaunchShowsTheWarningInsteadOfLogin`: silent sign-in fails with a certificate error and a refusal → `phase != .login`, `certificateWarning != nil`.
  - `testTrustingThePresentedCertificateSavesItAndRestarts`: stored configuration's `certificateTrust == .certificate(der("selfSignedB"))`, `phase == .main`.
  - `testStayOfflineForNowResumesOfflineWithDownloads`: `phase == .main`, `ConnectivityMonitor.shared.isOffline`, warning nil.
  - `testTheSameCertificateDoesNotRaiseTheWarningAgainAfterNotNow`, `testADifferentCertificateRaisesItAgain`.
  - `testChangeServerClearsTheWarningAndTheRegistry`.
  - `testCompletingSetupConfiguresTheRegistryAndEngineBridge`.
  - `testSourceCertificateRejectedHasItsOwnMessage`.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the unit plans** on both schemes and make sure they pass.
- [ ] **Step 5: Ask, then commit** `Raise a certificate warning when a server's certificate is refused (#466)`.

### Task 10: The warning's UI, iOS and Apple TV, with journeys

**Files:**
- Create: `DionysusPlayer/Features/CertificateWarning/CertificateWarningView.swift`
- Create: `DionysusTV/Onboarding/TVCertificateWarningPage.swift`
- Modify: `DionysusPlayer/App/RootView.swift`, `DionysusTV/DionysusTVApp.swift` (`TVRootView`), `AccessibilityIdentifiers.swift`
- Modify: `UITestConfiguration.swift` (`.changedCertificate`, `.untrustedCertificate`; a seeded session whose server is `https://` with a `.certificate(selfSignedA)` trust, or none), `UITestStubURLProtocol.swift` (presents B for `.changedCertificate`)
- Test: `DionysusPlayerUITests/Journeys/CertificateWarningJourneyTests.swift`, `DionysusTVUITests/CertificateWarningJourneyTests.swift`, both audits

**Interfaces:**
- Consumes: `AppState.certificateWarning`, `trustPresentedCertificate()`, `stayOfflineForNow()`, `changeServer()` (Task 9); `CertificateDetailsRows` (Task 8).
- Produces: `A11yID.CertificateWarning.{trustButton,changeServerButton,notNowButton,previousFingerprint,newFingerprint}` and TV equivalents.

iOS presents it as a `fullScreenCover` from `RootView` over the whole app, deferred while the player's cover is up (present on its dismissal). The Apple TV presents a full-screen page from `TVRootView` with "Not Now (Stay Offline)" focused, deferred while `TVPlayerPresenter` has a player. "Trust New Certificate" asks first with an alert (iOS) / `TVConfirmation` (tvOS, Cancel focused). The *changed* kind shows both fingerprints; *untrusted* shows the offer's rows.

- [ ] **Step 1: Write the failing journeys**, both platforms: `testChangedCertificateAtLaunchShowsBothFingerprints`; `testTrustingTheNewCertificateSignsBackIn`; `testNotNowStaysOfflineWithDownloadsReachable` (iOS: Downloads tab hittable; tvOS: Home's offline state); `testChangeServerFromTheWarningReturnsToSetup`; `testUntrustedServerShowsTheOfferInsteadOfLogin`. Audit: the warning on both.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Screenshot both warnings, send to Benjamin, wait for his OK.**
- [ ] **Step 5: Run the journeys and audits** on both platforms and make sure they pass.
- [ ] **Step 6: Ask, then commit** `Show the changed-certificate warning on iOS and the Apple TV (#466)`.

### Task 11: The Certificate row in Profile

**Files:**
- Modify: `DionysusPlayer/Features/Profile/AccountDetailsSheet.swift:105-106`
- Modify: `DionysusTV/Shell/Profile/TVProfileView.swift` (beside the server and address on the left)
- Test: `DionysusPlayerUITests/Journeys/ProfileJourneyTests.swift`, `DionysusTVUITests/ProfileJourneyTests.swift`

**Interfaces:**
- Consumes: `ServerConfiguration.certificateTrust` (Task 2).
- Produces: `A11yID.Profile.certificateRow`, `A11yID.TV.Profile.certificate`; `ServerCertificateTrust.profileSummary: String` ("Trusted for <first name>" / "Trusted (self-signed)").

- [ ] **Step 1: Write the failing tests**: unit `testProfileSummaryNamesTheFirstNameOrSaysSelfSigned`; journeys `testTrustedServerShowsTheCertificateRow` (seeded trust) and `testUntrustedServerHasNoCertificateRow`, both platforms.
- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement** (`LabeledContent("Certificate", value: …)` on iOS, shown only with a trust).
- [ ] **Step 4: Screenshot, send to Benjamin, wait for his OK; then run the tests** and make sure they pass.
- [ ] **Step 5: Ask, then commit** `Show a trusted server's certificate in Profile (#466)`.

### Task 12: Docs, strings and the manual end-to-end check

**Files:**
- Modify: `CLAUDE.md` (Networking: the trust model, the registry, "a new session takes `ServerTrustDelegate`, per task on `.shared`"), `DionysusTV/CLAUDE.md` (replace "Trusting the certificate itself instead is #466" with the pages), `PRIVACY.md` (a trusted server's certificate or names are stored with its address, on device only), `TESTING.md` (the four scenarios, `TLSTestServer`), `DionysusPlayer/Resources/Localizable.xcstrings`
- Check: the three privacy manifests need no new required-reason entry (no new API category).

- [ ] **Step 1: Write the doc changes.**
- [ ] **Step 2: Sync the string catalog** with an Xcode.app build (`automate-xcstrings-catalog-sync` memory), and check every new string is present.
- [ ] **Step 3: Manual run on the iPhone 17 Simulator** against SavareseHillFlix behind a local TLS proxy on another port with `selfSignedA`'s identity (the server's own configuration untouched): set up through the offer; browse with images; direct play; a transcode (`Scripts/deeplink.sh 'play/<id>?mode=transcode'`); a download; then swap the proxy to `selfSignedB` and see the warning; each answer. Name case: `xcrun simctl keychain booted add-root-cert testCA.der`, proxy with `nameLeaf`, connect by IP. Repeat setup, browse, play and the Top Shelf on the Apple TV Simulator. Record what was run, and anything not checked, in the PR description.
- [ ] **Step 4: Run every plan once**: `UnitTests`, `UITests-Smoke`, `TVUnitTests`, `TVUITests-Smoke`, plus the new journeys from the full plans; all pass.
- [ ] **Step 5: Restore the Simulators to SavareseHillFlix as Ben and shut them down** (his hand-back rule).
- [ ] **Step 6: Ask, then commit** `Document certificate trust (#466)`, then open the PR against `develop` (closes #466).
