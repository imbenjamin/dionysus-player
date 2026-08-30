#!/bin/sh
# Regenerates the two checked-in version artifacts from git — the single
# source of truth is the latest reachable annotated tag matching `v*`
# (see VERSIONING.md for the tagging convention: `v1.2.3`, `v1.2.3-alpha.4`,
# `v2.0.0-beta.1`).
#
# Two outputs, because Apple and everyone else want different things:
#
#   - Config/Version.xcconfig sets MARKETING_VERSION/CURRENT_PROJECT_VERSION
#     (-> CFBundleShortVersionString/CFBundleVersion). Apple requires these
#     to be plain dot-separated integers with no prerelease suffix, so this
#     is always just the tag's core "X.Y.Z" plus a monotonic build number
#     (total commit count) — never the full SemVer string.
#   - DionysusPlayer/Shared/AppVersion.swift carries the full human-facing
#     SemVer (prerelease suffix and, off-tag, build metadata included) for
#     in-app display (see AppVersionInfo.swift / the Profile screen
#     footer).
#
# This is a companion script, not a build-time hook — same reasoning as
# `Scripts/update-aetherengine-version.sh`: an earlier attempt at stamping
# per-build info (git branch/commit) into the *built* Info.plist via a
# postCompileScripts phase turned out to run at the wrong point in Xcode's
# build graph and never actually took effect (see that script's comment,
# and project.yml's git history, for the full story). A checked-in
# generated file refreshed by an explicit script run sidesteps that
# entirely, at the cost of needing to remember to run it.
#
# Takes no arguments: the version is always derived from the latest reachable
# `v*` tag. .github/workflows/release.yml runs this right before building a
# tagged release, at a point where that tag demonstrably exists (it's what
# triggered the run), so `git describe` resolves it and `git rev-list --count`
# is the real commit count.
#
# It used to also accept an explicit tag argument, for stamping on a
# release-prep branch *before* that tag existed. That mode had to *predict*
# the build number as "current count + 2" (the prep commit, plus the merge
# commit `gh pr merge --merge` always fabricates), and the prediction broke
# live three times — twice on the +1-vs-+2 arithmetic itself (#123, #132), and
# once when an unrelated PR landed on develop between the stamp and the tag
# (v0.7.0-alpha.1). It's gone, along with the prep branch and
# verify-ready-to-tag.sh that existed to police it. Don't reintroduce a mode
# that guesses at a number CI can simply read.
#
# Run it by hand any time you want the checked-in files to reflect the current
# tag; between releases they're expected to lag, and the off-tag build metadata
# below (`+<distance>.g<sha>`) says so honestly rather than claiming to be the
# tagged version.
#
# It's deliberately *not* wired into a build phase that runs on every local
# build — the output would change (build number, commit hash) on nearly
# every commit, turning two committed files into permanent working-tree
# noise for no benefit to Debug builds.
set -e
cd "$(dirname "$0")/.."

COMMIT=$(git rev-parse --short HEAD)

DIRTY=""
if ! git diff --quiet || ! git diff --cached --quiet; then
  DIRTY=".dirty"
fi

BUILD_NUMBER=$(git rev-list --count HEAD)
LATEST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)

if [ -z "$LATEST_TAG" ]; then
  # No `v*` tag reachable yet (e.g. before the first release is cut) — fall
  # back to an obviously-placeholder version rather than failing outright.
  CORE_VERSION="0.0.0"
  PRERELEASE=""
  SINCE_TAG="$BUILD_NUMBER"
else
  TAG_VERSION="${LATEST_TAG#v}"
  CORE_VERSION="${TAG_VERSION%%-*}"
  case "$TAG_VERSION" in
    *-*) PRERELEASE="${TAG_VERSION#*-}" ;;
    *) PRERELEASE="" ;;
  esac
  SINCE_TAG=$(git rev-list "${LATEST_TAG}..HEAD" --count)
fi

if [ -n "$LATEST_TAG" ] && [ "$SINCE_TAG" = "0" ] && [ -z "$DIRTY" ]; then
  # HEAD is exactly the tagged commit and the tree is clean — the full
  # version is exactly what the tag says, no build metadata needed.
  if [ -n "$PRERELEASE" ]; then
    FULL_VERSION="${CORE_VERSION}-${PRERELEASE}"
  else
    FULL_VERSION="${CORE_VERSION}"
  fi
else
  # Off-tag (or a dirty tree): append SemVer build metadata
  # (`+<distance>.g<commit>[.dirty]`) rather than lying about being exactly
  # the tagged version.
  META="${SINCE_TAG}.g${COMMIT}${DIRTY}"
  if [ -n "$PRERELEASE" ]; then
    FULL_VERSION="${CORE_VERSION}-${PRERELEASE}+${META}"
  else
    FULL_VERSION="${CORE_VERSION}+${META}"
  fi
fi

XCCONFIG="Config/Version.xcconfig"
mkdir -p "$(dirname "$XCCONFIG")"
cat > "$XCCONFIG" <<EOF
// GENERATED FILE — do not edit by hand.
// Regenerate with \`Scripts/update-version.sh\` — see that script's own
// comment and VERSIONING.md for the SemVer scheme this is derived from.
// This intentionally holds only the Apple-clean "X.Y.Z" + build number —
// see AppVersion.swift for the full human-facing SemVer string.
MARKETING_VERSION = $CORE_VERSION
CURRENT_PROJECT_VERSION = $BUILD_NUMBER
EOF

OUT="DionysusPlayer/Shared/AppVersion.swift"
cat > "$OUT" <<EOF
// GENERATED FILE — do not edit by hand.
// Regenerate with \`Scripts/update-version.sh\` (run whenever a version tag
// changes) — see that script's own comment and VERSIONING.md for the
// SemVer scheme this is derived from.

/// The full, human-facing SemVer for this build — always a valid SemVer
/// string, including \`+build.metadata\` when built off-tag. Distinct from
/// \`MARKETING_VERSION\`/\`CURRENT_PROJECT_VERSION\` (\`Config/Version.xcconfig\`),
/// which Apple requires to be plain dot-separated integers with no
/// prerelease suffix — this is the one source of truth those two are
/// mechanically derived from, but only this constant carries the full
/// string. Read by \`AppVersionInfo\` for the Profile screen footer.
enum AppVersion {
    static let full = "$FULL_VERSION"
    static let build = "$BUILD_NUMBER"
    static let commit = "$COMMIT"
}
EOF

echo "Wrote $XCCONFIG: MARKETING_VERSION=$CORE_VERSION CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
echo "Wrote $OUT: AppVersion.full=$FULL_VERSION"
