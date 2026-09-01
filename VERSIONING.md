# Versioning

Dionysus Player uses [SemVer](https://semver.org/) (`MAJOR.MINOR.PATCH`,
with `-alpha.N`/`-beta.N` prerelease suffixes), grounded in git tags and
wired into Xcode's own version fields as far as Apple allows.

## Why there are two version strings, not one

Apple requires `CFBundleShortVersionString` (the App Store/TestFlight-facing
version) and `CFBundleVersion` (the build number) to be plain
dot-separated integers — no `-alpha.3` suffix, even for TestFlight. So the
full SemVer (with prerelease suffix) and the Apple-facing version aren't the
same field; one is mechanically derived from the other:

| | Format | Where it lives | Purpose |
|---|---|---|---|
| **Full SemVer** | `1.2.3-alpha.4` | The git tag itself; `AppVersion.full` (generated Swift constant) | Source of truth. Human-facing: Profile screen footer, git history, GitHub Releases. |
| **Core version** | `1.2.3` | `MARKETING_VERSION` build setting (`Config/Version.xcconfig`) → `CFBundleShortVersionString` | What Apple/TestFlight ever sees. |
| **Build number** | `842` (total commit count) | `CURRENT_PROJECT_VERSION` build setting (`Config/Version.xcconfig`) → `CFBundleVersion` | Apple's monotonic-increase requirement. |

## Tag convention

Annotated tags, prefixed `v`: `v1.2.3`, `v1.2.3-alpha.4`, `v2.0.0-beta.1`.

- **Alpha/beta tags are cut from `develop`** — features and fixes land on
  `develop` as the working branch; once a batch is ready for wider internal
  testing, tag it there.
- **Final `vX.Y.Z` tags (no suffix) are cut from `stable`**, after merging
  `develop` into `stable`. The final release is either exactly the approved
  prerelease commit, or that commit plus any last fixes found during
  prerelease testing — either way, `stable` only ever moves forward via a
  `develop → stable` merge.
- Bump rules are the usual SemVer judgment call: PATCH for fixes only,
  MINOR for backward-compatible features, MAJOR for breaking changes/major
  redesigns.
- The first tag is `v0.1.0-alpha.1`.

## Day-to-day: cutting a tag

**Push an annotated tag. That's the whole flow.**

```sh
git checkout develop && git pull
git tag -a v1.2.0-alpha.1 -m "Short, tester-facing summary of what changed.

- plain language, aimed at whoever's installing the build
- no internal type or file names
- still an early alpha, expect rough edges"
git push origin v1.2.0-alpha.1
```

`.github/workflows/release.yml` takes it from there: it stamps the version
from the tag, refreshes the AetherEngine version display, builds and tests
the exact tagged commit, publishes a GitHub Release, and archives, signs and
uploads the build to App Store Connect — where it becomes a TestFlight build.

**Write the tag message as real release notes.** It isn't just a label: it
becomes both the GitHub Release body and TestFlight's "What to Test" — see
"Release notes" below.

Successive builds at the same core version bump the trailing number:
`v1.2.0-alpha.2`, `v1.2.0-alpha.3`, ... then `v1.2.0-beta.1`, ... then,
once approved, `v1.2.0`.

### Final releases come from `stable`

Prereleases (`-alpha`/`-beta`, or **any** `0.x` version) are cut from
`develop` and stay there. Final releases are cut from `stable`, which is
release-only and lags `develop`:

```sh
gh workflow run promote-to-stable.yml   # opens the develop -> stable PR
# merge it (gated by pr-checks.yml, like any other PR), then:
git checkout stable && git pull
git tag -a v1.2.0 -m "Release summary for testers…"
git push origin v1.2.0
```

`release.yml` refuses a tag on the wrong branch — a prerelease tag not
contained in `develop`, or a final tag not contained in `stable` — and says
so within seconds, rather than after a ~40 minute archive and upload.

The promotion workflow deliberately opens the PR but does **not** merge it.
Merging from CI would need a standing credential able to bypass `stable`'s
ruleset, kept around for something done a handful of times a year.

Nothing needs stamping, predicting, or verifying beforehand, and
`./Scripts/update-aetherengine-version.sh` does not need running as part of
cutting a release — CI regenerates both.

### Why there is no longer a release-prep PR

This used to be a two-CI-round-trip ritual: stamp the version on a
`release/vX.Y.Z` branch, PR it, merge it, verify, *then* tag. That existed
solely because `release.yml` checked the *checked-in* generated files against
what it computed at tag time — which forced `update-version.sh` to **predict**
the build number as "current commit count + 2" (the prep commit, plus the
merge commit `gh pr merge --merge` always fabricates).

