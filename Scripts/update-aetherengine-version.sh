#!/bin/sh
# Regenerates DionysusPlayer/Core/Playback/AetherEngineVersion.swift from
# whatever AetherEngine version is actually pinned in the *checked-in*
# Package.resolved lock file (see that file's own comment for why it's
# checked in, unlike the rest of `.xcodeproj`).
#
# Why a checked-in generated Swift file rather than stamping the version
# into the built Info.plist at build time (the same trick this project
# already uses for GitBranch/GitCommitHash — see project.yml's
# postCompileScripts entry): that approach was tried for this too
# (2026-08-12) and doesn't actually work under the current Xcode/build
# system combination — a script phase with no declared outputs gets
# scheduled to run *before* Xcode's own Info.plist processing regardless of
# its position in the build phase list, so its writes get silently
# overwritten; the fixes for that (declaring the Info.plist as an output,
# or as an input) either collide with Xcode's own declared producer of that
# same file ("Multiple commands produce...") or create a dependency cycle
# back through storyboard compilation. Rather than depend on a fragile
# build-time mechanism, this script is a companion to `xcodegen generate` —
# run it (from the repo root) whenever `Package.resolved` changes (a fresh
# `AetherEngine` resolution, a manual "Update to Latest Package Versions"
# in Xcode, or a `project.yml` `packages:` bump) so the checked-in Swift
# constant stays truthful. `PlaybackStatsOverlay`'s "AetherEngine Version"
# row reads it directly — nothing to remember to hand-edit there.
#
# This is also part of the release-prep flow in VERSIONING.md: run it on a
# release-prep branch alongside `Scripts/update-version.sh` if
# `Package.resolved` has drifted since the last release, so the tag being
# cut is already correct. `.github/workflows/release.yml` re-runs it during
# the tagged build too, purely as a safety net — it fails the release if
# that turns up a diff against what's checked in, rather than committing
# anything itself.
#
# Always forces a genuinely fresh resolution rather than trusting whatever
# happens to already be resolved locally — an already-resolved checkout
# won't re-resolve a floating `from:` requirement on its own even when a
# newer version exists upstream (SPM's local package-repository cache just
# keeps serving the tag list it last saw), so a stale local run of this
# script can silently report last month's version while a genuinely fresh
# resolution (which is all CI ever does, since it's always a clean
# checkout) finds something newer. Confirmed live (2026-08-28): a local run
# reported 6.42.0 with no diff to commit, while `release.yml`'s safety net
# on the very same commit caught 6.52.0 — costing a wasted release cut.
# Clearing SPM's caches and re-resolving here is what makes this script's
# output as trustworthy as CI's from now on, at the cost of this always
# taking a few seconds longer (a real network resolution, not a cache hit)
# and always touching the untracked `Package.resolved` even when nothing
# upstream actually changed.
set -e
cd "$(dirname "$0")/.."

if [ ! -d "DionysusPlayer.xcodeproj" ]; then
  echo "error: DionysusPlayer.xcodeproj not found — run 'xcodegen generate' first." >&2
  exit 1
fi

RESOLVED="DionysusPlayer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
rm -rf ~/Library/Caches/org.swift.swiftpm ~/Library/org.swift.swiftpm
rm -f "$RESOLVED"
echo "Resolving packages fresh (no cache) — this talks to the network..."
xcodebuild -resolvePackageDependencies -project DionysusPlayer.xcodeproj -scheme DionysusPlayer >/dev/null

if [ ! -f "$RESOLVED" ]; then
  echo "error: $RESOLVED not found after a fresh resolution — check for xcodebuild errors above (network access, an invalid pin, etc.)." >&2
  exit 1
fi

VERSION=$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next((p["state"].get("version","unknown") for p in d.get("pins",[]) if p.get("identity")=="aetherengine"), "unknown"))' "$RESOLVED")

if [ "$VERSION" = "unknown" ]; then
  echo "error: couldn't find an 'aetherengine' pin in $RESOLVED" >&2
  exit 1
fi

OUT="DionysusPlayer/Core/Playback/AetherEngineVersion.swift"
cat > "$OUT" <<EOF
// GENERATED FILE — do not edit by hand.
// Regenerate with \`Scripts/update-aetherengine-version.sh\` (run whenever
// \`Package.resolved\`'s \`aetherengine\` pin changes) — see that script's own
// comment for why this is a checked-in generated constant rather than a
// build-time Info.plist injection.

/// The AetherEngine version actually pinned in \`Package.resolved\` as of the
/// last \`Scripts/update-aetherengine-version.sh\` run — read by
/// \`PlaybackStatsOverlay\`'s "AetherEngine Version" row. AetherEngine
/// exposes no runtime version API of its own (checked — nothing on
/// \`AetherEngine\` reports it), so this is the only source of truth for it.
enum AetherEngineVersion {
    static let current = "$VERSION"
}
EOF

echo "Wrote $OUT: AetherEngine $VERSION"
