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
the exact tagged commit, and publishes a GitHub Release — marked
"prerelease" automatically when the tag contains `-alpha` or `-beta`.

**Write the tag message as real release notes.** It isn't just a label — see
"Release notes" below.

Successive builds at the same core version bump the trailing number:
`v1.2.0-alpha.2`, `v1.2.0-alpha.3`, ... then `v1.2.0-beta.1`, ... then, once
approved and merged to `main`, `v1.2.0` — same one-command flow, just based
off `main` instead of `develop`.

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

- **`.github/workflows/pr-checks.yml`** — the PR gate, on every PR into `main`
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
  tagged commit, then publishes a GitHub Release with the tag's own message
  above GitHub's generated notes (`--prerelease` for `-alpha`/`-beta` tags and
  for any `0.x` version).

The two treat AetherEngine drift deliberately differently. `pr-checks.yml`
*verifies* — drift is actionable there, days after it happens upstream.
`release.yml` *regenerates* — a version published upstream between the last PR
and the tag must never fail a tag that has already been pushed, which is
exactly what cost three CI runs and two recovery branches on `v0.7.0-alpha.1`.

Both share `.github/actions/setup-ios-project` and
`.github/actions/build-and-test`, so their build/test behaviour cannot drift
apart; they previously carried byte-identical copies of those steps.

Neither workflow does code signing, archiving, or TestFlight/App Store
upload yet — that needs an App Store Connect API key as a repo secret and
is a deliberate follow-up, not part of this pass.
