#!/bin/bash
# Usage: Scripts/verify-ready-to-tag.sh vX.Y.Z[-alpha.N]
#
# Needs bash, not /bin/sh (unlike this repo's other Scripts/*.sh) — the
# process-substitution diff below (`<(...)`) is a bash extension, not
# POSIX sh; macOS's /bin/sh runs bash in POSIX mode, which rejects it.
#
# Confirms the current HEAD is actually ready to be tagged as the given
# version — i.e. that Scripts/update-version.sh's *on-tag* output (the
# same thing release.yml computes once the real tag exists and is pushed)
# matches what's already checked in. Run this immediately before `git tag`
# in VERSIONING.md's release flow, as the last step before tagging.
#
# Why this exists: `update-version.sh <tag>`'s release-prep mode predicts
# the build number as current commit count + 2 (this prep commit, plus the
# merge commit `gh pr merge --merge` always fabricates) — correct for an
# *isolated* release-prep PR, but it can't predict a second, unplanned PR
# landing on develop between that stamp and the actual tag push. That's
# exactly what happened live cutting v0.7.0-alpha.1 (2026-08-28): an
# AetherEngine-version fix PR merged in between, adding 2 more commits the
# original stamp never accounted for — caught by release.yml's safety net,
# but only after an ~8 minute wasted CI round-trip. This script catches
# the same mismatch locally in seconds, before the tag is ever pushed.
#
# How: creates the tag *locally only* so update-version.sh's no-argument
# mode can compute the real on-tag values via `git describe` (the exact
# code path release.yml itself uses once the tag exists), diffs the result
# against the checked-in files, then always removes the local tag again —
# safe to run repeatedly, and has no effect on success or failure either
# way (Config/Version.xcconfig and AppVersion.swift are restored from HEAD
# before this script exits, regardless of outcome).
set -e
cd "$(dirname "$0")/.."

TAG="${1:?usage: $0 vX.Y.Z[-alpha.N]}"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree isn't clean — commit or stash before verifying." >&2
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: a tag named $TAG already exists locally — delete it first (git tag -d $TAG) if you're re-verifying after a fix." >&2
  exit 1
fi

git tag "$TAG"
cleanup() {
  git tag -d "$TAG" >/dev/null 2>&1 || true
  git checkout -- Config/Version.xcconfig DionysusPlayer/Shared/AppVersion.swift 2>/dev/null || true
}
trap cleanup EXIT

./Scripts/update-version.sh >/dev/null

fail=0
if ! git diff --exit-code -- Config/Version.xcconfig; then
  fail=1
fi
# `commit` is excused, same as release.yml's own check: HEAD is later than
# whatever the release-prep branch's stamp could have recorded (it can
# only ever record its own commit's *parent*), so this field is expected
# to differ and isn't itself a sign anything is wrong.
if ! diff \
  <(git show "HEAD:DionysusPlayer/Shared/AppVersion.swift" | grep -v 'static let commit') \
  <(grep -v 'static let commit' DionysusPlayer/Shared/AppVersion.swift)
then
  fail=1
fi

if [ "$fail" = "1" ]; then
  echo "::error::HEAD is NOT ready to be tagged $TAG — generated version files would differ from what release.yml will compute. Something merged to develop since the release-prep branch was stamped. Re-run the release-prep flow (Scripts/update-version.sh $TAG on a fresh branch, PR it, merge) before tagging." >&2
  exit 1
fi

echo "HEAD is ready to be tagged $TAG."
