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
set -e
cd "$(dirname "$0")/.."

RESOLVED="DionysusPlayer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ ! -f "$RESOLVED" ]; then
  echo "error: $RESOLVED not found — run 'xcodegen generate' and let Xcode/xcodebuild resolve packages at least once first." >&2
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