That prediction broke live three times: twice on the arithmetic itself (#123,
#132) and once when an unrelated PR landed on `develop` between the stamp and
the tag (`v0.7.0-alpha.1`, 2026-08-28), which took two recovery branches and
three CI runs to unpick. A companion `verify-ready-to-tag.sh` existed only to
catch that class locally.

The fix was to delete the requirement rather than keep policing it. CI stamps
from the tag, at a point where the tag demonstrably exists — so there is
nothing to predict and nothing to verify. If you find yourself re-adding a
"stamp before tagging" step, re-read this section first.

**The trade:** `Config/Version.xcconfig` and `AppVersion.swift` on `develop`
now reflect the *last release*, not the current commit. That's intended. A
local build between releases reports e.g. `0.8.0-alpha.1+12.gabc1234` — the
off-tag build metadata `update-version.sh` has always emitted — which is
honest about being 12 commits past the tag rather than silently claiming to
be it. Run `./Scripts/update-version.sh` by hand any time you want those
files refreshed; nothing depends on you remembering to.

### Release notes

**The annotated tag's message *is* the release notes.** CI reads it back with
`git tag -l --format='%(contents)'` and publishes it above GitHub's
auto-generated "What's Changed" PR list. Write it accordingly — this is the
one part of cutting a release that still needs a human, and it's the reason
the tag must be annotated (`git tag -a`) rather than lightweight.

The summary is a few bullet points aimed at whoever's actually installing
the build (an internal tester, not a future contributor reading `git log`):
what changed from a user's perspective, in plain language — no internal
type/file names, no implementation detail. Skip bullets for pure
chores/CI fixes that a user wouldn't notice; call out real features/fixes
only. End with a one-line "still an early alpha, expect rough edges"
disclaimer while prerelease. Established with `v0.1.0-alpha.2`'s notes —
use those as the template.

This used to be a manual `gh release edit --notes-file` pass *after* every
workflow run, which meant a release sat published-but-unreadable in the gap,
and "treat the release as done" depended on someone remembering. Getting it
wrong now means amending the notes on GitHub after the fact — the same
recovery as before, just no longer the default path.

## Signing setup

`release.yml` signs, archives and uploads to App Store Connect using three
repo **secrets** and two repo **variables**. Without them it skips those
steps with a warning and publishes to GitHub only — so a missing credential
degrades the release rather than failing it. If a tag didn't reach
TestFlight, check the run summary first.

| | Name | Contents |
|---|---|---|
| secret | `APPSTORE_CERTIFICATES_FILE_BASE64` | `base64 -i AppleDistribution.p12` |
| secret | `APPSTORE_CERTIFICATES_PASSWORD` | the `.p12` export password |
| secret | `APPSTORE_API_PRIVATE_KEY` | full contents of `AuthKey_XXXXXX.p8` |
| var | `APPSTORE_ISSUER_ID` | ASC → Users and Access → Integrations |
| var | `APPSTORE_API_KEY_ID` | the key's ID, same page |

One-time setup:

1. **App Store Connect API key.** ASC → Users and Access → Integrations →
   App Store Connect API → generate a team key with the **App Manager**
   role. Admin or App Manager is required — `-allowProvisioningUpdates`
   needs to create and update provisioning profiles, and a Developer-role
   key will fail the archive. The `.p8` downloads **once**; there is no
   second chance.
2. **Distribution certificate.** Keychain Access → your *Apple Distribution*
   certificate → expand it and select both the certificate **and** its
   private key → Export as a `.p12` with a password. Exporting the
   certificate alone produces a `.p12` that imports cleanly and then fails
   to sign.
3. Set them:
   ```sh
   base64 -i AppleDistribution.p12 | gh secret set APPSTORE_CERTIFICATES_FILE_BASE64
   gh secret set APPSTORE_CERTIFICATES_PASSWORD
   gh secret set APPSTORE_API_PRIVATE_KEY < AuthKey_XXXXXX.p8
   gh variable set APPSTORE_ISSUER_ID
   gh variable set APPSTORE_API_KEY_ID
   ```

This repo is public. Secrets are unavailable to fork PRs by design, and the
signing steps live only in `release.yml`, which runs on tag pushes — never in
`pr-checks.yml`.

### The archive and the export sign differently

- **Archive** — automatic (`-allowProvisioningUpdates` + the API key),
  matching `project.yml`'s `CODE_SIGN_STYLE: Automatic`.
- **Export** — *manual*, against a named provisioning profile, needing no
  credentials at all.

Automatic export was tried first and does not work. At export time it asks
Apple to mint the provisioning profile via cloud signing, which fails:

```
error: exportArchive Cloud signing permission error
```

— even with an Admin-role API key. Only the export needs a profile, which is
why the archive succeeds and the export doesn't. Naming an existing profile
sidesteps the cloud-signing path entirely.

`apple-actions/xcodebuild` was also evaluated and rejected: it passes
`extra-arguments` to the archive only, building its export argument list from
scratch, so signing flags can never reach the export.

### ⚠️ The provisioning profile is a maintained artifact

`Dionysus App Store` (type `IOS_APP_STORE`, bundle ID
`com.imbenjamin.dionysusplayer`) must exist in App Store Connect, and
`Config/ExportOptions.plist` names it **by name, exactly**.
`apple-actions/download-provisioning-profiles` installs it on the runner
before the export.

Two ways this breaks, neither of which the pipeline warns about in advance:

- **The profile is renamed or deleted.** The export fails with "doesn't
  include signing certificate" or a no-matching-profile error. Recreate it
  under the same name.
- **It expires** — profiles are tied to the signing certificate's lifetime,
  so this one expires with the cert (see below). Regenerate it, and make sure
  the new one keeps the name.

Recreate it from the developer portal (Certificates, Identifiers & Profiles →
Profiles → + → App Store Connect), or via the API:

```
POST /v1/profiles
  attributes: { name: "Dionysus App Store", profileType: "IOS_APP_STORE" }
  relationships: { bundleId: <bundle id>, certificates: [<distribution cert>] }
```

### ⚠️ Both credentials expire

The distribution certificate and the profile that depends on it both expire
**2027-08-30**. Nothing warns beforehand; a release simply fails at the
archive or export step with a signing error that doesn't obviously say
"expired". Renew the certificate, re-export the `.p12`, update
`APPSTORE_CERTIFICATES_FILE_BASE64`, and regenerate the profile under the
same name.

## How the version gets into the app

`Scripts/update-version.sh` is the single source of truth's consumer. It
takes no arguments: it derives the version from the latest reachable `v*` tag
plus git's current commit count/hash. `release.yml` runs it right before a
tagged build, where the tag already exists (it's what triggered the run), so
the values it reads are facts rather than predictions. It regenerates two
checked-in files:

- `Config/Version.xcconfig` — `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`
  (always the clean `X.Y.Z` + commit count, never a prerelease suffix).
- `DionysusPlayer/Shared/AppVersion.swift` — the full SemVer string
  (`AppVersion.full`), read by `AppVersionInfo` for the Profile screen
  footer. Off-tag (mid-development, ahead of the last tag) it appends
  SemVer build metadata, e.g. `1.2.0-alpha.1+7.gabc1234`, rather than
  lying about being exactly the tagged version; a dirty working tree adds
  `.dirty` too.

This is a **companion script, not a build-time hook**. See
`Scripts/update-version.sh`'s own header comment for why: an earlier
attempt at the equivalent (stamping git branch/commit into the *built*
Info.plist via a `postCompileScripts` phase) turned out to run at the
wrong point in Xcode's build graph and silently never took effect. A
checked-in generated file sidesteps that class of bug entirely, following
the same pattern already used for `AetherEngineVersion.swift`
(`Scripts/update-aetherengine-version.sh`).

CI's run is what makes the *shipped* build's version correct, and it is not
checked against what's committed. The checked-in copies are a convenience for
local builds and are expected to lag between releases — see "Why there is no
longer a release-prep PR" above for why that coupling was removed.

It's deliberately *not* wired into a prebuild script that runs on every
local build, either — the output (build number, commit hash) would change
on nearly every commit, turning two committed files into permanent
working-tree noise for no benefit to Debug builds, where the version
string isn't user-visible anyway.

## GitHub Actions

- **`.github/workflows/pr-checks.yml`** — the PR gate, on every PR into `stable`
  or `develop`: sets up the project, regenerates and **verifies**
  `AetherEngineVersion.swift` against a genuinely fresh package resolution,
  then builds and runs the full test suite. This is the only place AetherEngine
  drift is enforced, and it's a required status check on both branches.

  ⚠️ Its job is named `Build and Test default scheme using any available
  iPhone simulator`, and both branch rulesets require that exact string.
  GitHub keys required checks on the **job** name, not the workflow name or
  filename — renaming the job without updating both rulesets first makes every
  PR hang on a check that never reports.

- **`.github/workflows/release.yml`** — runs on any `v*.*.*` tag push: sets up
  the project, stamps the version from that tag via `Scripts/update-version.sh`,
  **regenerates** `AetherEngineVersion.swift`, builds and tests the exact
  tagged commit, archives and signs it, uploads it to App Store Connect, and
  publishes a GitHub Release with the tag's own message above GitHub's
  generated notes (`--prerelease` for `-alpha`/`-beta` tags and for any `0.x`
  version). It also refuses a tag on the wrong branch — see "Final releases
  come from `stable`" above. A `workflow_dispatch` input re-runs a release for
  an existing tag without re-tagging, for recovering from an infrastructure
  failure partway through.

- **`.github/workflows/promote-to-stable.yml`** — `workflow_dispatch` only:
  opens (or finds) the `develop` → `stable` PR that a final release is tagged
  from. Never merges; see that file's header for why.

The two treat AetherEngine drift deliberately differently. `pr-checks.yml`
*verifies* — drift is actionable there, days after it happens upstream.
`release.yml` *regenerates* — a version published upstream between the last PR
and the tag must never fail a tag that has already been pushed, which is
exactly what cost three CI runs and two recovery branches on `v0.7.0-alpha.1`.

Both share `.github/actions/setup-ios-project` and
`.github/actions/build-and-test`, so their build/test behaviour cannot drift
apart; they previously carried byte-identical copies of those steps.

Code signing, archiving and TestFlight upload live in `release.yml` only, and
need the credentials in "Signing setup" above. Submitting a build for Beta App
Review and assigning it to a tester group remain manual in the App Store
Connect UI — deliberately, since neither is a per-release decision worth
automating yet. App Store submission (metadata, screenshots) is not automated
at all.
