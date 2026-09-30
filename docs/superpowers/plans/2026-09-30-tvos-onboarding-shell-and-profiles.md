# tvOS Onboarding, Shell and Profiles Implementation Plan (Milestone 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Apple TV app the following:
- the prototype's onboarding (Welcome, Find Your Server, Who's Watching?, Quick Connect first);
- the designed sidebar shell (Home, Search, the user's libraries folded into "Libraries" above 5, and Profile);
- per-Apple-TV-user sessions: one server for the household, each person signed in to their own Jellyfin account;
- in-app account switching as the fallback when tvOS's own user switching misbehaves: every account signed in on this Apple TV is remembered and one press away on Who's Watching?;
- a "Follow Apple TV Users" setting (on by default) that, turned off, shares one sign-in and one list of remembered accounts across every Apple TV user, for households where tvOS's switching is too unreliable.

**Architecture:**
- **Per-user sessions come from the platform, not from our code.** The `com.apple.developer.user-management` entitlement (`runs-as-current-user-with-user-independent-keychain`) gives each Apple TV user their own `UserDefaults` and Keychain. tvOS terminates the app when the user switches and relaunches it as the new user, so there is no in-app "user changed" event to handle.
- Our part:
  - keep the **server configuration** in the one keychain every user shares (`kSecUseUserIndependentKeychain`);
  - bind each user's stored credentials to the server they were issued for;
  - prime the device name, which the tvOS app never did.
- The onboarding and shell are TV-only SwiftUI under `DionysusTV/`, on the shared `LoginViewModel`, `QuickConnectViewModel`, `ServerSetupViewModel` and `CollectionGridViewModel`.
- The sidebar's library list and fold rule are a small TV-only model with its own unit tests.
- **tvOS's user switching is unreliable** (see "Platform facts"), so the app never depends on it alone. `ServerSessionStore` remembers every account signed in on this container (tvOS only), Who's Watching? lists them first and signs them in on one press, and Profile's Switch User is the way back to it (Task 7).

**Tech Stack:** Swift 6, SwiftUI (tvOS 26 `TabView` + `.sidebarAdaptable`, `TabSection`), Security.framework, XcodeGen, XCTest/XCUITest (`XCUIRemote`).

**Spec:** `docs/superpowers/specs/2026-09-29-tvos-app-design.md` (Milestone 2; screens 1–4, 6, 6b, and the Profile entry of 11). Plan 1 is `docs/superpowers/plans/2026-09-29-tvos-foundation-and-playback.md`; its "Later milestones" section is the scope of this plan. The approved prototype is the Design canvas https://claude.ai/artifact/Wjp3J4eh4VGqMmmR7ntAKL, boards `Main` (Welcome), `FindServer`, `WhosWatching`, `QuickConnect`, `Sidebar` and `SidebarLibraries`. The measurements quoted in Tasks 3–4 come from its `project/tv.css`.

## Global Constraints

- **Deployment target** `tvOS 26.0` for every tvOS target. iOS stays at `18.0`.
- **Bundle ID** `com.imbenjamin.dionysusplayer`, the same as iOS.
- **The iOS app must behave identically.** The iOS `UnitTests` plan and `UITests-Smoke` stay green on every PR. Every shared-code change here (Keychain scopes, where the server configuration lives, credentials bound to a server) must leave iOS's stored data readable and its behaviour unchanged.
- **`DOWNLOADS` is defined only on `DionysusPlayer` and `DionysusPlayerTests`.** Shared code that names a Downloads type stays inside `#if DOWNLOADS`.
- **Dark only; onboarding in the landscape composition:** brand pane left, task right (prototype: brand pane 800pt wide, task pane from x=860 to 140pt from the right edge).
- **Navigation:**
  - A left sidebar with Home, Search, the libraries and Profile.
  - **More than 5 libraries fold into one expandable "Libraries" entry.**
  - Profile is the only way to Settings; there is no separate Settings item.
- **No Downloads anywhere on tvOS.** The Welcome screen's Downloads line becomes the Apple TV profiles line.
- **Quick Connect is the primary sign-in route.** "Use Password Instead" is secondary, using the system keyboard (and so the Continuity Keyboard).
- **Quick Connect copy names no menu path:** "On a device already signed in to \(serverName), open Quick Connect and enter this code."
- **Audio suppression:** a Music library never appears, the same `MediaItem.isAudioLibrary` filter Home uses.
- **The Xcode project is generated:**
  - Edit `project.yml`, then run `xcodegen generate`.
  - Never commit `.xcodeproj`, and `Package.resolved` stays gitignored.
- **Localization:**
  - Use `Text("…")` literals in views, and `String(localized:)` in models.
  - Sync `Localizable.xcstrings` in Xcode (Cmd+B) in the same PR as the new strings (memory `automate-xcstrings-catalog-sync`).
- **A11y:**
  - Never select on a label, and never put an identifier on a screen-root container.
  - New identifiers go in `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` under `A11yID.TV`.
  - Decorative images get `.accessibilityHidden(true)`.
- **Simulator first.** Ask Benjamin for the Bedroom Apple TV only for the checks that need real tvOS users. The Simulator has one user.
- **Workflow:**
  - Benjamin signs off every commit and every push.
  - Branch from `develop` in the main checkout, one PR per group below, merged with `--merge` once checks pass.
  - README.md, TESTING.md and CLAUDE.md are reviewed in the same commit as any change they describe.
  - Before sign-off, run the suites one after another, never concurrently: tvOS unit, tvOS UI, iOS unit, iOS smoke.
- **Commit trailer:** `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never include a Claude session URL.

**Test commands** (used throughout):

```bash
# tvOS unit
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -testPlan TVUnitTests
# tvOS UI
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -testPlan TVUITests
# iOS unit
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan UnitTests
# iOS smoke
xcodebuild test -project DionysusPlayer.xcodeproj -scheme DionysusPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan UITests-Smoke
```

## Platform facts this plan relies on (checked 2026-09-30)

From Apple's "Personalizing your app for each user on Apple TV" and "Mapping Apple TV users to app profiles" (sample for WWDC22 session 110384):

- With **Runs as Current User**, the app gets the current user's Keychain, preferences (`UserDefaults`), iCloud and Game Center data. **"Implement `applicationWillTerminate(_:)` to save data in case a user switch occurs while your app is in the foreground"**: a user switch terminates the app. When it next launches, it runs as the new user.
- `runs-as-current-user-with-user-independent-keychain` separates each user's data. Items written with **`kSecUseUserIndependentKeychain: true`** go to a keychain every Apple TV user can read ("signing in only needs to happen once… because items stored using this property are accessible by all Apple TV users"). Omitting the attribute stores in the current user's keychain.
- **Without** the User Management capability, "the system runs your app as the default user". That is the M1 build today, and it explains the spike finding that switching users "has no effect".

From Jellyfin `SessionManager.GetAuthorizationToken` (release-10.11.z): signing in logs out existing tokens matching **both** `DeviceId` **and** `UserId`. Two different Jellyfin accounts on one device id don't disturb each other. The same account signed in by two Apple TV users under one device id would, so `DeviceIdentity.deviceID` must stay per Apple TV user. It already does, since it lives in `UserDefaults`, and nothing here may move it to shared storage.

**tvOS routes launches to the wrong user's container, often.** Measured on the Bedroom Apple TV (tvOS 27.0) on 2026-09-30 with a probe that printed the container path and a per-user keychain marker: separation itself works (a secondary user gets `/var/PersonaVolumes/<id>/…`, the primary `/var/mobile/…`, and neither sees the other's per-user keychain items), but cold launches from the Home screen repeatedly ran as the other user, before and after restarts. It is the known system bug in Firecore's "User Switching Broken (tvOS 26.4)" thread, which Firecore reproduced with a sample app and filed with Apple ("we don't have the ability to fix this from the app side"); Apple fixed it in tvOS 26.6/27.0 beta 1, and "User switching still broken on tvOS 27" (September 2026) reports it recurring 20–30% of the time. Hence Task 7.

The spike's **one-off session loss after a reinstall** has a likely cause: before this plan, the server configuration lived in `UserDefaults`, which a reinstall erases, while the credentials live in the Keychain, which a reinstall keeps. `start()` then finds no server and goes to Find Your Server. Task 1 moves the tvOS server configuration into the Keychain, and Task 2 re-checks the reinstall on the Simulator and on the device.

## Review Focus

1. **Another Apple TV user changes the server.** The server configuration is shared, but each user's credentials are private. Anyone else's stored credentials then belong to the old server. On their next launch they must land on Who's Watching for the new server. They must never sign in to the new server with the old server's username and password, which could succeed against a different account of the same name. (Pinned in Task 1.)
2. **A launch resumed from cache while offline has no `currentUser`.** The sidebar's Profile entry must still show the stored username, never a blank row or a generic "Profile". (Pinned in Task 5.)
3. **A server whose only extra library is Music.** The fold counts libraries *after* the audio filter, so 5 video libraries plus Music stay unfolded, and a Music library never appears. (Pinned in Task 5.)
4. **The sidebar's first library load cancelled by a `TabView` rebuild.** This is the same bug Home had in M1. The model must return to a state from which `loadIfNeeded()` loads again, never stay stuck at `.loading` with no libraries. (Pinned in Task 5.)
5. **A second Apple TV user's first launch.** The server is already configured, so they skip the Welcome and Find Your Server and land on Who's Watching, on the shared server. (Pinned in Task 1 as a store test; checked on the device in Task 2.)
6. **A remembered account from another server, or with a password changed since.** Who's Watching? lists only accounts bound to the configured server. A remembered password account that no longer signs in falls back to its password screen with the error shown, and stays remembered until the person forgets it. (Pinned in Task 7.)

## Pull requests

| PR | Tasks | Branch |
|---|---|---|
| 1 | 1–2: per-user sessions | `feature/tvos-profiles` |
| 2 | 3–4: onboarding design | `feature/tvos-onboarding-design` |
| 3 | 5–6: sidebar shell and Profile | `feature/tvos-sidebar` |
| 4 | 7: in-app account switching | `feature/tvos-account-switching` |
| 5 | 8: the "Follow Apple TV Users" setting | `feature/tvos-follow-users-setting` |

---

### Task 1: Shared server, per-user credentials (shared core)

**Files:**
- Modify: `DionysusPlayer/Core/Persistence/KeychainStore.swift`
- Modify: `DionysusPlayer/Core/Persistence/ServerSessionStore.swift`
- Modify: `DionysusPlayer/Core/Models/StoredCredentials.swift`
- Modify: `DionysusPlayer/App/AppState.swift` (`start()`, `signIn(username:password:client:)`, `signInWithQuickConnect(secret:)`)
- Test: `DionysusPlayerTests/Core/Persistence/KeychainStoreTests.swift`
- Test: `DionysusPlayerTests/Core/Persistence/ServerSessionStoreTests.swift`
- Test: `DionysusPlayerTests/App/AppStateTests.swift`
- Test: `DionysusPlayerTests/Features/Login/LoginViewModelTests.swift` (tearDown only)

All three test files already compile into `DionysusTVTests` (`project.yml` includes `Core/Persistence/**`, `App/AppStateTests.swift` and `Features/Login/**`), so every test here runs on both platforms.

**Interfaces:**
- Produces:
  - `KeychainStore.Scope { case currentUser, allUsers }`.
  - `KeychainStore.save(_:forKey:scope:) -> OSStatus` (`@discardableResult`), `load(forKey:scope:) -> Data?` and `delete(forKey:scope:)`. `scope` defaults to `.currentUser`, so every existing call is unchanged.
  - `ServerSessionStore.ServerLocation { case userDefaults, sharedKeychain }`, with `static var platformDefault` (`.sharedKeychain` on tvOS, `.userDefaults` elsewhere).
  - `ServerSessionStore.init(defaults:serverLocation:)`, where `serverLocation` defaults to `.platformDefault`.
  - `ServerSessionStore.Keys.serverConfiguration` stays `"server.configuration"`, the key in both locations.
  - `StoredCredentials.serverID: String?` (`ServerConfiguration.id` at sign-in; `nil` for entries written before this change).

- [ ] **Step 1: Write the failing Keychain test**

Append to `KeychainStoreTests`:

```swift
    /// The shared scope is where tvOS keeps the household's server. On iOS it
    /// is the same keychain as `.currentUser`; either way it must round-trip.
    func test_allUsersScope_roundTripsAndDeletes() {
        let status = KeychainStore.save(Data("shared".utf8), forKey: key, scope: .allUsers)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(KeychainStore.load(forKey: key, scope: .allUsers), Data("shared".utf8))
        KeychainStore.delete(forKey: key, scope: .allUsers)
        XCTAssertNil(KeychainStore.load(forKey: key, scope: .allUsers))
    }
```

Change the file's `tearDown` to delete both scopes:

```swift
    override func tearDown() {
        KeychainStore.delete(forKey: key)
        KeychainStore.delete(forKey: key, scope: .allUsers)
        super.tearDown()
    }
```

- [ ] **Step 2: Write the failing store tests**

In `ServerSessionStoreTests`:
- Add `private let serverKey = "server.configuration" // matches ServerSessionStore.Keys.serverConfiguration`.
- Add `KeychainStore.delete(forKey: serverKey, scope: .allUsers)` to `tearDown`, so a tvOS run can't leak a server between tests.
- Append:

```swift
    // MARK: Shared-keychain server (tvOS)

    func test_sharedKeychainServer_persistsAcrossInstances_withoutTouchingDefaults() {
        let config = ServerConfiguration(name: "Living Room", baseURL: URL(string: "http://192.168.1.20:8096")!)
        ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain).saveServer(config)

        XCTAssertEqual(ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain).serverConfiguration, config)
        XCTAssertNil(defaults.data(forKey: serverKey), "The shared server must not also land in one user's defaults")
    }

    /// A second Apple TV user has their own, empty `UserDefaults` but reads the
    /// same shared keychain: they see the household's server and skip the
    /// Welcome, landing on Who's Watching.
    func test_sharedKeychainServer_secondUsersFreshDefaults_seeServerAndSkipWelcome() {
        let config = ServerConfiguration(name: "Living Room", baseURL: URL(string: "http://192.168.1.20:8096")!)
        ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain).saveServer(config)

        let otherSuite = "\(suiteName).otherUser"
        let otherDefaults = UserDefaults(suiteName: otherSuite)!
        otherDefaults.removePersistentDomain(forName: otherSuite)
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }

        let secondUser = ServerSessionStore(defaults: otherDefaults, serverLocation: .sharedKeychain)
        XCTAssertEqual(secondUser.serverConfiguration, config)
        XCTAssertTrue(secondUser.hasCompletedWelcome)
    }

    func test_sharedKeychainServer_clearAllRemovesIt() {
        let config = ServerConfiguration(name: "Living Room", baseURL: URL(string: "http://192.168.1.20:8096")!)
        let store = ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain)
        store.saveServer(config)
        store.clearAll()

        XCTAssertNil(ServerSessionStore(defaults: defaults, serverLocation: .sharedKeychain).serverConfiguration)
    }

    /// Every keychain entry written before credentials were bound to a server.
    func test_credentialsSavedBeforeServerBinding_decodeWithNilServerID() throws {
        let legacy = #"{"username":"ben","password":"pw","accessToken":"tok","userID":"u1","authMethod":"password"}"#
        let decoded = try JSONDecoder().decode(StoredCredentials.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.serverID)
        XCTAssertEqual(decoded.username, "ben")
    }
```

The existing tests that construct `ServerSessionStore(defaults: defaults)` must keep testing the `UserDefaults` path on **both** platforms. Change each of those constructions in `ServerSessionStoreTests` to `ServerSessionStore(defaults: defaults, serverLocation: .userDefaults)`. Two tests read `defaults` directly and would otherwise fail on tvOS: `test_welcome_countsAsCompletedForAnExistingServerConfiguration` and anything that seeds `defaults` with a server.

- [ ] **Step 3: Write the failing `AppState` tests**

In `AppStateTests`:
- Add `private let serverKey = "server.configuration"`.
- Add `KeychainStore.delete(forKey: serverKey, scope: .allUsers)` to `tearDown`.
- Append:

```swift
    // MARK: Credentials bound to a server

    /// Another Apple TV user changed the shared server. This user's own
    /// credentials were issued by the old one and must not be replayed against
    /// the new one, where the same username could be someone else.
    func test_start_credentialsBoundToAnotherServer_discardsThemAndGoesToLogin() async {
        let store = ServerSessionStore(defaults: defaults)
        store.saveServer(exampleServer)
        store.saveCredentials(StoredCredentials(
            username: "ben", password: "pw", accessToken: "tok", userID: "u1",
            serverID: "https://old.example.com"
        ))
        MockURLProtocol.requestHandler = { _ in
            XCTFail("No request may be sent with credentials from another server")
            throw URLError(.badServerResponse)
        }
        let appState = AppState(sessionStore: store)

        await appState.start()

        XCTAssertEqual(appState.phase, .login)
        XCTAssertNil(store.credentials)
    }

    func test_signIn_bindsCredentialsToTheConfiguredServer() async throws {
        let store = ServerSessionStore(defaults: defaults)
        let appState = AppState(sessionStore: store)
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = Self.authenticateByNameHandler

        try await appState.signIn(username: "ben", password: "pw")

        XCTAssertEqual(store.credentials?.serverID, exampleServer.id)
    }
```

`Self.authenticateByNameHandler` stands for whatever `test_signIn_success_setsUserPhaseAndPersistsCredentials` already installs as `MockURLProtocol.requestHandler`. Copy that test's handler set-up line for line rather than inventing a new one. If it's an inline closure, lift it into a `private static let authenticateByNameHandler` and use it from both tests.

The existing `test_start_validRememberedCredentials_signsInAutomatically` saves credentials with no `serverID`. It is the regression test for legacy entries: it must keep passing unchanged.

- [ ] **Step 4: Run the new tests and confirm they fail to compile**

Run the iOS unit command with `-only-testing:DionysusPlayerTests/KeychainStoreTests -only-testing:DionysusPlayerTests/ServerSessionStoreTests -only-testing:DionysusPlayerTests/AppStateTests`.
Expected: build failure. `scope:`, `serverLocation:` and `serverID:` don't exist yet.

- [ ] **Step 5: Implement `KeychainStore` scopes**

Replace `KeychainStore.swift`'s body with:

```swift
import Foundation
import Security

/// Minimal wrapper around the Keychain Services API for storing small
/// secrets (credentials, tokens) as opaque `Data` blobs.
enum KeychainStore {
    /// Whose keychain an item lives in. Only tvOS tells them apart: running as
    /// the current Apple TV user, each user has their own keychain, and
    /// `.allUsers` items go to the one every user shares
    /// (`kSecUseUserIndependentKeychain`). iOS has one user, so there the two
    /// are the same keychain.
    enum Scope {
        case currentUser
        case allUsers
    }

    private static let service = "com.dionysusplayer.ios.credentials"

    private static func baseQuery(forKey key: String, scope: Scope) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        #if os(tvOS)
        if scope == .allUsers {
            query[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue
        }
        #endif
        return query
    }

    @discardableResult
    static func save(_ data: Data, forKey key: String, scope: Scope = .currentUser) -> OSStatus {
        let query = baseQuery(forKey: key, scope: scope)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(forKey key: String, scope: Scope = .currentUser) -> Data? {
        var query = baseQuery(forKey: key, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(forKey key: String, scope: Scope = .currentUser) {
        SecItemDelete(baseQuery(forKey: key, scope: scope) as CFDictionary)
    }
}
```

- [ ] **Step 6: Implement the server location in `ServerSessionStore`**

1. Add, above `private(set) var serverConfiguration`:

```swift
    /// Where the configured server is kept. On tvOS it's the household's, not
    /// one person's: it goes in the keychain every Apple TV user shares, while
    /// each person's credentials stay in their own. It also survives a
    /// reinstall there, alongside the credentials, which `UserDefaults`
    /// doesn't. That mismatch is the likeliest cause of the spike's one
    /// unexplained session loss.
    enum ServerLocation {
        case userDefaults
        case sharedKeychain

        static var platformDefault: ServerLocation {
            #if os(tvOS)
            .sharedKeychain
            #else
            .userDefaults
            #endif
        }
    }

    private let serverLocation: ServerLocation
```

2. Change `init(defaults:)` to `init(defaults: UserDefaults = .standard, serverLocation: ServerLocation = .platformDefault)`, and assign `self.serverLocation = serverLocation` before `loadServerConfiguration()`.

3. Replace the three server-configuration touch points:

```swift
    private func loadServerConfiguration() {
        let data: Data? = switch serverLocation {
        case .userDefaults: defaults.data(forKey: Keys.serverConfiguration)
        case .sharedKeychain: KeychainStore.load(forKey: Keys.serverConfiguration, scope: .allUsers)
        }
        guard let data, let config = try? decoder.decode(ServerConfiguration.self, from: data) else { return }
        serverConfiguration = config
    }

    func saveServer(_ configuration: ServerConfiguration) {
        markWelcomeCompleted()
        serverConfiguration = configuration
        guard let data = try? encoder.encode(configuration) else { return }
        switch serverLocation {
        case .userDefaults: defaults.set(data, forKey: Keys.serverConfiguration)
        case .sharedKeychain: KeychainStore.save(data, forKey: Keys.serverConfiguration, scope: .allUsers)
        }
    }

    func clearAll() {
        clearCredentials()
        serverConfiguration = nil
        switch serverLocation {
        case .userDefaults: defaults.removeObject(forKey: Keys.serverConfiguration)
        case .sharedKeychain: KeychainStore.delete(forKey: Keys.serverConfiguration, scope: .allUsers)
        }
    }
```

Also fix the misplaced doc comment. "Forgets the server entirely…" currently sits on `markWelcomeCompleted()`; move it to `clearAll()`, and give `markWelcomeCompleted()` its own one-liner: "Records that the first-run welcome is behind the user."

Leave the type's header comment accurate: "Server config lives in `UserDefaults` on iOS and in the keychain every Apple TV user shares on tvOS; credentials live in the (per-user) Keychain."

- [ ] **Step 7: Bind credentials to their server**

In `StoredCredentials`:
- Add the property after `authMethod`:

```swift
    /// The `ServerConfiguration.id` these were issued by. On tvOS the server is
    /// shared by every Apple TV user while credentials are per user, so another
    /// user changing the server leaves these pointing at the old one; launch
    /// discards them rather than replaying a username and password against a
    /// server where the name may belong to someone else. `nil` for entries
    /// written before this existed, which are trusted as before.
    var serverID: String?
```

- Add `serverID: String? = nil` as the last `init` parameter, assigned in the body.
- Add `serverID = try container.decodeIfPresent(String.self, forKey: .serverID)` to `init(from:)`.

In `AppState`:
- In `start()`, directly after `guard let credentials = sessionStore.credentials else { … }`:

```swift
        // Another Apple TV user changed the shared server since these were
        // saved (see `StoredCredentials.serverID`).
        if let boundServerID = credentials.serverID, boundServerID != server.id {
            sessionStore.clearCredentials()
            phase = .login
            return
        }
```

- In the private `signIn(username:password:client:)` and in `signInWithQuickConnect(secret:)`, pass `serverID: sessionStore.serverConfiguration?.id` to the `StoredCredentials` initialiser.

- [ ] **Step 8: Run the tests on iOS, then on tvOS**

Run the Step 4 command. Expected: PASS.

Then run the tvOS unit command with `-only-testing:DionysusTVTests/KeychainStoreTests -only-testing:DionysusTVTests/ServerSessionStoreTests -only-testing:DionysusTVTests/AppStateTests -only-testing:DionysusTVTests/LoginViewModelTests`. Expected: PASS.

**If `test_allUsersScope_roundTripsAndDeletes` fails on tvOS only**, with status `-34018` (`errSecMissingEntitlement`) or `-50` (`errSecParam`), the Simulator is rejecting `kSecUseUserIndependentKeychain` for a host without the User Management entitlement. Task 2 adds that entitlement, so **re-run after Task 2's Step 1** before doing anything else. Only if it still fails there:
- change the `#if os(tvOS)` in `baseQuery` to `#if os(tvOS) && !targetEnvironment(simulator)`;
- add the comment "the Simulator has one user and refuses the attribute (status N, measured)";
- report the status to Benjamin.

Don't guess the status; quote the one the test printed.

`LoginViewModelTests` constructs one `ServerSessionStore`. If it now leaks a server across tvOS tests (a failure that depends on test order), add the same `KeychainStore.delete(forKey: "server.configuration", scope: .allUsers)` to its `tearDown`.

- [ ] **Step 9: Run the full iOS unit and tvOS unit plans**

Run both commands. Expected: all pass. iOS behaviour is unchanged because iOS stays on `.userDefaults`, and `.allUsers` is the same keychain there.

No commit yet: PR 1 is committed once, after Task 2.

---

### Task 2: Run as the current Apple TV user

**Files:**
- Modify: `project.yml` (the `DionysusTV` target: `entitlements`)
- Modify: `DionysusTV/DionysusTVApp.swift` (`init`: prime `DeviceIdentity`)
- Create: `DionysusTVTests/TVAppLaunchTests.swift`
- Modify: `CLAUDE.md` ("tvOS app (in progress)"), `docs/superpowers/specs/2026-09-29-tvos-app-design.md` ("Open" findings)

**Interfaces:**
- Consumes: `DeviceIdentity.primeCache()` and `DeviceIdentity.deviceName`, both unchanged. Also Task 1's `ServerSessionStore.ServerLocation.platformDefault`.
- Produces: `Generated/DionysusTV.entitlements`, generated by XcodeGen and gitignored with the rest of `Generated/`, carrying `com.apple.developer.user-management = [runs-as-current-user-with-user-independent-keychain]`.

- [ ] **Step 1: Add the entitlement**

In `project.yml`, under `targets.DionysusTV`, between `settings` and `info`:

```yaml
    # Each Apple TV user gets their own UserDefaults and Keychain, so their own
    # Jellyfin sign-in; tvOS relaunches the app as the new user on a switch.
    # Items written with kSecUseUserIndependentKeychain (the server
    # configuration) are shared by every user. Without this capability tvOS
    # runs the app as the default user for everyone.
    entitlements:
      path: Generated/DionysusTV.entitlements
      properties:
        com.apple.developer.user-management:
          - runs-as-current-user-with-user-independent-keychain
```

Run `xcodegen generate`, then `git status --short Generated/`. Expected: nothing listed, because `Generated/` is ignored. If the entitlements file shows up as untracked, ignore it the way `Info-tvOS.plist` is ignored rather than committing it.

If Task 1's Step 8 left the Simulator keychain question open, re-run that tvOS command now.

- [ ] **Step 2: Write the failing device-name test**

`DionysusTVTests/TVAppLaunchTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// Checks on what the tvOS app sets up at launch. The test host runs
/// `DionysusTVApp.init`, so these see exactly what a real launch leaves behind.
final class TVAppLaunchTests: XCTestCase {
    /// Jellyfin lists this Apple TV (Dashboard › Devices, and each session)
    /// under the name sent with every request. Unprimed, that name is the
    /// "Unknown Device" placeholder: the iOS app primes it from its
    /// `AppDelegate`, which the tvOS app doesn't have.
    @MainActor
    func test_launch_primesTheDeviceName() {
        XCTAssertNotEqual(DeviceIdentity.deviceName, "Unknown Device")
        XCTAssertEqual(DeviceIdentity.deviceName, UIDevice.current.name)
    }

    /// The household's server is shared by every Apple TV user; see
    /// `ServerSessionStore.ServerLocation`.
    func test_serverConfiguration_isSharedAcrossAppleTVUsers() {
        XCTAssertEqual(ServerSessionStore.ServerLocation.platformDefault, .sharedKeychain)
    }
}
```

`ServerLocation` needs `Equatable` for that assertion. A payload-free enum gets it for free, so no code change is needed.

Run: the tvOS unit command with `-only-testing:DionysusTVTests/TVAppLaunchTests`.
Expected: `test_launch_primesTheDeviceName` FAILS ("Unknown Device"); the other passes.

- [ ] **Step 3: Prime the device identity at launch**

In `DionysusTVApp.init()`, before the `#if DEBUG` block:

```swift
        // Jellyfin names this Apple TV from it on every request; the iOS app
        // primes it from its AppDelegate, which tvOS doesn't have.
        DeviceIdentity.primeCache()
```

`init()` of an `App` runs on the main actor, which `primeCache()` requires. Update `primeCache()`'s doc comment in `DeviceIdentity.swift` to name both call sites: "`AppDelegate`'s launch callback on iOS, `DionysusTVApp.init` on tvOS".

- [ ] **Step 4: Run the test and confirm it passes**

Same command. Expected: PASS.

- [ ] **Step 5: Simulator checks (I do these myself)**

On the booted Apple TV Simulator (memory `simulator-automation`):

1. Confirm the built app carries the entitlement:
   `codesign -d --entitlements - "$(xcodebuild -project DionysusPlayer.xcodeproj -scheme DionysusTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -showBuildSettings | awk '/ CODESIGNING_FOLDER_PATH /{print $3}')"`
   Expected: the output lists `com.apple.developer.user-management`. For a Simulator build it may appear under the simulated entitlements.
2. **The reinstall check** (the spike's open item):
   - Sign in against the LAN test server (memory `jellyfin-test-server`).
   - Run `xcrun simctl uninstall booted com.imbenjamin.dionysusplayer`, then reinstall and launch.
   - Expected: straight to Home. There should be no Find Your Server and no Who's Watching.
   - Record the result in the PR description either way.
3. Sign out through the Change Server path. That path doesn't exist until Task 6, so for now check this through the unit tests only.

- [ ] **Step 6: Device checks (ask Benjamin for the Bedroom Apple TV)**

Only these need real tvOS users. Install a Debug build with `devicectl` (memory `physical-device-cli-deployment`). Then:

1. **Existing session.** The M1 build ran as the default user. After installing this build, note whether the M1 session survives. Either outcome is acceptable, because no tvOS build has shipped. Record which one happened: it tells us whether the default user's container carries over into running as the current user.
2. **First user.** As Apple TV user A, sign in to Jellyfin account X. Expect Home.
3. **Switch users with Dionysus in the foreground.** Hold the TV button, choose user B. Expect Dionysus to close. Launch it as B. Expect Who's Watching on the same server, skipping the Welcome and Find Your Server (Review Focus 5). Sign in as account Y.
4. **Switch back to A**, then launch. Expect X's Home, with no sign-in.
5. **Jellyfin Dashboard › Devices.** Expect two entries named after the Apple TV (not "Unknown Device"), one for X and one for Y.
6. **Reinstall on the device**, as A. Expect X's Home.

If step 3 shows X's Home as user B, the entitlement isn't in effect on the device. Check the development provisioning profile for the User Management capability before touching code:

```bash
security cms -D -i ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/<profile>.mobileprovision | grep -A3 user-management
```

Report the result to Benjamin.

- [ ] **Step 7: Docs**

1. `CLAUDE.md`, "tvOS app (in progress)". Add a paragraph:

   > **Each Apple TV user has their own session.** The `DionysusTV` target runs as the current Apple TV user (`com.apple.developer.user-management` = `runs-as-current-user-with-user-independent-keychain`), so `UserDefaults` and the Keychain are per user, and tvOS terminates the app on a user switch and relaunches it as the new user. There is no in-app user-change event to handle. The server configuration is the household's: `ServerSessionStore.ServerLocation.platformDefault` puts it in the keychain every user shares (`KeychainStore.Scope.allUsers`). Credentials carry the server they were issued by (`StoredCredentials.serverID`) and are discarded at launch when another user has since changed it. `DeviceIdentity.deviceID` must stay per user: Jellyfin revokes a user's older token on the same device id (`SessionManager.GetAuthorizationToken`), so a shared id would sign one person out whenever another signs in to the same account.

2. The spec's "Open" findings:
   - Change "**Per-user profiles.** The entitlement is granted, but switching tvOS users has no effect yet." to its outcome from Step 6.
   - Change "**One unexplained loss** of the saved session after a reinstall." to its outcome from Steps 5–6.

- [ ] **Step 8: Run all four suites (one after another), then commit after sign-off and open PR 1**

```bash
git switch -c feature/tvos-profiles develop
git add DionysusPlayer/Core/Persistence DionysusPlayer/Core/Models/StoredCredentials.swift DionysusPlayer/App/AppState.swift \
  DionysusPlayerTests DionysusTV/DionysusTVApp.swift DionysusTVTests/TVAppLaunchTests.swift project.yml CLAUDE.md \
  docs/superpowers/specs/2026-09-29-tvos-app-design.md
git commit -m "Give each Apple TV user their own Jellyfin session on a shared server

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Leave `Config/Version.xcconfig` and `AppVersion.swift` unstaged: they are deliberately uncommitted.

---

### Task 3: Onboarding scaffold, Welcome and Find Your Server

**Files:**
- Modify: `DionysusTV/Onboarding/TVBrandBackground.swift` (vignette, optional photo)
- Create: `DionysusTV/Onboarding/TVOnboardingPanes.swift` (the two-pane composition)
- Create: `DionysusTV/Onboarding/TVWelcomeView.swift`
- Modify: `DionysusTV/Onboarding/TVServerSetupView.swift` (the prototype's layout)
- Modify: `DionysusTV/DionysusTVApp.swift` (`TVRootView`: Welcome first)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.TV.Onboarding`)
- Modify: `DionysusTVUITests/Support/TVUITestCase.swift` (`skipsWelcome:`)
- Test: `DionysusTVUITests/OnboardingJourneyTests.swift`, `DionysusTVUITests/LaunchJourneyTests.swift`

**Interfaces:**
- Consumes: `AppState.completeWelcome()`, `ServerSessionStore.hasCompletedWelcome`, `ServerSetupViewModel` (unchanged), `Image("DionysusGlyph")`, `Color.dionysusGold`.
- Produces:
  - `TVBrandBackground(photoURL: URL? = nil, content:)`.
  - `TVOnboardingPanes(brand:task:)`.
  - `TVWelcomeView()`.
  - New ids: `A11yID.TV.Onboarding.welcomeTitle`, `.getStarted`, `.enterAddress`, `.addressField`.
  - `TVUITestCase.launch(scenario:seedSession:skipsWelcome:extraArguments:)`.

- [ ] **Step 1: Add the identifiers and the launch parameter**

In `A11yID.TV.Onboarding`:

```swift
            static let welcomeTitle = "tv.onboarding.welcome.title"
            static let getStarted = "tv.onboarding.welcome.getStarted"
            static let enterAddress = "tv.onboarding.findServer.enterAddress"
            static let addressField = "tv.onboarding.findServer.addressField"
```

In `TVUITestCase.launch`, add `skipsWelcome: Bool = true` after `seedSession`. Pass `"-onboarding.welcomeCompleted", "YES"` only when it's `true`, mirroring iOS's `UITestCase.launch(skipsWelcome:)`.

- [ ] **Step 2: Write the failing journeys**

Append to `LaunchJourneyTests`:

```swift
    /// A first launch opens on the Welcome, with Get Started focused; Select
    /// moves on to Find Your Server, and the Welcome never shows again.
    func test_firstLaunch_showsWelcome_thenGetStartedFindsServers() {
        let app = launch(skipsWelcome: false)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.welcomeTitle].waitForExistence(timeout: 10))
        let getStarted = app.buttons[A11yID.TV.Onboarding.getStarted]
        XCTAssertTrue(waitForFocus(getStarted))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.findServerTitle].waitForExistence(timeout: 10))
    }
```

Append to `OnboardingJourneyTests`:

```swift
    /// Typing an address is the secondary route: a button below the found
    /// servers reveals the field.
    func test_enterServerAddress_revealsTheAddressField() {
        let app = launch()
        let enter = app.buttons[A11yID.TV.Onboarding.enterAddress]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        for _ in 0..<4 where !enter.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(enter))
        press(.select)
        XCTAssertTrue(app.textFields[A11yID.TV.Onboarding.addressField].waitForExistence(timeout: 5))
    }
```

Run: the tvOS UI command with `-only-testing:DionysusTVUITests/LaunchJourneyTests -only-testing:DionysusTVUITests/OnboardingJourneyTests`.
Expected: the two new tests FAIL (no Welcome, no Enter Server Address button). The existing ones still pass.

- [ ] **Step 3: Extend the background and add the panes**

`TVBrandBackground.swift`:

```swift
import SwiftUI

/// The onboarding flow's brand ground: the iOS mesh colours, drawn statically,
/// under the prototype's vignette. `photoURL` (the server's login artwork,
/// when it has one) is blended in softly over the mesh, as on Who's Watching?.
struct TVBrandBackground<Content: View>: View {
    var photoURL: URL? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.55, 0], [1, 0], [0, 0.45], [0.5, 0.5], [1, 0.55], [0, 1], [0.5, 1], [1, 1]],
                colors: [
                    .dionysusMagenta, Color(red: 0.55, green: 0.02, blue: 0.26), .dionysusBurgundy,
                    Color(red: 0.62, green: 0.16, blue: 0.10), .dionysusMagenta, Color(red: 0.55, green: 0.02, blue: 0.26),
                    .dionysusBurgundy, Color(red: 0.07, green: 0, blue: 0.04), Color(red: 0.07, green: 0, blue: 0.04)
                ]
            )
            .ignoresSafeArea()

            if let photoURL {
                AsyncRemoteImage(url: photoURL, placeholderSystemImage: "photo")
                    .scaledToFill()
                    .blur(radius: 10)
                    .saturation(1.2)
                    .opacity(0.55)
                    .blendMode(.softLight)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }

            // The prototype's vignette: darker at the edges and towards the bottom.
            ZStack {
                RadialGradient(colors: [.clear, .black.opacity(0.5)], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 400, endRadius: 1100)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            content
        }
    }
}
```

`AsyncRemoteImage` shows a placeholder while loading. If that placeholder's glyph shows through the blend, pass the background's own clear view instead: check `AsyncRemoteImage`'s initialisers for a variant without a placeholder, and otherwise load the image with `RemoteImageLoader.shared.image(for:)` into `@State` and draw `Image(uiImage:)` only once it has arrived.

`TVOnboardingPanes.swift`:

```swift
import SwiftUI

/// The onboarding composition from the prototype: an 800pt brand pane on the
/// left, the task on the right, ending 140pt from the screen's edge. Both are
/// vertically centred.
struct TVOnboardingPanes<Brand: View, Task: View>: View {
    @ViewBuilder var brand: Brand
    @ViewBuilder var task: Task

    var body: some View {
        HStack(spacing: 60) {
            brand
                .frame(width: 800)
                .frame(maxHeight: .infinity)
            task
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.trailing, 140)
        }
        .ignoresSafeArea()
    }
}
```

- [ ] **Step 4: Write `TVWelcomeView`**

```swift
import SwiftUI

/// The first-run welcome: iOS's feature lines, with Downloads (absent on
/// Apple TV) replaced by one about Apple TV users. Shown once, as on iOS
/// (`ServerSessionStore.hasCompletedWelcome`); a second Apple TV user never
/// sees it, since the server they share already counts as set up.
struct TVWelcomeView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var getStartedFocused: Bool

    private struct Feature: Identifiable {
        let id: String
        let systemImage: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private static let features = [
        Feature(
            id: "quality", systemImage: "sparkles.tv",
            title: "Plays it as it was made",
            detail: "Dolby Vision, HDR10 and surround sound, straight from your server, with the TV switched to match every frame rate and range."
        ),
        Feature(
            id: "library", systemImage: "rectangle.stack",
            title: "Your whole library, beautifully",
            detail: "Artwork-first browsing, Continue Watching, collections and playlists."
        ),
        Feature(
            id: "profiles", systemImage: "person.2",
            title: "Everyone gets their own",
            detail: "Switch Apple TV users in Control Center and Dionysus follows, each person signed in to their own Jellyfin account."
        )
    ]

    var body: some View {
        TVBrandBackground {
            TVOnboardingPanes {
                VStack(spacing: 36) {
                    Image("DionysusGlyph")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300, height: 300)
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 16)
                        .accessibilityHidden(true)
                    Text(verbatim: "Dionysus")
                        .font(.title2.bold())
                        .accessibilityHidden(true)
                }
            } task: {
                VStack(alignment: .leading, spacing: 44) {
                    Text("Your Jellyfin library, in its best light.")
                        .font(.title2.bold())
                        .frame(maxWidth: 820, alignment: .leading)
                        .accessibilityIdentifier(A11yID.TV.Onboarding.welcomeTitle)
                    VStack(alignment: .leading, spacing: 34) {
                        ForEach(Self.features) { feature in
                            HStack(alignment: .top, spacing: 30) {
                                Image(systemName: feature.systemImage)
                                    .font(.system(size: 40))
                                    .foregroundStyle(Color.dionysusGold)
                                    .frame(width: 88, height: 88)
                                    .glassEffect(.regular, in: .circle)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(feature.title).font(.headline)
                                    Text(feature.detail)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: 760, alignment: .leading)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        Button("Get Started") { appState.completeWelcome() }
                            .frame(width: 560)
                            .focused($getStartedFocused)
                            .accessibilityIdentifier(A11yID.TV.Onboarding.getStarted)
                        Text("Dionysus plays from your own Jellyfin media server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                }
            }
        }
        .defaultFocus($getStartedFocused, true)
    }
}
```

Notes for the implementer:
- **The prototype's "What's Jellyfin?" pill is deliberately left out.** tvOS has no browser to open jellyfin.org in. Say so in the PR description.
- **Check the symbol names on the tvOS 26 SDK.** If `sparkles.tv` doesn't exist there, use `tv` with a `sparkles` overlay, or plain `sparkles`. Confirm with the SF Symbols app, or look for a runtime "No symbol named" log.
- **`Get Started` doesn't need to move the screen itself.** `appState.completeWelcome()` flips `hasCompletedWelcome`, which is `@Observable`, and `TVRootView` re-renders into Find Your Server.

- [ ] **Step 5: Show the Welcome first**

In `TVRootView`, the `.serverSetup` case becomes:

```swift
                case .serverSetup:
                    if appState.sessionStore.hasCompletedWelcome {
                        TVServerSetupView()
                    } else {
                        TVWelcomeView()
                    }
```

- [ ] **Step 6: Restyle Find Your Server to the prototype**

Rework `TVServerSetupView.body`, keeping every behaviour: the scan on arrival, the first-found focus rule, `userMovedFocus`, `connect(to:)` and the address submit. The changes:

1. **Brand pane.** A 520pt radar: three concentric `Circle().stroke(.white.opacity(0.10 / 0.16 / 0.24), lineWidth: 2)` at insets 0, 70 and 140, with the glyph (190pt) centred. While `viewModel.scanState == .scanning` and `!UITestHarness.freezesAmbientMotion`, add a sweeping `AngularGradient(colors: [.dionysusGold.opacity(0.28), .clear], center: .center, startAngle: .degrees(20), endAngle: .degrees(100))` inside the outer circle, rotating once every 3s with `.repeatForever(autoreverses: false)`. Hide the whole pane from accessibility.
2. **Task pane:**
   - Title "Find Your Server" (keep its identifier).
   - Subtitle "Jellyfin servers on this network appear here as they're found."
   - Then the server rows (below).
   - Then an HStack of the "Enter Server Address" button and the status caption: "Still searching…" while scanning; "No servers found." when a scan found nothing; nothing once servers are listed and the scan is done.
3. **Server rows.** 900pt wide, at least 132pt tall, `.buttonStyle(.card)`. Each row shows:
   - a 76pt `server.rack` symbol on a `Circle().fill(.white.opacity(0.16))`;
   - the name, semibold;
   - `"\(host) · Jellyfin \(version)"` when the discovery reply has a version, otherwise the host alone (read `DiscoveredServer`'s fields; don't add a network request for the version);
   - a trailing `chevron.right`.

   Keep the `ProgressView()` shown while `connectingServerID == server.id`, in place of the chevron.
4. **The address field moves behind the button.** Add `@State private var showsAddressEntry = false`. The button (identifier `enterAddress`, label "Enter Server Address", icon `keyboard`) sets it `true`. While it's `true`, the existing `addressRow` shows below the button, and its `TextField` carries `.accessibilityIdentifier(A11yID.TV.Onboarding.addressField)` and takes focus on appear (`@FocusState private var addressFocused: Bool`).
5. Keep the error text below everything.

Wrap it all in `TVBrandBackground { TVOnboardingPanes { radar } task: { … } }`.

- [ ] **Step 7: Run the onboarding journeys and confirm they pass**

Run the Step 2 command. Expected: all pass, including M1's `test_selectDiscoveredServer_thenUser_reachesMain`.

Then take one screenshot of each of the Welcome and Find Your Server on the Simulator (`xcrun simctl io booted screenshot`) and compare it with the canvas boards `Main` and `FindServer`. Fix spacing that is visibly off. Don't chase pixel parity with CSS: tvOS's focus and glass rendering differ by design.

No commit yet: PR 2 is committed after Task 4.

---

### Task 4: Who's Watching?, Quick Connect first, and the password route

**Files:**
- Create: `DionysusTV/Onboarding/TVSignInRoute.swift`
- Modify: `DionysusTV/Onboarding/TVLoginView.swift`
- Modify: `DionysusTV/Onboarding/TVQuickConnectView.swift`
- Create: `DionysusTV/Onboarding/TVPasswordSignInView.swift`
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift`
- Test: `DionysusTVTests/TVSignInRouteTests.swift`
- Test: `DionysusTVUITests/OnboardingJourneyTests.swift`

**Interfaces:**
- Consumes:
  - `LoginViewModel`: `load(using:)`, `usersState`, `isQuickConnectAvailable`, `choose(_:using:)`, `selectedUserPassword`, `signInSelectedUser(using:)`, `username`, `password`, `signIn(using:)`, `canSubmit`, `isSigningIn`, `errorMessage` and `splashscreenURL`.
  - `QuickConnectViewModel(client:)`: `state`, `run(signIn:)`.
  - `UserAvatar(user:serverURL:size:)`.
- Produces:
  - `enum TVSignInRoute: Equatable { case signInNow, quickConnect, password }`.
  - `static func TVSignInRoute.forUser(_ user: UserDto, quickConnectAvailable: Bool) -> TVSignInRoute`.
  - `TVPasswordSignInView`.
  - Ids `A11yID.TV.Onboarding.otherUser`, `.quickConnectCode`, `.usePassword`, `.passwordField`, `.changeServer`.

- [ ] **Step 1: Write the failing route tests**

`DionysusTVTests/TVSignInRouteTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// Who's Watching? on Apple TV: Quick Connect is the primary route, typing a
/// password with the remote the fallback. Only `hasPassword == false` is
/// conclusive (see `JellyfinAPIClient.publicUsers()`), so only that signs in
/// on one press.
final class TVSignInRouteTests: XCTestCase {
    private func user(hasPassword: Bool?) -> UserDto {
        UserDto(id: "u1", name: "Ben", hasPassword: hasPassword, primaryImageTag: nil)
    }

    func test_passwordlessUser_signsInNow_evenWithQuickConnect() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: false), quickConnectAvailable: true), .signInNow)
    }

    func test_passwordUser_goesToQuickConnect_whenTheServerHasIt() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: true), quickConnectAvailable: true), .quickConnect)
    }

    func test_passwordUser_goesToPassword_whenQuickConnectIsOff() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: true), quickConnectAvailable: false), .password)
    }

    /// The server didn't say: treated as needing a password, as iOS does.
    func test_unknownPasswordState_isTreatedAsHavingOne() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: nil), quickConnectAvailable: true), .quickConnect)
    }
}
```

Run: the tvOS unit command with `-only-testing:DionysusTVTests/TVSignInRouteTests`. Expected: build failure (no `TVSignInRoute`).

- [ ] **Step 2: Implement `TVSignInRoute`**

```swift
/// Where choosing a user on Who's Watching? leads. Quick Connect first,
/// because typing a password with a Siri Remote is the worst part of any TV
/// sign-in; the password stays one press away on its screen.
enum TVSignInRoute: Equatable {
    case signInNow
    case quickConnect
    case password

    static func forUser(_ user: UserDto, quickConnectAvailable: Bool) -> TVSignInRoute {
        if user.hasPassword == false { return .signInNow }
        return quickConnectAvailable ? .quickConnect : .password
    }
}
```

Run the Step 1 command. Expected: PASS.

- [ ] **Step 3: Add the identifiers and write the failing journeys**

In `A11yID.TV.Onboarding`:

```swift
            static let otherUser = "tv.onboarding.user.other"
            static let quickConnectCode = "tv.onboarding.quickConnect.code"
            static let usePassword = "tv.onboarding.quickConnect.usePassword"
            static let passwordField = "tv.onboarding.password.field"
            static let changeServer = "tv.onboarding.whosWatching.changeServer"
```

Append to `OnboardingJourneyTests`:

```swift
    /// A user with a password goes to Quick Connect, not a keyboard; the stub
    /// approves the code on its first poll, which signs in.
    func test_passwordUser_signsInThroughQuickConnect() {
        let app = launch()
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.quickConnectCode].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Main.root].waitForExistence(timeout: 15))
    }

    /// "Use Password Instead" is one press from the code, and opens a password
    /// field for the chosen user.
    func test_quickConnect_usePasswordInstead_showsThePasswordField() {
        let app = launch(scenario: "quickConnectPending")
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        let usePassword = app.buttons[A11yID.TV.Onboarding.usePassword]
        XCTAssertTrue(usePassword.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(usePassword))
        press(.select)
        XCTAssertTrue(app.secureTextFields[A11yID.TV.Onboarding.passwordField].waitForExistence(timeout: 5))
    }

    /// With Quick Connect off, a user with a password goes straight to the
    /// password field.
    func test_quickConnectDisabled_passwordUser_goesStraightToPassword() {
        let app = launch(scenario: "quickConnectDisabled")
        connectToDiscoveredServer(app)
        let user = app.buttons[A11yID.TV.Onboarding.user(UITestFixtureIdentity.userID)]
        XCTAssertTrue(waitForFocus(user))
        press(.select)
        XCTAssertTrue(app.secureTextFields[A11yID.TV.Onboarding.passwordField].waitForExistence(timeout: 5))
    }

    private func connectToDiscoveredServer(_ app: XCUIApplication) {
        let server = app.buttons[A11yID.TV.Onboarding.serverRow(UITestFixtureIdentity.discoveredServerID)]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(server))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
    }
}
```

Replace the file's final `}` rather than adding a second one. Refactor `test_selectDiscoveredServer_thenUser_reachesMain` to use `connectToDiscoveredServer` too.

`UITestFixtureIdentity.userID` must be the id of the stub's password user (`UITestFixtureLibrary.user`, `hasPassword: true`, listed first). If the identity file names it differently (e.g. it's `UITestConfiguration.stubUserID`), use that name. Don't add an alias.

**Don't type into the password field.** XCUITest's `typeText` into a tvOS `SecureField` opens the system keyboard and is unreliable. The password sign-in itself is covered by `LoginViewModelTests`.

Run: the tvOS UI command with `-only-testing:DionysusTVUITests/OnboardingJourneyTests`. Expected: the three new tests FAIL.

- [ ] **Step 4: Rebuild `TVLoginView` to the prototype**

Keep the file's `load(using:)` task and its first-user focus rule (`focusedUserID`, `userMovedFocus`). Replace the body's layout and the choose action.

**Layout** (the canvas board `WhosWatching`), inside `TVBrandBackground(photoURL: viewModel.splashscreenURL)`:

1. **Header.** Centred, 150pt from the top:
   - the glyph at 110pt;
   - "Who's Watching?" (keep its identifier);
   - `Text("Signing in to \(Text(serverName).bold())")` in `.secondary`.
2. **Users.** 470pt from the top: a centred `HStack(spacing: 70)` of user lockups, then an "Other" lockup (identifier `otherUser`).
   - Each lockup is a `Button` with `.buttonStyle(.borderless)` whose label is `VStack(spacing: 26) { UserAvatar(user:serverURL:size: 230).hoverEffect(.highlight); Text(name).font(.callout.weight(.semibold)) }`. That gives the tvOS 26 circular-lockup look.
   - **If the Simulator shows no focus lift on it** (the spike's finding for `.borderless`), fall back to the M1 approach, `.buttonStyle(.card)` around the same label. Say which one shipped in the PR description.
   - The "Other" lockup is a 230pt `Circle().fill(.white.opacity(0.14))` with a `plus` symbol, and the text "Other".
3. **Footer.** 110pt from the bottom: a small "Change Server" button (identifier `changeServer`) → `appState.changeServer()`.
4. Keep the error text beneath the users.
5. `.unavailable` (every user hidden): "Other"'s manual form fills the users area directly. That is the existing `manualSignInForm`, restyled to one column at 600pt width.

**Choosing a user:**

```swift
    @State private var quickConnectUser: UserDto?
    @State private var passwordUser: UserDto?
    @State private var showsManualSignIn = false

    private func choose(_ user: UserDto) {
        switch TVSignInRoute.forUser(user, quickConnectAvailable: viewModel.isQuickConnectAvailable) {
        case .signInNow: Task { await viewModel.choose(user, using: appState) }
        case .quickConnect: quickConnectUser = user
        case .password: passwordUser = user
        }
    }
```

Present the three destinations as `.fullScreenCover(item: $quickConnectUser)`, `.fullScreenCover(item: $passwordUser)` and `.fullScreenCover(isPresented: $showsManualSignIn)`. `fullScreenCover` is acceptable here, because only the player must avoid it.
- **Quick Connect → password.** When "Use Password Instead" is chosen, the Quick Connect cover dismisses and `passwordUser` is set to the same user. Do that in the cover's `onDismiss` via a `@State private var switchToPasswordFor: UserDto?` handed to the cover, so the second cover isn't presented while the first is still animating out.
- **Delete the inline `selectedUserPasswordRow`.** It becomes `TVPasswordSignInView`.
- **`UserDto` needs `Identifiable` for `item:`.** It already conforms.

- [ ] **Step 5: Rebuild `TVQuickConnectView` to the prototype**

Change its init to `init(client: JellyfinAPIClient, serverName: String, user: UserDto?, serverURL: URL?, onUsePassword: (() -> Void)?)`. Keep `run(signIn:)` exactly as it is.

**Layout** (the board `QuickConnect`), in `TVBrandBackground` + `TVOnboardingPanes`:

- **Brand pane:**
  - `UserAvatar(user:serverURL:size: 260)`;
  - the user's name (`.title3.bold()`);
  - `serverName` in `.secondary`.
  - With `user == nil` (from "Other"), show the glyph instead of the avatar and no name.
- **Task pane:**
  - Title "Sign In with Quick Connect".
  - The existing instruction string, unchanged, at 800pt maximum width.
  - Then a glass panel 800pt wide (`.glassEffect(.regular, in: .rect(cornerRadius: 40))`) holding:
    - The code. In `.waiting(let code)`, show one 104×136 tile per character (`RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.12))`, 84pt bold, `.monospacedDigit()`). The whole row is `.accessibilityElement(children: .ignore)`, `.accessibilityLabel(code)` and `.accessibilityIdentifier(A11yID.TV.Onboarding.quickConnectCode)`. Use `.accessibilityLabel(Text(verbatim: code))` so the code isn't localized.
    - Below the code, a status line: a 14pt gold dot and "Waiting for approval".
  - `.requesting` / `.authorizing`: `ProgressView()` in the panel.
  - `.expired`: "The code expired." plus a "Get New Code" button, if `QuickConnectViewModel` exposes a restart. Check its API; iOS's `QuickConnectView` has the same button. Otherwise just the text.
  - `.failed(message)`: the message.
  - The buttons below the panel: "Use Password Instead" (identifier `usePassword`, default focus, shown only when `onUsePassword != nil`) and "Cancel".

**Why "Use Password Instead" takes default focus:** in the prototype the code needs no press. That button is the only thing the person might want to press, and Cancel is the fallback.

**The copy doesn't promise which account gets signed in.** Quick Connect signs in whichever account approves the code, which may not be the lockup that was chosen. Don't add copy claiming otherwise. The sidebar (Task 6) shows the account that actually signed in.

- [ ] **Step 6: Write `TVPasswordSignInView`**

```swift
import SwiftUI

/// The password route for a listed user: the fallback from Quick Connect, or
/// the only route when the server has it off. The system keyboard offers the
/// Continuity Keyboard on a nearby iPhone by itself.
struct TVPasswordSignInView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let user: UserDto
    let serverName: String
    let viewModel: LoginViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        TVBrandBackground {
            TVOnboardingPanes {
                VStack(spacing: 28) {
                    UserAvatar(user: user, serverURL: appState.sessionStore.serverConfiguration?.baseURL, size: 260)
                    Text(user.name).font(.title3.bold())
                    Text(serverName).foregroundStyle(.secondary)
                }
            } task: {
                VStack(alignment: .leading, spacing: 40) {
                    Text("Enter Your Password").font(.title2.bold())
                    SecureField("Password", text: $viewModel.selectedUserPassword)
                        .frame(width: 800)
                        .focused($fieldFocused)
                        .onSubmit(signIn)
                        .accessibilityIdentifier(A11yID.TV.Onboarding.passwordField)
                    if let error = viewModel.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    HStack(spacing: 26) {
                        Button("Sign In", action: signIn).disabled(viewModel.isSigningIn)
                        Button("Cancel") { viewModel.clearSelection(); dismiss() }
                    }
                }
            }
        }
        .task {
            // `choose` on a user with a password selects them rather than
            // signing in, so the password typed here is theirs.
            if viewModel.selectedUser?.id != user.id { await viewModel.choose(user, using: appState) }
            fieldFocused = true
        }
    }

    private func signIn() {
        Task { await viewModel.signInSelectedUser(using: appState) }
    }
}
```

`LoginViewModel.choose` toggles the selection when the same user is chosen twice. The `if` guard above prevents a second `choose` from deselecting.

On success, `AppState.phase` becomes `.main` and `TVRootView` replaces the whole login tree, cover included. Check on the Simulator that no orphaned cover remains over Home. If one does, dismiss on `appState.phase == .main` with an `.onChange` in `TVLoginView`.

- [ ] **Step 7: Run the journeys and confirm they pass**

Run the tvOS UI command for `OnboardingJourneyTests` and `LaunchJourneyTests`. Expected: all pass.

Take Simulator screenshots of Who's Watching?, Quick Connect and the password screen, and compare them with the canvas boards `WhosWatching` and `QuickConnect`.

- [ ] **Step 8: Sync strings, run all four suites, commit after sign-off and open PR 2**

Open the project in Xcode, select the `DionysusTV` scheme and build once (Cmd+B), so the new strings land in `Localizable.xcstrings` (memory `automate-xcstrings-catalog-sync`).

Update TESTING.md's tvOS section with the new journeys and `TVSignInRouteTests`, without counts.

```bash
git switch -c feature/tvos-onboarding-design develop   # after PR 1 merges
git add DionysusTV DionysusTVTests DionysusTVUITests DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift \
  DionysusPlayer/Resources/Localizable.xcstrings TESTING.md
git commit -m "Bring the Apple TV onboarding to the prototype, with Quick Connect first

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The sidebar's model: libraries, the fold rule, and the Profile identity

**Files:**
- Create: `DionysusTV/Shell/TVSidebarModel.swift`
- Create: `DionysusTV/Shell/TVSidebarLayout.swift`
- Create: `DionysusTV/Shell/TVProfileIdentity.swift`
- Modify: `DionysusPlayer/Core/UITestSupport/UITestConfiguration.swift` (a `manyLibraries` scenario)
- Modify: `DionysusPlayer/Core/UITestSupport/UITestFixtureLibrary.swift` and `UITestFixtureIdentity.swift` (its libraries)
- Modify: `DionysusPlayer/Core/UITestSupport/UITestStubURLProtocol.swift` (`/Views` for that scenario)
- Test: `DionysusTVTests/TVSidebarLayoutTests.swift`, `DionysusTVTests/TVSidebarModelTests.swift`, `DionysusTVTests/TVProfileIdentityTests.swift`

**Interfaces:**
- Consumes:
  - `JellyfinAPIClient.userViews(userID:)` and `makeImageURLBuilder()`.
  - `MediaItem(dto:images:)`, `.isAudioLibrary`, `.collectionType`, `.libraryContentItemTypes`.
  - `CollectionQuery(title:parentID:includeItemTypes:)`, `StoredCredentials`, `UserDto`.
- Produces:
  - `TVSidebarLayout.foldThreshold = 5`.
  - `enum TVSidebarLayout.Libraries: Equatable { case none, inline([MediaItem]), folded([MediaItem]) }`.
  - `static func TVSidebarLayout.libraries(_ libraries: [MediaItem]) -> Libraries`.
  - `static func TVSidebarLayout.systemImage(forCollectionType: String?) -> String`.
  - `static func TVSidebarLayout.query(for library: MediaItem) -> CollectionQuery`.
  - `@MainActor @Observable final class TVSidebarModel`, with:
    - `init(client: JellyfinAPIClient, userID: String)`;
    - `enum LoadState: Equatable { case idle, loading, loaded, failed }`;
    - `private(set) var loadState: LoadState` and `private(set) var libraries: [MediaItem]`;
    - `func loadIfNeeded() async`.
  - `static func TVProfileIdentity.user(currentUser: UserDto?, credentials: StoredCredentials?) -> UserDto?`.

- [ ] **Step 1: Write the failing layout tests**

`DionysusTVTests/TVSidebarLayoutTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// The sidebar lists each library as its own entry up to five, and folds them
/// into one "Libraries" entry above that (decided 2026-09-29), counting only
/// what's shown: a Music library is suppressed app-wide.
final class TVSidebarLayoutTests: XCTestCase {
    private func library(_ id: String, _ type: String?) -> MediaItem {
        var dto = BaseItemDto(id: id, name: id, type: .collectionFolder)
        dto.collectionType = type
        return MediaItem(dto: dto, images: ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil))
    }

    func test_noLibraries_addsNoEntries() {
        XCTAssertEqual(TVSidebarLayout.libraries([]), .none)
    }

    func test_fiveLibraries_stayInline() {
        let five = (1...5).map { library("l\($0)", "movies") }
        XCTAssertEqual(TVSidebarLayout.libraries(five), .inline(five))
    }

    func test_sixLibraries_fold() {
        let six = (1...6).map { library("l\($0)", "movies") }
        XCTAssertEqual(TVSidebarLayout.libraries(six), .folded(six))
    }

    /// Five video libraries and a Music one: the Music one is dropped first,
    /// so five remain and nothing folds.
    func test_musicLibrary_isDroppedBeforeCounting() {
        let five = (1...5).map { library("l\($0)", "movies") }
        let music = library("music", JellyfinCollectionType.music)
        XCTAssertEqual(TVSidebarLayout.libraries(five + [music]), .inline(five))
    }

    func test_symbols_coverEveryKnownCollectionType_andFallBack() {
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: JellyfinCollectionType.movies), "film")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: JellyfinCollectionType.tvShows), "tv")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: JellyfinCollectionType.boxSets), "square.stack")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: JellyfinCollectionType.playlists), "list.bullet.rectangle")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: "homevideos"), "video")
        XCTAssertEqual(TVSidebarLayout.systemImage(forCollectionType: nil), "folder")
    }

    func test_query_opensTheLibraryWithItsContentTypes() {
        let movies = library("lib-movies", JellyfinCollectionType.movies)
        let query = TVSidebarLayout.query(for: movies)
        XCTAssertEqual(query.parentID, "lib-movies")
        XCTAssertEqual(query.includeItemTypes, movies.libraryContentItemTypes)
    }
}
```

`BaseItemDto`'s memberwise shape may differ, as may whether `collectionType` is a `var` and whether a `.collectionFolder` kind exists. Match the existing test helpers: `HomeViewModelTests` or `MediaItemTests` build library DTOs somewhere, and `UITestFixtureLibrary.library(id:name:collectionType:)` shows one working construction. If `MediaItem` isn't `Equatable` over these fields, it is: `MediaItem.==` is structural (CLAUDE.md).

- [ ] **Step 2: Write the failing model and identity tests**

`DionysusTVTests/TVSidebarModelTests.swift`:
- Use `MockURLProtocol` exactly as `HomeViewModelTests` does to build a client.
- Answer `/Users/u1/Views` with the standard four fixture libraries plus a Music one.
- Mirror the cancelled-first-load test M1 added to `HomeViewModelTests`, including its slow-response helper.

```swift
    func test_load_listsVideoLibraries_withoutMusic() async {
        let model = makeModel(viewsJSON: Self.viewsWithMusic)
        await model.loadIfNeeded()
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.libraries.map(\.id), ["lib-movies", "lib-tvshows", "lib-boxsets", "lib-playlists"])
    }

    /// A `TabView` rebuild cancels the first `.task` mid-request, as it did
    /// Home's in M1. That must not leave `.loading` behind, or
    /// `loadIfNeeded()` skips forever and the sidebar never lists a library.
    func test_cancelledFirstLoad_returnsToIdle_soLoadIfNeededRetries() async {
        let model = makeModel(respondingSlowly: true)
        let task = Task { await model.loadIfNeeded() }
        await waitUntil { model.loadState == .loading }
        task.cancel()
        await task.value
        XCTAssertEqual(model.loadState, .idle)
    }

    /// A failed load leaves Home, Search and Profile usable. The sidebar
    /// just has no library entries, and the next `loadIfNeeded()` tries again.
    func test_failedLoad_isRetriedByTheNextLoadIfNeeded() async {
        let model = makeModel(status: 500)
        await model.loadIfNeeded()
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertTrue(model.libraries.isEmpty)
        installViewsHandler(status: 200, viewsJSON: Self.viewsWithMusic)
        await model.loadIfNeeded()
        XCTAssertEqual(model.loadState, .loaded)
    }
```

`installViewsHandler(status:viewsJSON:)` sets `MockURLProtocol.requestHandler` to answer `/Views` with that status and body. Build `makeModel(viewsJSON:respondingSlowly:status:)` on it and on the same `MockURLProtocol` pattern `HomeViewModelTests` uses, and `waitUntil` from `AsyncTestHelpers.swift`. Encode `viewsWithMusic` from `BaseItemDtoQueryResult` values rather than hand-writing JSON.

`DionysusTVTests/TVProfileIdentityTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// The sidebar's Profile entry names who is signed in. A launch resumed from
/// cache while the server is unreachable has no `currentUser` yet, and must
/// still show the stored account, never a blank or generic row.
final class TVProfileIdentityTests: XCTestCase {
    func test_prefersTheLiveUser() {
        let live = UserDto(id: "u1", name: "Benjamin", hasPassword: true, primaryImageTag: "tag")
        let stored = StoredCredentials(username: "old-name", password: "pw", accessToken: "t", userID: "u1")
        XCTAssertEqual(TVProfileIdentity.user(currentUser: live, credentials: stored), live)
    }

    func test_fallsBackToTheStoredAccountOffline() {
        let stored = StoredCredentials(username: "Benjamin", password: "pw", accessToken: "t", userID: "u1")
        let user = TVProfileIdentity.user(currentUser: nil, credentials: stored)
        XCTAssertEqual(user?.id, "u1")
        XCTAssertEqual(user?.name, "Benjamin")
        XCTAssertNil(user?.primaryImageTag, "No tag offline: the avatar shows the monogram")
    }

    func test_nothingStored_isNil() {
        XCTAssertNil(TVProfileIdentity.user(currentUser: nil, credentials: nil))
    }
}
```

Run: the tvOS unit command with `-only-testing:DionysusTVTests/TVSidebarLayoutTests -only-testing:DionysusTVTests/TVSidebarModelTests -only-testing:DionysusTVTests/TVProfileIdentityTests`. Expected: build failure.

- [ ] **Step 3: Implement the three types**

`DionysusTV/Shell/TVSidebarLayout.swift`:

```swift
import Foundation

/// What the sidebar lists for the user's libraries (decided 2026-09-29): each
/// library as its own entry up to `foldThreshold`, one expandable "Libraries"
/// entry above it. Counted after the audio suppression, since a Music library
/// is never shown.
enum TVSidebarLayout {
    static let foldThreshold = 5

    enum Libraries: Equatable {
        case none
        case inline([MediaItem])
        case folded([MediaItem])
    }

    static func libraries(_ libraries: [MediaItem]) -> Libraries {
        // AUDIO SUPPRESSION: as Home's library rail.
        let shown = libraries.filter { !$0.isAudioLibrary }
        if shown.isEmpty { return .none }
        return shown.count > foldThreshold ? .folded(shown) : .inline(shown)
    }

    static func systemImage(forCollectionType type: String?) -> String {
        switch type {
        case JellyfinCollectionType.movies: "film"
        case JellyfinCollectionType.tvShows: "tv"
        case JellyfinCollectionType.boxSets: "square.stack"
        case JellyfinCollectionType.playlists: "list.bullet.rectangle"
        case "homevideos": "video"
        default: "folder"
        }
    }

    /// The same query iOS's library rail opens a library with.
    static func query(for library: MediaItem) -> CollectionQuery {
        CollectionQuery(title: library.name, parentID: library.id, includeItemTypes: library.libraryContentItemTypes)
    }
}
```

The model filters audio as well. Filtering in both places is deliberate: the layout test pins the count rule on its own.

`DionysusTV/Shell/TVSidebarModel.swift`:

```swift
import Foundation
import Observation

/// The user's libraries, for the sidebar. Separate from `HomeViewModel`, which
/// fetches the same list for its own rail, because the sidebar outlives Home
/// and must not wait on Home's much larger load.
@MainActor
@Observable
final class TVSidebarModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed }

    private(set) var loadState: LoadState = .idle
    private(set) var libraries: [MediaItem] = []

    private let client: JellyfinAPIClient
    private let userID: String

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    /// Loads unless loaded or loading. A failure is retried by the next call.
    func loadIfNeeded() async {
        guard loadState == .idle || loadState == .failed else { return }
        loadState = .loading
        do {
            let images = await client.makeImageURLBuilder()
            let views = try await client.userViews(userID: userID)
            try Task.checkCancellation()
            // AUDIO SUPPRESSION: as Home's library rail.
            libraries = views.items.map { MediaItem(dto: $0, images: images) }.filter { !$0.isAudioLibrary }
            loadState = .loaded
        } catch is CancellationError {
            // Superseded, not failed: a rebuilt sidebar's `.task` must load again.
            loadState = .idle
        } catch let error as URLError where error.code == .cancelled {
            loadState = .idle
        } catch {
            loadState = .failed
        }
    }
}
```

`DionysusTV/Shell/TVProfileIdentity.swift`:

```swift
/// Who the sidebar's Profile entry shows. The live user once sign-in has
/// answered; before that (a launch resumed from cache while the server is
/// unreachable, see `AppState.start()`), the stored account, with no image tag
/// so the avatar shows its monogram rather than fetching.
enum TVProfileIdentity {
    static func user(currentUser: UserDto?, credentials: StoredCredentials?) -> UserDto? {
        if let currentUser { return currentUser }
        guard let credentials, let id = credentials.userID else { return nil }
        return UserDto(id: id, name: credentials.username, hasPassword: nil, primaryImageTag: nil)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Add the `manyLibraries` stub scenario**

1. In `UITestScenario`, after `slowPlaybackInfo`:

```swift
    /// `.standard`, but `/Views` lists seven libraries (the four standard ones,
    /// two more video libraries, and a Music one), so the Apple TV sidebar
    /// folds them into its "Libraries" entry. Six are shown after the Music one
    /// is suppressed, one over the fold threshold.
    case manyLibraries
```

2. In `UITestFixtureIdentity`, add `static let animeLibraryID = "lib-anime"`, `static let documentariesLibraryID = "lib-docs"` and `static let musicLibraryID = "lib-music"`.

3. In `UITestFixtureLibrary`, add:

```swift
    static let manyLibraries: [BaseItemDto] = libraries + [
        library(id: animeLibraryID, name: "Anime", collectionType: JellyfinCollectionType.tvShows),
        library(id: documentariesLibraryID, name: "Documentaries", collectionType: JellyfinCollectionType.movies),
        library(id: musicLibraryID, name: "Music", collectionType: JellyfinCollectionType.music)
    ]
```

   Match how `libraries` references the identity constants: fully qualified if the file does, bare if it imports them.

4. In the stub's `/Views` case:

```swift
        case path.hasSuffix("/Views"):
            let views = UITestConfiguration.scenario == .manyLibraries ? library.manyLibraries : library.libraries
            return try encode(result(scoped(views)))
```

5. Add `.manyLibraries` wherever the stub groups the scenarios that behave as `.standard`, such as the `case .standard, .emptyLibrary, .offline, …` list near line 478. Otherwise the compiler's exhaustiveness check points at every switch that needs it.

Run the iOS unit plan and the iOS smoke plan to confirm the stub change broke nothing on iOS (the stub is shared). Expected: pass.

No commit yet: PR 3 is committed after Task 6.

---

### Task 6: The sidebar shell, library grids and Profile

**Files:**
- Modify: `DionysusTV/Browse/TVMainView.swift`
- Create: `DionysusTV/Browse/TVLibraryGridView.swift`
- Create: `DionysusTV/Shell/TVProfileView.swift`
- Create: `DionysusTV/Shell/TVProfileAvatarImage.swift`
- Modify: `DionysusTV/DionysusTVApp.swift` (pass `AppState` identity into `TVMainView`)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.TV.Library`, `A11yID.TV.Profile`)
- Modify: `project.yml` (`DionysusTV` sources: add `Components/PosterCard.swift` only if Step 4 uses it; see there)
- Test: `DionysusTVUITests/SidebarJourneyTests.swift`
- Docs: `CLAUDE.md`, `TESTING.md`, `README.md` (tvOS section, if it has one), the spec's Milestones

**Interfaces:**
- Consumes: Task 5's `TVSidebarModel`, `TVSidebarLayout`, `TVProfileIdentity`; `CollectionGridViewModel(client:userID:query:)` with `items`, `loadState` and `loadIfNeeded()`; `TVPlayerPresenter.present(item:client:userID:)`; `AppState.signOut()`, `AppState.changeServer()`; `UserAvatar`; `RemoteImageLoader`.
- Produces:
  - `TVMainView(client:userID:)`, reading `AppState` from the environment.
  - `TVLibraryGridView(client:userID:library:)`.
  - `TVProfileView()`.
  - Ids:
    - `A11yID.TV.Library.title(_ libraryID:)` and `A11yID.TV.Library.tile(_ itemID:)`;
    - `A11yID.TV.Profile.name`, `.server`, `.switchUser` and `.changeServer`;
    - `A11yID.TV.Profile.changeServerConfirm`.

- [ ] **Step 1: Add the identifiers and write the failing journeys**

```swift
        enum Library {
            static func title(_ libraryID: String) -> String { "tv.library.title.\(libraryID)" }
            static func tile(_ itemID: String) -> String { "tv.library.tile.\(itemID)" }
        }
        enum Profile {
            static let name = "tv.profile.name"
            static let server = "tv.profile.server"
            static let switchUser = "tv.profile.switchUser"
            static let changeServer = "tv.profile.changeServer"
            static let changeServerConfirm = "tv.profile.changeServer.confirm"
            static let sidebarEntry = "tv.profile.sidebarEntry"
        }
```

`DionysusTVUITests/SidebarJourneyTests.swift`:

```swift
import XCTest

/// The signed-in shell: tvOS 26's sidebar with Home, Search, one entry per
/// library (four in the standard fixture), and Profile last.
final class SidebarJourneyTests: TVUITestCase {
    /// Home, Search, then Movies: selecting it opens the Movies grid.
    func test_libraryEntry_opensItsGrid() {
        let app = launchAtHome()
        press(.left)
        press(.down, times: 2)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Library.title(UITestFixtureIdentity.moviesLibraryID)].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[A11yID.TV.Library.tile(UITestFixtureIdentity.primaryMovieID)].waitForExistence(timeout: 10))
    }

    /// Profile is the last entry: Home, Search, four libraries, Profile. It
    /// names the signed-in account and offers Switch User, which returns to
    /// Who's Watching.
    func test_profile_namesTheAccount_andSwitchUserReturnsToWhosWatching() {
        let app = launchAtHome()
        press(.left)
        press(.down, times: 6)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Profile.name].waitForExistence(timeout: 10))
        let switchUser = app.buttons[A11yID.TV.Profile.switchUser]
        XCTAssertTrue(waitForFocus(switchUser))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.whosWatchingTitle].waitForExistence(timeout: 10))
    }

    /// Change Server affects every Apple TV user, so it asks first.
    func test_changeServer_asksBeforeForgettingTheServer() {
        let app = launchAtHome()
        press(.left)
        press(.down, times: 6)
        press(.select)
        let change = app.buttons[A11yID.TV.Profile.changeServer]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        press(.down)
        XCTAssertTrue(waitForFocus(change))
        press(.select)
        let confirm = app.buttons[A11yID.TV.Profile.changeServerConfirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(confirm))
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Onboarding.findServerTitle].waitForExistence(timeout: 10))
    }

    /// Above five libraries, they fold into one Libraries entry: the sidebar
    /// then reads Home, Search, Libraries, Profile.
    func test_manyLibraries_foldIntoOneEntry() {
        let app = launchAtHome(scenario: "manyLibraries")
        press(.left)
        press(.down, times: 3)
        press(.select)
        XCTAssertTrue(app.staticTexts[A11yID.TV.Profile.name].waitForExistence(timeout: 10),
                      "With the libraries folded, Profile is the fourth entry")
    }

    private func launchAtHome(scenario: String = "standard") -> XCUIApplication {
        let app = launch(scenario: scenario, seedSession: true)
        let firstTile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertTrue(firstTile.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(firstTile))
        return app
    }
}
```

Two things to check before trusting these journeys:

- **The sidebar is driven by position, not identifier.** Tab items aren't views we can attach an identifier to. In Step 2, try `.accessibilityIdentifier` on each `Tab`'s `Label`. If XCUITest then finds the sidebar entries by identifier (check with `attachTree()`), switch these journeys to select by identifier and delete the position comments. If it doesn't, keep the positions and the comments, which say what each count means.
- **A folded section may start collapsed or expanded.** Record the Simulator's actual behaviour in the test's doc comment, and adjust the `times:` count if the expanded section's rows come before Profile.

Run: the tvOS UI command with `-only-testing:DionysusTVUITests/SidebarJourneyTests`. Expected: FAIL.

- [ ] **Step 2: Build the sidebar**

`TVMainView.swift`:

```swift
import SwiftUI

/// The signed-in shell (prototype boards 6 and 6b): tvOS 26's sidebar with
/// Home, Search, the user's libraries and Profile. Above five libraries they
/// fold into one expandable "Libraries" section (`TVSidebarLayout`). Profile
/// is the only way to settings; there is no separate Settings entry.
struct TVMainView: View {
    @Environment(AppState.self) private var appState
    let client: JellyfinAPIClient
    let userID: String

    private enum TabID: Hashable { case home, search, library(String), profile }
    @State private var selection: TabID = .home
    @State private var sidebar: TVSidebarModel

    init(client: JellyfinAPIClient, userID: String) {
        self.client = client
        self.userID = userID
        _sidebar = State(initialValue: TVSidebarModel(client: client, userID: userID))
    }

    private var profileUser: UserDto? {
        TVProfileIdentity.user(currentUser: appState.currentUser, credentials: appState.sessionStore.credentials)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: TabID.home) {
                TVBrowseLauncher(client: client, userID: userID)
            }
            Tab("Search", systemImage: "magnifyingglass", value: TabID.search) {
                TVSearchView(client: client, userID: userID)
            }
            switch TVSidebarLayout.libraries(sidebar.libraries) {
            case .none:
                EmptyTabContent()
            case .inline(let libraries):
                ForEach(libraries) { libraryTab($0) }
            case .folded(let libraries):
                TabSection("Libraries") {
                    ForEach(libraries) { libraryTab($0) }
                }
            }
            Tab(value: TabID.profile) {
                TVProfileView()
            } label: {
                TVProfileAvatarImage.label(for: profileUser)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .task { await sidebar.loadIfNeeded() }
    }

    private func libraryTab(_ library: MediaItem) -> some TabContent<TabID> {
        Tab(library.name, systemImage: TVSidebarLayout.systemImage(forCollectionType: library.collectionType), value: TabID.library(library.id)) {
            TVLibraryGridView(client: client, userID: userID, library: library)
        }
    }
}
```

`TabContentBuilder`'s support for `switch`, and the name of an empty tab content (`EmptyTabContent`), vary by SDK. If the `switch` doesn't compile, make it `if case`/`else` chains over two computed `[MediaItem]` values (`inlineLibraries`, `foldedLibraries`, one of them always empty), with `ForEach` over each. That shape needs no empty content at all. Keep `TVSidebarLayout` as the only place the rule lives.

In `TVRootView`, `TVMainView` already reads `AppState` from the environment, so the call site doesn't change.

- [ ] **Step 3: The Profile entry's avatar**

`DionysusTV/Shell/TVProfileAvatarImage.swift` builds the sidebar label: the avatar, then the name.

- A sidebar tab icon must be an `Image`, so the avatar is loaded as a `UIImage` through `RemoteImageLoader`, cropped to a circle with `UIGraphicsImageRenderer`, and drawn with `.renderingMode(.original)`.
- Until it loads, and whenever the user has no `primaryImageTag` (offline, or no picture set), it falls back to `person.crop.circle.fill`.

```swift
import SwiftUI
import UIKit

/// The sidebar's Profile label: the signed-in user's picture and name
/// (decided 2026-09-28), falling back to a person symbol while the picture
/// loads, or when there is none to fetch.
enum TVProfileAvatarImage {
    @MainActor
    static func label(for user: UserDto?) -> some View {
        Label {
            Text(verbatim: user?.name ?? "")
        } icon: {
            AvatarIcon(user: user)
        }
        .accessibilityIdentifier(A11yID.TV.Profile.sidebarEntry)
    }

    private struct AvatarIcon: View {
        @Environment(AppState.self) private var appState
        let user: UserDto?
        @State private var image: UIImage?

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image).renderingMode(.original)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                }
            }
            .task(id: user?.primaryImageTag) {
                guard let user,
                      let url = UserAvatar.imageURL(for: user, serverURL: appState.sessionStore.serverConfiguration?.baseURL, size: 68),
                      let loaded = try? await RemoteImageLoader.shared.image(for: url) else { return }
                image = circular(loaded, side: 68)
            }
        }

        private func circular(_ source: UIImage, side: CGFloat) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
                source.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
    }
}
```

- `A11yID.TV.Profile.sidebarEntry` was added in Step 1.
- Check `RemoteImageLoader`'s actual entry point: `shared` and the `image(for:)` signature, and whether it throws or returns an optional. Match it.
- The name is `verbatim` because it's the user's own name, not UI copy.

**Verify on the Simulator** with a screenshot of the open sidebar:
- **The avatar may render as a monochrome template.** The tvOS sidebar is allowed to force that on tab images. If it does, keep the symbol, delete the image loading, and report it to Benjamin as a known deviation from the prototype's avatar.
- **The profile row sits last in the list, not pinned to the bottom** as in the prototype. The tvOS 26 sidebar has no bottom slot. Accept it and note it in the PR.

- [ ] **Step 4: The library grid**

`DionysusTV/Browse/TVLibraryGridView.swift` is a functional grid. Milestone 3 replaces it with the prototype's collection grid: the five facets and the alphabet jump bar.

```swift
import SwiftUI

/// One library as a poster grid, on the shared `CollectionGridViewModel` with
/// the query iOS's library rail uses. Movies and episodes play on Select; a
/// series, season or collection needs a detail page, which is Milestone 3, so
/// selecting one does nothing yet.
struct TVLibraryGridView: View {
    let client: JellyfinAPIClient
    let userID: String
    let library: MediaItem
    @State private var viewModel: CollectionGridViewModel

    init(client: JellyfinAPIClient, userID: String, library: MediaItem) {
        self.client = client
        self.userID = userID
        self.library = library
        _viewModel = State(initialValue: CollectionGridViewModel(client: client, userID: userID, query: TVSidebarLayout.query(for: library)))
    }

    private static let playableKinds: Set<BaseItemKind> = [.movie, .episode]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text(verbatim: library.name)
                    .font(.title2.bold())
                    .accessibilityIdentifier(A11yID.TV.Library.title(library.id))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 48), count: 6), spacing: 60) {
                    ForEach(viewModel.items) { item in
                        Button {
                            guard Self.playableKinds.contains(item.kind) else { return }
                            TVPlayerPresenter.present(item: item, client: client, userID: userID)
                        } label: {
                            AsyncRemoteImage(url: item.primaryImageURL, placeholderSystemImage: item.kind.placeholderSystemImage)
                                .frame(width: 250, height: 375)
                        }
                        .buttonStyle(.card)
                        .accessibilityLabel(item.railTitle)
                        .accessibilityIdentifier(A11yID.TV.Library.tile(item.id))
                    }
                }
            }
            .padding(60)
        }
        .task { await viewModel.loadIfNeeded() }
    }
}
```

Don't add iOS's `PosterCard` badges here. The tile badges are Milestone 3's (with Home's), and `project.yml` stays unchanged.

**`CollectionGridViewModel` may have the M1 bug.** Check whether its `load()` resets `.loading` on cancellation, as M1 fixed in `HomeViewModel`. Its `loadIfNeeded()` would otherwise skip forever after a `TabView` rebuild. If it doesn't reset, apply the same two `catch` clauses and add the same test to `CollectionGridViewModelTests` (it runs on both platforms) before relying on it here.

- [ ] **Step 5: The Profile screen**

`DionysusTV/Shell/TVProfileView.swift` is the entry to Settings. Milestone 3 fills in the iOS sections. For now it shows who is signed in and where, plus the two ways out:

```swift
import SwiftUI

/// Profile: who is signed in, to which server, and the two ways out. Switch
/// User signs this Apple TV user out of Jellyfin, back to Who's Watching.
/// Change Server forgets the household's server for every Apple TV user, so
/// it asks first. Milestone 3 adds the iOS settings sections above these.
struct TVProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmsChangeServer = false

    private var user: UserDto? {
        TVProfileIdentity.user(currentUser: appState.currentUser, credentials: appState.sessionStore.credentials)
    }

    var body: some View {
        VStack(spacing: 40) {
            if let user {
                UserAvatar(user: user, serverURL: appState.sessionStore.serverConfiguration?.baseURL, size: 220)
                Text(verbatim: user.name)
                    .font(.title2.bold())
                    .accessibilityIdentifier(A11yID.TV.Profile.name)
            }
            if let server = appState.sessionStore.serverConfiguration {
                Text(verbatim: server.name)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(A11yID.TV.Profile.server)
            }
            VStack(spacing: 24) {
                Button("Switch User") { appState.signOut() }
                    .accessibilityIdentifier(A11yID.TV.Profile.switchUser)
                Button("Change Server") { confirmsChangeServer = true }
                    .accessibilityIdentifier(A11yID.TV.Profile.changeServer)
            }
            .frame(width: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Change Server?", isPresented: $confirmsChangeServer, titleVisibility: .visible) {
            Button("Change Server", role: .destructive) { appState.changeServer() }
                .accessibilityIdentifier(A11yID.TV.Profile.changeServerConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone on this Apple TV will need to find a server and sign in again.")
        }
    }
}
```

- **`.confirmationDialog` buttons may not keep their identifiers.** On tvOS a `.confirmationDialog` presents as an alert sheet, and its buttons sometimes lose identifiers (memory `xcuitest-gotchas`). If the journey can't find `changeServerConfirm`, present a small custom `fullScreenCover` with the same copy and two buttons instead. Don't select on the label.
- **The dialog copy is a product call.** Tell Benjamin it's new wording, so he can change it at sign-off.
- **Why the copy says "everyone":** Change Server clears the shared server. Every other Apple TV user's stored credentials then fail their server check at launch (Task 1), so they sign in again too.

- [ ] **Step 6: Run the journeys and confirm they pass**

Run the tvOS UI command with `-only-testing:DionysusTVUITests/SidebarJourneyTests`, then the whole `TVUITests` plan. M1's Browse, Search and Player journeys must still pass. Search's "Left, Down, Select" still lands on Search, because Home and Search keep their positions.

Then take screenshots on the Simulator:
- the sidebar open with the standard fixture;
- the sidebar with `manyLibraries` (launch it with `-UITestScenario manyLibraries`);
- Profile.

Compare them with the canvas boards `Sidebar` and `SidebarLibraries`.

- [ ] **Step 7: Docs**

1. **`CLAUDE.md`, "tvOS app (in progress)".** Add a paragraph:

   > **The shell is tvOS 26's sidebar** (`TVMainView`): Home, Search, one entry per library, and Profile. Above five libraries they fold into one "Libraries" section. The rule, the symbols and the query live in `TVSidebarLayout`, counted after the Music suppression. Profile is the only way to settings, and its sidebar entry names the signed-in account, falling back to the stored one offline (`TVProfileIdentity`). Sign-in puts Quick Connect first (`TVSignInRoute`): a user with a password goes to a code, with "Use Password Instead" one press away, and only a user the server reports as passwordless signs in on Select.

2. **The spec's Milestones section.** Mark M2 done with its PR numbers, and add this plan's path, as M1 is listed.

3. **`TESTING.md`.** List `SidebarJourneyTests`, the `TVSidebar*`/`TVProfileIdentity`/`TVAppLaunchTests` unit tests and the `manyLibraries` scenario. No counts.

4. **`README.md`.** If it has a tvOS section, add one line on per-user profiles. If it has none, leave it alone: a README tvOS section is Milestone 5's docs work.

- [ ] **Step 8: Sync strings, run all four suites, commit after sign-off, and open PR 3**

Build the `DionysusTV` scheme once in Xcode (Cmd+B) to sync `Localizable.xcstrings`.

```bash
git switch -c feature/tvos-sidebar develop   # after PR 2 merges
git add DionysusTV DionysusTVTests DionysusTVUITests DionysusPlayer/Core/UITestSupport \
  DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift DionysusPlayer/Resources/Localizable.xcstrings \
  CLAUDE.md TESTING.md docs/superpowers/specs/2026-09-29-tvos-app-design.md
# plus CollectionGridViewModel(.swift|Tests.swift) if Step 4 fixed its cancellation
git commit -m "Add the Apple TV sidebar: libraries, the Libraries fold, and Profile

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

After PR 5 merges, run one final review of the whole milestone: a fresh reviewer on the most capable model, reviewing all five PRs against this plan and the spec. That's how plan 1 ended.

---

### Task 7: In-app account switching, the fallback for tvOS user switching

Added 2026-09-30 after the device checks in Task 2 showed tvOS sending cold launches to the wrong Apple TV user's container (see "Platform facts"). When that happens, the person gets someone else's container: that container's stored session, and none of their own. So every account ever signed in on this container is remembered, Who's Watching? lists those accounts first, and one press signs any of them in without a code or password. Switch User in Profile is the way back to Who's Watching?.

**Files:**
- Modify: `DionysusPlayer/Core/Persistence/ServerSessionStore.swift` (remembered accounts)
- Modify: `DionysusPlayer/App/AppState.swift` (`signIn(rememberedAccount:)`)
- Modify: `DionysusTV/Onboarding/TVSignInRoute.swift` (a `.rememberedAccount` route)
- Modify: `DionysusTV/Onboarding/TVLoginView.swift` (remembered lockups, Forget)
- Modify: `DionysusTV/Shell/TVProfileView.swift` (Switch User first, default focus)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift`
- Test: `DionysusPlayerTests/Core/Persistence/ServerSessionStoreTests.swift`, `DionysusPlayerTests/App/AppStateTests.swift`, `DionysusTVTests/TVSignInRouteTests.swift`
- Test: `DionysusTVUITests/AccountSwitchingJourneyTests.swift`
- Docs: `CLAUDE.md` (the per-user sessions paragraph), the spec's Profiles row

**Interfaces:**
- Consumes:
  - Task 1's `StoredCredentials.serverID` and `KeychainStore`.
  - Task 4's `TVSignInRoute` and `TVLoginView`.
  - Task 6's `TVProfileView`, and `AppState.signOut()` (unchanged: it clears the *current* credentials only).
- Produces:
  - `ServerSessionStore.init(defaults:serverLocation:remembersAccounts:)`, where `remembersAccounts` defaults to `.platformDefault` (tvOS `true`, iOS `false`, so iOS stores nothing new).
  - `ServerSessionStore.rememberedAccounts(forServer serverID: String) -> [StoredCredentials]`, in most-recently-used order.
  - `ServerSessionStore.forgetAccount(userID: String)`.
  - `AppState.signIn(rememberedAccount: StoredCredentials) async throws`.
  - `TVSignInRoute.rememberedAccount`.
  - `TVSignInRoute.forUser(_:quickConnectAvailable:isRemembered:)`.
  - Ids `A11yID.TV.Onboarding.rememberedUser(_ userID:)` and `A11yID.TV.Onboarding.forgetAccount`.

**Rules:**
- **Remembering is per container, like the credentials.** The list lives in the current user's keychain (`server.rememberedAccounts`), never the shared one. Remembering across all Apple TV users would hand every person's session to everyone, which the per-user design exists to avoid.
- **An account is remembered on every successful sign-in** (password, passwordless or Quick Connect). It is keyed by `userID` + `serverID`: signing in again replaces the entry and moves it to the front.
- **Switch User (`signOut()`) keeps the remembered list.** Change Server (`clearAll()`) clears it, since every entry belongs to the old server anyway.
- **Only accounts bound to the configured server are listed.** An entry without a `serverID` is never listed; remembering begins with this task, so every entry has one.
- **A remembered password account that fails to sign in** (wrong password now, or a revoked Quick Connect token) opens the password screen for that user with the error, and stays remembered.

- [ ] **Step 1: Write the failing store tests**

Append to `ServerSessionStoreTests`. Use explicit `remembersAccounts: true` so these run on iOS too, and add `KeychainStore.delete(forKey: "server.rememberedAccounts")` to `tearDown`.

```swift
    // MARK: Remembered accounts (tvOS fallback for user switching)

    private func account(_ userID: String, server: String = "https://a.example.com", token: String = "tok") -> StoredCredentials {
        StoredCredentials(username: userID, password: "", accessToken: token, userID: userID, serverID: server)
    }

    func test_signingIn_remembersTheAccount_mostRecentFirst() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true)
        store.saveCredentials(account("ben"))
        store.saveCredentials(account("tara"))
        store.saveCredentials(account("ben", token: "tok2"))

        let reloaded = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true)
        XCTAssertEqual(reloaded.rememberedAccounts(forServer: "https://a.example.com").map(\.userID), ["ben", "tara"])
        XCTAssertEqual(reloaded.rememberedAccounts(forServer: "https://a.example.com").first?.accessToken, "tok2")
    }

    func test_rememberedAccounts_listOnlyTheConfiguredServer() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true)
        store.saveCredentials(account("ben", server: "https://a.example.com"))
        store.saveCredentials(account("tara", server: "https://b.example.com"))
        XCTAssertEqual(store.rememberedAccounts(forServer: "https://a.example.com").map(\.userID), ["ben"])
    }

    func test_switchUser_keepsRememberedAccounts_changeServerClearsThem() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true)
        store.saveCredentials(account("ben"))
        store.clearCredentials()
        XCTAssertEqual(store.rememberedAccounts(forServer: "https://a.example.com").count, 1)
        store.clearAll()
        XCTAssertTrue(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true)
            .rememberedAccounts(forServer: "https://a.example.com").isEmpty)
    }

    func test_forgetAccount_removesOnlyThatAccount() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true)
        store.saveCredentials(account("ben"))
        store.saveCredentials(account("tara"))
        store.forgetAccount(userID: "ben")
        XCTAssertEqual(store.rememberedAccounts(forServer: "https://a.example.com").map(\.userID), ["tara"])
    }

    /// iOS has no tvOS user switching to fall back from, so it remembers nothing.
    func test_notRemembering_storesNoAccounts() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: false)
        store.saveCredentials(account("ben"))
        XCTAssertTrue(store.rememberedAccounts(forServer: "https://a.example.com").isEmpty)
        XCTAssertNil(KeychainStore.load(forKey: "server.rememberedAccounts"))
    }
```

Add one test to `TVAppLaunchTests` pinning the platform default: `XCTAssertTrue(ServerSessionStore.RememberedAccounts.platformDefault)`.

Run the iOS unit command with `-only-testing:DionysusPlayerTests/ServerSessionStoreTests`. Expected: build failure (no `remembersAccounts:`).

- [ ] **Step 2: Implement remembered accounts**

In `ServerSessionStore`:

```swift
    /// Whether every account signed in here is remembered for Who's Watching?.
    /// tvOS only: its user switching often launches the app in another Apple
    /// TV user's container (a system bug, see the tvOS plan's "Platform
    /// facts"), and remembered accounts make the right one a single press
    /// away. iOS has one user and stores nothing extra.
    enum RememberedAccounts {
        static var platformDefault: Bool {
            #if os(tvOS)
            true
            #else
            false
            #endif
        }
    }

    private let remembersAccounts: Bool
    private var rememberedAccounts: [StoredCredentials] = []
```

- Add `Keys.rememberedAccounts = "server.rememberedAccounts"`.
- Add the `remembersAccounts: Bool = RememberedAccounts.platformDefault` init parameter, assigned before loading; load the list from the Keychain (current user) when it's `true`.
- `saveCredentials(_:)`, after saving: when remembering and `credentials.userID != nil`, remove any entry with the same `userID` and `serverID`, insert the new one at index 0, and persist.
- `clearAll()`: also empty the list and `KeychainStore.delete(forKey: Keys.rememberedAccounts)`.
- Add:

```swift
    func rememberedAccounts(forServer serverID: String) -> [StoredCredentials] {
        rememberedAccounts.filter { $0.serverID == serverID }
    }

    func forgetAccount(userID: String) {
        rememberedAccounts.removeAll { $0.userID == userID }
        persistRememberedAccounts()
    }
```

`rememberedAccounts` is `private` storage behind the filtered accessor on purpose, so no caller can list another server's accounts. The accessor needs a different name from the stored property: call the stored property `accounts`.

Run the Step 1 command. Expected: PASS.

- [ ] **Step 3: Write the failing `AppState` tests, then add `signIn(rememberedAccount:)`**

Append to `AppStateTests`:

```swift
    func test_signInRememberedPasswordAccount_signsInWithItsStoredPassword() async throws {
        let appState = makeAppState()
        appState.completeServerSetup(exampleServer)
        var sentBody: String?
        MockURLProtocol.requestHandler = { request in
            sentBody = request.httpBodyStreamString ?? request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            return try Self.authenticateByNameHandler(request)
        }
        let remembered = StoredCredentials(username: "ben", password: "pw", accessToken: "old", userID: "user-1", serverID: exampleServer.id)

        try await appState.signIn(rememberedAccount: remembered)

        XCTAssertEqual(appState.phase, .main)
        XCTAssertTrue(sentBody?.contains("\"Pw\":\"pw\"") ?? false)
    }

    func test_signInRememberedQuickConnectAccount_validatesItsTokenInsteadOfSigningIn() async throws {
        let appState = makeAppState()
        appState.completeServerSetup(exampleServer)
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/Users/Me"), "A Quick Connect account has no password to send")
            return try MockURLProtocol.encodedJSONResponse(for: request, value: UserDto(id: "user-1", name: "ben"))
        }
        let remembered = StoredCredentials(username: "ben", password: nil, accessToken: "qc", userID: "user-1",
                                           authMethod: .quickConnect, serverID: exampleServer.id)

        try await appState.signIn(rememberedAccount: remembered)

        XCTAssertEqual(appState.phase, .main)
        XCTAssertEqual(appState.sessionStore.credentials?.accessToken, "qc")
    }
```

Match the request-body and `/Users/Me` handling to how `test_start_quickConnectSession_validatesTokenInsteadOfSigningIn` and `MockURLProtocol` already do it (`httpBodyStreamString` stands for whichever helper that file uses to read a streamed body). Run them: build failure.

Then in `AppState`:

```swift
    /// One press on a remembered account on Who's Watching?: signs in the way
    /// launch restores a session. A password account signs in again with its
    /// stored password; a Quick Connect one validates its token.
    func signIn(rememberedAccount account: StoredCredentials) async throws {
        guard let client = apiClient else { throw JellyfinAPIError.invalidServerAddress }
        switch account.authMethod {
        case .password:
            try await signIn(username: account.username, password: account.password ?? "", client: client)
        case .quickConnect:
            try await resumeQuickConnectSession(account, client: client)
            sessionStore.saveCredentials(account)
        }
    }
```

`resumeQuickConnectSession` doesn't save credentials, because launch already has them stored. Here they must become current, hence the explicit save. Run the tests: PASS.

- [ ] **Step 4: Route remembered accounts**

In `TVSignInRouteTests`, add:

```swift
    func test_rememberedAccount_signsInOnOnePress_beforeQuickConnect() {
        XCTAssertEqual(TVSignInRoute.forUser(user(hasPassword: true), quickConnectAvailable: true, isRemembered: true), .rememberedAccount)
    }
```

Change the existing four tests to pass `isRemembered: false`. Run: build failure. Then add `case rememberedAccount` and the `isRemembered: Bool` parameter, checked first:

```swift
    static func forUser(_ user: UserDto, quickConnectAvailable: Bool, isRemembered: Bool) -> TVSignInRoute {
        if isRemembered { return .rememberedAccount }
        if user.hasPassword == false { return .signInNow }
        return quickConnectAvailable ? .quickConnect : .password
    }
```

Run: PASS.

- [ ] **Step 5: Write the failing journey**

`DionysusTVUITests/AccountSwitchingJourneyTests.swift`:

```swift
import XCTest

/// The fallback for tvOS user switching: an account signed in on this Apple TV
/// is remembered, so Switch User then one press on that account returns to
/// Home, with no code and no password.
final class AccountSwitchingJourneyTests: TVUITestCase {
    func test_switchUser_thenRememberedAccount_signsBackInOnOnePress() {
        let app = launch(seedSession: true)
        let firstTile = app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)]
        XCTAssertTrue(waitForFocus(firstTile, timeout: 10))

        press(.left)
        press(.down, times: 6)   // Home, Search, four libraries, Profile
        press(.select)
        let switchUser = app.buttons[A11yID.TV.Profile.switchUser]
        XCTAssertTrue(waitForFocus(switchUser), "Switch User takes default focus on Profile")
        press(.select)

        let remembered = app.buttons[A11yID.TV.Onboarding.rememberedUser(UITestConfiguration.stubUserID)]
        XCTAssertTrue(remembered.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(remembered), "The most recent remembered account takes first focus")
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.TV.Main.root].waitForExistence(timeout: 10))
    }
}
```

`UITestHarness.seedSession()` saves its credentials through `saveCredentials`, so on tvOS the seeded account is remembered with no harness change. But it passes no `serverID`, and unbound entries are never listed. Give the seeded `StoredCredentials` `serverID: UITestConfiguration.stubServerURL.absoluteString` (the `ServerConfiguration.id` of the seeded server). If `UITestConfiguration.stubUserID` isn't visible to the UI-test target, use the `UITestFixtureIdentity` constant for the same id.

Use the Profile position and identifier conventions Task 6 settled on. If Task 6 switched the sidebar journeys to identifiers, do the same here.

Run: FAIL (no remembered lockups yet).

- [ ] **Step 6: Show remembered accounts on Who's Watching?**

In `TVLoginView`:
- Read `appState.sessionStore.rememberedAccounts(forServer: server.id)` for the configured server.
- Lay the users out in this order:
  1. Remembered accounts first, most recent first. Each is shown by its public `UserDto` when the server lists it (so the avatar appears), otherwise by `UserDto(id: userID, name: username)`.
  2. Then the public users that aren't remembered.
  3. Then "Other".
- The first focus rule (`firstUserID`) takes the first lockup, which is now the most recently used account.
- Remembered lockups carry `A11yID.TV.Onboarding.rememberedUser(userID)` instead of `user(_:)`, plus a small "signed in on this Apple TV" cue: a `checkmark.circle.fill` badge at the avatar's bottom trailing edge, `.accessibilityHidden(true)`. The lockup's accessibility label is still the name.
- Choosing one goes through `TVSignInRoute.forUser(_:quickConnectAvailable:isRemembered:)`. `.rememberedAccount` calls `appState.signIn(rememberedAccount:)`:
  - on failure with a password account, open the password screen for that user with `viewModel`'s error set to "Couldn't sign in. Check your password.";
  - on failure with a Quick Connect account, open Quick Connect for that user.
- Each remembered lockup gets `.contextMenu { Button("Forget This Account", role: .destructive) { appState.sessionStore.forgetAccount(userID:) } }` (long-press Select on the remote). The Forget button carries `A11yID.TV.Onboarding.forgetAccount`.

`ServerSessionStore` is `@Observable` and `accounts` is stored state, so forgetting redraws the list.

- [ ] **Step 7: Make Switch User the easy way back**

In `TVProfileView`, give Switch User default focus (`@FocusState` + `.defaultFocus`). Place it first, above Change Server, as the Task 6 layout already does. The route is then two presses from anywhere: Menu to the sidebar → Profile → Select.

- [ ] **Step 8: Run the journey and the suites**

Run the Step 5 journey: PASS. Then the whole `TVUITests` plan, and the tvOS and iOS unit plans. The iOS smoke plan must be unaffected, since iOS remembers nothing.

- [ ] **Step 9: Docs, then commit after sign-off and open PR 4**

- **CLAUDE.md, the per-user sessions paragraph.** Add: "tvOS's user switching is unreliable: cold launches often run in another Apple TV user's container (a system bug Firecore reproduced for Infuse, fixed in tvOS 26.6, recurring on 27). So `ServerSessionStore` remembers every account signed in on a container (tvOS only, per user), Who's Watching? lists them first and signs them in on one press, and Profile's Switch User is the way back to it. Don't design anything that assumes the container matches the Apple TV user."
- **The spec's Profiles row.** Append: "with remembered accounts and one-press switching in the app as the fallback when tvOS's own switching misbehaves."
- **TESTING.md.** List the journey.

```bash
git switch -c feature/tvos-account-switching develop   # after PR 3 merges
git add DionysusPlayer DionysusPlayerTests DionysusTV DionysusTVTests DionysusTVUITests CLAUDE.md TESTING.md \
  docs/superpowers/specs/2026-09-29-tvos-app-design.md DionysusPlayer/Resources/Localizable.xcstrings
git commit -m "Remember accounts on Apple TV for one-press switching when tvOS user switching fails

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The "Follow Apple TV Users" setting

Requested by Benjamin on 2026-09-30, as a follow-up to PR 1: a setting to stop following Apple TV users, for anyone who finds tvOS's switching bug too annoying and would rather switch accounts in the app.

**What it can and can't do.** The User Management entitlement is part of the signed app, so a setting can't stop tvOS choosing which Apple TV user's container a launch runs in. What the setting controls is *where the session lives*:
- **On (the default):** credentials and remembered accounts are per Apple TV user (Tasks 1 and 7).
- **Off:** credentials and remembered accounts move to the keychain every Apple TV user shares. Whichever container tvOS picks, the app opens on the same account, and people change account with Switch User and Who's Watching?.

**Rules:**
- **The setting itself lives in the shared keychain** (`settings.followsAppleTVUsers`, `KeychainStore.Scope.allUsers`). A value stored per container would change with the very bug it exists to avoid. It is one setting for the whole Apple TV, and the copy says so.
- **Turning it off moves this container's session** (current credentials plus remembered accounts) to the shared keychain, and deletes the per-user copies. Other Apple TV users' per-user sessions stay where they are, unused while the setting is off.
- **Turning it on moves the shared session** into this container's per-user keychain and deletes the shared copies. Every other Apple TV user then starts from Who's Watching?, with nothing remembered.
- **Not moved, accepted:**
  - `UserDefaults` preferences (stream, track and Next Up settings, search history) and `DeviceIdentity.deviceID` stay per container either way.
  - While the setting is off, a launch in another container reads that container's preferences and a different device id. The session still works: Jellyfin checks the token, not the device id.
  - Moving preferences is out of scope unless Benjamin asks.
- **tvOS only.** iOS has no Apple TV users; the setting is compiled out there, and `ServerSessionStore` on iOS behaves exactly as before.

**Files:**
- Create: `DionysusPlayer/Core/Persistence/SessionScopeSetting.swift` (the shared-keychain Bool, tvOS only)
- Modify: `DionysusPlayer/Core/Persistence/ServerSessionStore.swift` (a `sessionScope` used for credentials and remembered accounts, plus `moveSession(to:)`)
- Modify: `DionysusPlayer/App/AppState.swift` (`setFollowsAppleTVUsers(_:)`)
- Modify: `DionysusTV/Shell/TVProfileView.swift` (the toggle)
- Modify: `DionysusPlayer/Shared/Accessibility/AccessibilityIdentifiers.swift` (`A11yID.TV.Profile.followsAppleTVUsers`)
- Test: `DionysusPlayerTests/Core/Persistence/ServerSessionStoreTests.swift`, `DionysusTVTests/SessionScopeSettingTests.swift`
- Test: `DionysusTVUITests/AccountSwitchingJourneyTests.swift`
- Docs: `CLAUDE.md` (the per-user sessions paragraph), the spec's Profiles row, TESTING.md

**Interfaces:**
- Consumes: Task 1's `KeychainStore.Scope`, and Task 7's remembered accounts and `forgetAccount(userID:)`.
- Produces:
  - `enum SessionScopeSetting { static var followsAppleTVUsers: Bool { get }; static func set(_ follows: Bool) }`. The default is `true` when nothing is stored.
  - `ServerSessionStore.init(defaults:serverLocation:remembersAccounts:sessionScope:)`, where `sessionScope: KeychainStore.Scope` defaults to `.currentUser` on iOS, and on tvOS to `SessionScopeSetting.followsAppleTVUsers ? .currentUser : .allUsers`.
  - `ServerSessionStore.moveSession(to scope: KeychainStore.Scope)`.
  - `AppState.setFollowsAppleTVUsers(_ follows: Bool)`.

- [ ] **Step 1: Write the failing store tests**

In `ServerSessionStoreTests`:
- Add `KeychainStore.delete(forKey: "server.credentials", scope: .allUsers)` and the same for `"server.rememberedAccounts"` to `tearDown`.
- Append the tests below.

On iOS both scopes are one keychain, so the scope assertions only mean something on tvOS. Guard the two scope-separation tests with `#if os(tvOS)` and keep the round-trip ones unguarded.

```swift
    // MARK: Session scope (tvOS "Follow Apple TV Users" off)

    func test_sharedScope_roundTripsCredentialsAndRememberedAccounts() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true, sessionScope: .allUsers)
        store.saveCredentials(StoredCredentials(username: "ben", password: "", accessToken: "t", userID: "u1", serverID: "s"))

        let reloaded = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true, sessionScope: .allUsers)
        XCTAssertEqual(reloaded.credentials?.userID, "u1")
        XCTAssertEqual(reloaded.rememberedAccounts(forServer: "s").map(\.userID), ["u1"])
    }

    #if os(tvOS)
    func test_moveSessionToShared_leavesNothingPerUser() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true, sessionScope: .currentUser)
        store.saveCredentials(StoredCredentials(username: "ben", password: "", accessToken: "t", userID: "u1", serverID: "s"))

        store.moveSession(to: .allUsers)

        XCTAssertNil(KeychainStore.load(forKey: "server.credentials"))
        XCTAssertNil(KeychainStore.load(forKey: "server.rememberedAccounts"))
        let shared = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true, sessionScope: .allUsers)
        XCTAssertEqual(shared.credentials?.userID, "u1")
        XCTAssertEqual(shared.rememberedAccounts(forServer: "s").map(\.userID), ["u1"])
    }

    func test_moveSessionBackToPerUser_leavesNothingShared() {
        let store = ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true, sessionScope: .allUsers)
        store.saveCredentials(StoredCredentials(username: "ben", password: "", accessToken: "t", userID: "u1", serverID: "s"))

        store.moveSession(to: .currentUser)

        XCTAssertNil(KeychainStore.load(forKey: "server.credentials", scope: .allUsers))
        XCTAssertNil(KeychainStore.load(forKey: "server.rememberedAccounts", scope: .allUsers))
        XCTAssertEqual(ServerSessionStore(defaults: defaults, serverLocation: .userDefaults, remembersAccounts: true, sessionScope: .currentUser).credentials?.userID, "u1")
    }
    #endif
```

`DionysusTVTests/SessionScopeSettingTests.swift`:

```swift
import XCTest
@testable import Dionysus

/// The setting is one value for the whole Apple TV, stored where every Apple
/// TV user reads it, and on by default.
final class SessionScopeSettingTests: XCTestCase {
    override func tearDown() {
        KeychainStore.delete(forKey: "settings.followsAppleTVUsers", scope: .allUsers)
        super.tearDown()
    }

    func test_defaultsToFollowingAppleTVUsers() {
        XCTAssertTrue(SessionScopeSetting.followsAppleTVUsers)
    }

    func test_turnedOff_persistsInTheSharedKeychain() {
        SessionScopeSetting.set(false)
        XCTAssertFalse(SessionScopeSetting.followsAppleTVUsers)
        XCTAssertNotNil(KeychainStore.load(forKey: "settings.followsAppleTVUsers", scope: .allUsers))
    }
}
```

Run the tvOS unit command with `-only-testing:DionysusTVTests/ServerSessionStoreTests -only-testing:DionysusTVTests/SessionScopeSettingTests`. Expected: build failure.

- [ ] **Step 2: Implement**

1. **`SessionScopeSetting.swift`**, inside `#if os(tvOS)`:

```swift
import Foundation

/// "Follow Apple TV Users": whether each Apple TV user keeps their own
/// Dionysus session (on, the default) or everyone shares one (off). Stored in
/// the keychain every Apple TV user shares, because tvOS's user-switching bug
/// can launch the app in any user's container; a per-container value would
/// flip with it.
enum SessionScopeSetting {
    private static let key = "settings.followsAppleTVUsers"

    static var followsAppleTVUsers: Bool {
        guard let data = KeychainStore.load(forKey: key, scope: .allUsers) else { return true }
        return data != Data([0])
    }

    static func set(_ follows: Bool) {
        KeychainStore.save(Data([follows ? 1 : 0]), forKey: key, scope: .allUsers)
    }
}
```

2. **`ServerSessionStore`:** replace the credentials' and remembered accounts' hard-coded `.currentUser` with a stored `sessionScope`:
   - Add `private(set) var sessionScope: KeychainStore.Scope`, set from the new init parameter.
   - Pass `scope: sessionScope` to every `KeychainStore` call on `Keys.credentials` and `Keys.rememberedAccounts`.
   - Add:

```swift
    /// Moves the current credentials and remembered accounts to `scope`,
    /// deleting them from the scope they were in (see `SessionScopeSetting`).
    func moveSession(to scope: KeychainStore.Scope) {
        guard scope != sessionScope else { return }
        let previous = sessionScope
        KeychainStore.delete(forKey: Keys.credentials, scope: previous)
        KeychainStore.delete(forKey: Keys.rememberedAccounts, scope: previous)
        sessionScope = scope
        if let credentials, let data = try? encoder.encode(credentials) {
            KeychainStore.save(data, forKey: Keys.credentials, scope: scope)
        }
        persistRememberedAccounts()
    }
```

   `persistRememberedAccounts()` (Task 7) must write with `scope: sessionScope`.

   Default for the init parameter: define `static var platformDefaultSessionScope: KeychainStore.Scope` as `#if os(tvOS) SessionScopeSetting.followsAppleTVUsers ? .currentUser : .allUsers #else .currentUser #endif`.

3. **`AppState`**, inside `#if os(tvOS)`:

```swift
    /// The "Follow Apple TV Users" setting. The session moves with it, so
    /// whoever is signed in stays signed in.
    func setFollowsAppleTVUsers(_ follows: Bool) {
        SessionScopeSetting.set(follows)
        sessionStore.moveSession(to: follows ? .currentUser : .allUsers)
    }
```

Run the Step 1 command: PASS. Then the full iOS unit plan, which must be unchanged.

- [ ] **Step 3: The toggle**

In `TVProfileView`, below Switch User and Change Server, add a section:

```swift
            Toggle("Follow Apple TV Users", isOn: Binding(
                get: { SessionScopeSetting.followsAppleTVUsers },
                set: { appState.setFollowsAppleTVUsers($0) }
            ))
            .frame(width: 900)
            .accessibilityIdentifier(A11yID.TV.Profile.followsAppleTVUsers)
            Text("On: each person on this Apple TV has their own Dionysus sign-in, following the user chosen in Control Center. Off: everyone shares one sign-in and switches accounts with Switch User. Turn this off if Dionysus opens as the wrong person. Applies to everyone on this Apple TV.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 900)
```

`SessionScopeSetting` isn't observable, so the `Binding`'s getter won't redraw by itself after a change. Hold the value in `@State private var followsAppleTVUsers = SessionScopeSetting.followsAppleTVUsers`, and set both it and the app state in the binding's setter.

Add `static let followsAppleTVUsers = "tv.profile.followsAppleTVUsers"` to `A11yID.TV.Profile`.

The copy is new wording. Flag it to Benjamin at sign-off.

- [ ] **Step 4: Write the failing journey, then make it pass**

Append to `AccountSwitchingJourneyTests`:

```swift
    /// Turned off, the session moves to the keychain every Apple TV user
    /// shares, and whoever is signed in stays signed in across a relaunch.
    func test_followAppleTVUsersOff_keepsTheSignedInAccountAcrossRelaunch() {
        let app = launch(seedSession: true)
        XCTAssertTrue(waitForFocus(app.buttons[A11yID.TV.Main.tile(UITestFixtureIdentity.partWatchedMovieID)], timeout: 10))
        press(.left)
        press(.down, times: 6)   // Profile, as in Task 6
        press(.select)
        let toggle = app.switches[A11yID.TV.Profile.followsAppleTVUsers]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        for _ in 0..<4 where !toggle.hasFocus { press(.down) }
        XCTAssertTrue(waitForFocus(toggle))
        press(.select)

        app.terminate()
        let relaunched = launch(extraArguments: ["-UITestResetState", "NO"])
        XCTAssertTrue(relaunched.descendants(matching: .any)[A11yID.TV.Main.root].waitForExistence(timeout: 10))
    }
```

**Two things to check in the harness before trusting this:**
- `TVUITestCase.launch` always passes `-UITestResetState YES`. Check whether a later `NO` overrides it. If not, add a `resetsState: Bool = true` parameter to `launch` and pass `NO` for the relaunch.
- `UITestHarness.resetPersistentState()` must also clear the shared session keys and `settings.followsAppleTVUsers`, or this test leaks the "off" setting into every later test. Add those three deletes there, using `.allUsers`.

Run it: FAIL, then PASS after Step 3. Then run the whole `TVUITests` plan.

- [ ] **Step 5: Docs, then commit after sign-off and open PR 5**

- **CLAUDE.md, the per-user sessions paragraph.** Add: "The Profile setting 'Follow Apple TV Users' (`SessionScopeSetting`, stored in the shared keychain, on by default) moves the session between the per-user and shared keychains (`ServerSessionStore.moveSession(to:)`); off, every Apple TV user shares one sign-in and remembered list. It can't change which container tvOS launches into; preferences and the device id stay per container either way."
- **The spec's Profiles row.** Append: "A Profile setting, Follow Apple TV Users, can turn per-user sessions off for the whole Apple TV."
- **TESTING.md.** List the new tests, and the harness reset of the shared keys.

```bash
git switch -c feature/tvos-follow-users-setting develop   # after PR 4 merges
git add DionysusPlayer DionysusPlayerTests DionysusTV DionysusTVTests DionysusTVUITests CLAUDE.md TESTING.md \
  docs/superpowers/specs/2026-09-29-tvos-app-design.md DionysusPlayer/Resources/Localizable.xcstrings
git commit -m "Add the Follow Apple TV Users setting: share one session when tvOS switching misbehaves

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Deviations from the prototype, to confirm with Benjamin at sign-off

- **"What's Jellyfin?" is dropped from the Welcome.** tvOS has no browser to open it in.
- **Profile is the last sidebar row, not pinned to the bottom.** The tvOS 26 sidebar has no bottom slot. Its avatar may be forced to a template symbol (Task 6, Step 3).
- **The tvOS 26 sidebar collapses to a "‹ Home" pill**, not the prototype's icon rail. This was already accepted in the spec.
- **The Change Server confirmation copy is new** (Task 6, Step 5).
- **The Follow Apple TV Users setting and its footer copy are new** (Task 8, Step 3); the prototype's Profile screen has no such row.

## Out of scope (later milestones)

- The prototype's Home, detail pages, the collection grid's facets and alphabet bar, Search's Recent Searches, and the full Profile/Settings sections: **M3**.
- Tile badges: **M3**, with Home.
- Top Shelf, Now Playing, and a tvOS archive/upload. The App Store distribution profile will also need the User Management capability, which is part of the **M5** release pipeline.
