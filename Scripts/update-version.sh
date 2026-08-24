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
# Run this:
#   - on a release-prep branch, with the intended tag name as an explicit
#     argument (`./Scripts/update-version.sh v1.2.0-alpha.3`), *before* that
#     tag exists — see VERSIONING.md's "Day-to-day: cutting a tag" section.
#     This is the normal path now: stamp on a branch, PR it in like any
#     other change, merge, *then* tag the already-correct merge commit — so
#     nothing needs fixing up after the tag is pushed.
#   - with no argument, to derive the version from the latest reachable
#     `v*` tag instead — used automatically in CI
#     (.github/workflows/release.yml) right before building a tagged
#     release, purely to make that build's MARKETING_VERSION correct (the
#     tag already exists by then, having been pushed to trigger the
#     workflow).
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

EXPLICIT_TAG="${1:-}"
if [ -n "$EXPLICIT_TAG" ]; then
  # Release-prep mode: the caller is telling us what tag this commit is
  # *about to become* (it doesn't exist yet, so `git describe` can't see
  # it) — stamp as if already exactly on that tag, same as the "clean,
  # zero commits since the tag" case below.
  #
  # BUILD_NUMBER (a plain count) is knowable in advance — the commit this
  # script's output is about to be committed into will be one past HEAD's
  # current count, so add 1 rather than using today's count. Skipping this
  # would leave the checked-in build number permanently one behind the
  # count CI computes once that commit and its tag actually exist (see
  # release.yml's verification step, which caught exactly this).
  #
  # COMMIT's short SHA is *not* knowable in advance, though — a commit
  # can't contain its own hash, only its parent's — so this stays whatever
  # HEAD is right now (the commit this release was prepared from, one
  # behind the eventual tag). release.yml's verification step knows to
  # excuse exactly this field for exactly this reason.
  BUILD_NUMBER=$(($(git rev-list --count HEAD) + 1))
  LATEST_TAG="$EXPLICIT_TAG"
  SINCE_TAG="0"
else
  BUILD_NUMBER=$(git rev-list --count HEAD)
  LATEST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
fi

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
  if [ -z "$EXPLICIT_TAG" ]; then
    # Only recompute from git when LATEST_TAG came from `git describe` — an
    # explicit tag argument doesn't exist as a ref yet, so `rev-list` can't
    # resolve it, and SINCE_TAG is already "0" from the branch above.
    SINCE_TAG=$(git rev-list "${LATEST_TAG}..HEAD" --count)
  fi
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
