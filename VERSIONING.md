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
- **Final `vX.Y.Z` tags (no suffix) are cut from `main`**, after merging
  `develop` into `main`. The final release is either exactly the approved
  prerelease commit, or that commit plus any last fixes found during
  prerelease testing — either way, `main` only ever moves forward via a
  `develop → main` merge (see `CLAUDE.md`'s note that `main` is
  release-only and lags behind `develop`).
- Bump rules are the usual SemVer judgment call: PATCH for fixes only,
  MINOR for backward-compatible features, MAJOR for breaking changes/major
  redesigns.
- The first tag is `v0.1.0-alpha.1`.

## Day-to-day: cutting a tag

Stamp the version *before* the tag exists, as a normal small PR, then tag
the already-correct merge commit — this way the tag never needs a
follow-up "stamp version"/"bump AetherEngine display" commit after the
fact:

```sh
git checkout develop && git pull
git checkout -b release/v1.2.0-alpha.1
./Scripts/update-version.sh v1.2.0-alpha.1
./Scripts/update-aetherengine-version.sh   # only if this has drifted — see below
git commit -am "Prepare release v1.2.0-alpha.1"
gh pr create --base develop --title "Prepare release v1.2.0-alpha.1" --fill
# merge once the required check passes, same as any other PR, then:
git checkout develop && git pull
git tag -a v1.2.0-alpha.1 -m "1.2.0-alpha.1"
git push origin v1.2.0-alpha.1
```

Pushing the tag triggers `.github/workflows/release.yml`, which builds,
tests, and publishes a GitHub Release for that exact commit — marked
"prerelease" automatically when the tag contains `-alpha` or `-beta`. It
also re-verifies the generated files (see "How the version gets into the
app" below) and fails the build if they don't match what's checked in —
catching a skipped prep step or a package resolution that drifted in the
gap, rather than shipping a stale version display silently. Successive
builds at the same core version bump the trailing number:
`v1.2.0-alpha.2`, `v1.2.0-alpha.3`, ... then `v1.2.0-beta.1`, ... then,
once approved and merged to `main`, `v1.2.0` — same prep-PR-then-tag flow,
just based off `main` instead of `develop`.

`./Scripts/update-aetherengine-version.sh` only needs running in the prep
PR when `Package.resolved`'s `aetherengine` pin has actually moved since
the last release (check with `git diff` after running it — it's a no-op
otherwise); the release workflow's own verification step will catch it if
you forget and a resolution drifted.

### Release notes

CI publishes the release with `gh release create --generate-notes`, which
is just an auto-generated "What's Changed" PR list — accurate but not
something a human tester wants to read first. Once the workflow finishes,
edit the release to prepend a short, plain-language summary above that
list before treating the release as done:

```sh
gh release view vX.Y.Z-alpha.N --json body --jq '.body'   # grab the auto-generated notes
# write summary + the existing body to a file, then:
gh release edit vX.Y.Z-alpha.N --notes-file notes.md
```

The summary is a few bullet points aimed at whoever's actually installing
the build (an internal tester, not a future contributor reading `git log`):
what changed from a user's perspective, in plain language — no internal
type/file names, no implementation detail. Skip bullets for pure
chores/CI fixes that a user wouldn't notice; call out real features/fixes
only. End with a one-line "still an early alpha, expect rough edges"
disclaimer while prerelease. Established with `v0.1.0-alpha.2`'s notes —
use those as the template.

## How the version gets into the app

`Scripts/update-version.sh` is the single source of truth's consumer. Given
an explicit tag argument (`./Scripts/update-version.sh v1.2.0-alpha.1`) —
the normal path, run on a release-prep branch *before* that tag exists —
it stamps exactly that version. With no argument, it instead derives the
version from the latest reachable `v*` tag plus git's current commit
count/hash — used only by CI (see below), where the tag already exists by
the time the workflow runs. Either way it regenerates the same two checked-in files:

- `Config/Version.xcconfig` — `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`
  (always the clean `X.Y.Z` + commit count, never a prerelease suffix).
- `DionysusPlayer/Shared/AppVersion.swift` — the full SemVer string
  (`AppVersion.full`), read by `AppVersionInfo` for the Profile screen
  footer. Off-tag (mid-development, ahead of the last tag) it appends
  SemVer build metadata, e.g. `1.2.0-alpha.1+7.gabc1234`, rather than
  lying about being exactly the tagged version; a dirty working tree adds
  `.dirty` too.

This is a **companion script you run explicitly** (locally on a
release-prep branch before cutting a tag, or automatically in CI right
before a tagged build) — not a build-time hook. See
`Scripts/update-version.sh`'s own header comment for why: an earlier
attempt at the equivalent (stamping git branch/commit into the *built*
Info.plist via a `postCompileScripts` phase) turned out to run at the
wrong point in Xcode's build graph and silently never took effect. A
checked-in generated file sidesteps that class of bug entirely, following
the same pattern already used for `AetherEngineVersion.swift`
(`Scripts/update-aetherengine-version.sh`). CI's own run (no argument, see
above) exists only to make the tagged build's `MARKETING_VERSION` correct
and is immediately followed by a verification step
(`release.yml`'s "Verify nothing was left uncommitted for this release")
that fails the build if it doesn't match what's already checked in — it's
a safety net, not the mechanism by which the repo's files get updated.

It's deliberately *not* wired into a prebuild script that runs on every
local build, either — the output (build number, commit hash) would change
on nearly every commit, turning two committed files into permanent
working-tree noise for no benefit to Debug builds, where the version
string isn't user-visible anyway.

## GitHub Actions

- **`.github/workflows/ios.yml`** — runs on every push/PR to `main` or
  `develop`: generates the Xcode project, builds, and runs the full test
  suite. This is the PR gate — set it as a required status check in this
  repo's branch protection rules for `main` and `develop` if not already.
- **`.github/workflows/release.yml`** — runs on any `v*.*.*` tag push:
  regenerates the project, stamps the version from that tag via
  `Scripts/update-version.sh`, builds and tests the exact tagged commit,
  regenerates `AetherEngineVersion.swift` and verifies none of the three
  generated files differ from what's checked in (failing the build if they
  do), then publishes a GitHub Release (`--prerelease` for `-alpha`/`-beta`
  tags).

Neither workflow does code signing, archiving, or TestFlight/App Store
upload yet — that needs an App Store Connect API key as a repo secret and
is a deliberate follow-up, not part of this pass.
