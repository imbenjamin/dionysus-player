#!/usr/bin/env bash
# Checks the App Review server (docs/store/review-server.md) is safe to hand
# to a reviewer: set up, one visible user who can't administer or delete, and
# a library of only the Creative Commons titles, with no online metadata.
#
#   Scripts/review-server/check.sh <base-url>   (REVIEW_PASSWORD optional; see below)
#
# Read-only apart from signing in (and the DELETE it expects to be refused).
# Exits 0 when every check passes, 1 at the first that fails.
set -euo pipefail

BASE="${1:?usage: $0 <base-url>}"
BASE="${BASE%/}"
# The password comes from REVIEW_PASSWORD or, failing that, the login keychain
# (security add-generic-password -s dionysus-review -a reviewer -w).
if [[ -z "${REVIEW_PASSWORD:-}" ]]; then
  REVIEW_PASSWORD="$(security find-generic-password -s dionysus-review -a "${REVIEW_USER:-reviewer}" -w 2>/dev/null)" \
    || { echo "set REVIEW_PASSWORD, or add the reviewer password to the keychain (service dionysus-review)" >&2; exit 2; }
fi
REVIEW_USER="${REVIEW_USER:-reviewer}"
EXPECTED_TITLES=9   # 7 films + 2 Caminandes episodes

AUTH='MediaBrowser Client="review-check", Device="check.sh", DeviceId="review-check-sh", Version="1"'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

# get <path> [token] → body in $TMP/body, status echoed
req() {
  local method="$1" path="$2" token="${3:-}" header="$AUTH"
  [[ -n "$token" ]] && header="$AUTH, Token=\"$token\""
  curl -s -m 20 -o "$TMP/body" -w '%{http_code}' -X "$method" \
    -H "Authorization: $header" -H 'Content-Type: application/json' \
    ${4:+--data-binary "@$4"} "$BASE$path" || echo 000
}

# 1. Set up
[[ "$(req GET /System/Info/Public)" == 200 ]] || fail "/System/Info/Public doesn't answer 200"
[[ "$(jq -r .StartupWizardCompleted "$TMP/body")" == true ]] || fail "StartupWizardCompleted is not true"
version="$(jq -r .Version "$TMP/body")"
pass "server answers, startup wizard completed ($version)"

# 2. Exactly one visible user
[[ "$(req GET /Users/Public)" == 200 ]] || fail "/Users/Public doesn't answer 200"
users="$(jq -r '[.[].Name] | join(",")' "$TMP/body")"
[[ "$users" == "$REVIEW_USER" ]] || fail "public users are '$users', expected only '$REVIEW_USER'"
pass "the only public user is $REVIEW_USER"

# 3. Reviewer signs in, with a reviewer's policy
jq -n --arg u "$REVIEW_USER" --arg p "$REVIEW_PASSWORD" '{Username:$u, Pw:$p}' > "$TMP/login.json"
[[ "$(req POST /Users/AuthenticateByName "" "$TMP/login.json")" == 200 ]] || fail "signing in as $REVIEW_USER failed"
rm -f "$TMP/login.json"
TOKEN="$(jq -r .AccessToken "$TMP/body")"
USER_ID="$(jq -r .User.Id "$TMP/body")"
policy_ok="$(jq -r '.User.Policy |
  .IsAdministrator == false and .EnableContentDeletion == false and
  (.EnableContentDeletionFromFolders | length) == 0 and
  .EnableRemoteControlOfOtherUsers == false and .EnableLiveTvAccess == false and
  .EnableLiveTvManagement == false and .EnableMediaPlayback == true and
  .EnableVideoPlaybackTranscoding == true and .EnableContentDownloading == true and
  .EnablePublicSharing == false and .SyncPlayAccess == "None" and
  .EnableSharedDeviceControl == false and
  .IsHidden == false and .IsDisabled == false' "$TMP/body")"
if [[ "$policy_ok" != true ]]; then
  policy="$(jq -c '.User.Policy | {IsAdministrator, EnableContentDeletion, EnableContentDeletionFromFolders, EnableRemoteControlOfOtherUsers, EnableLiveTvAccess, EnableLiveTvManagement, EnableMediaPlayback, EnableVideoPlaybackTranscoding, EnableContentDownloading, EnablePublicSharing, SyncPlayAccess, EnableSharedDeviceControl, IsHidden, IsDisabled}' "$TMP/body")"
  fail "$REVIEW_USER's policy isn't the reviewer policy: $policy"
fi
pass "$REVIEW_USER signs in; not an administrator, can't delete, can play, transcode and download"

# 4. Admin-only endpoints refuse the reviewer (any signed-in user may *read*
#    /System/Configuration in Jellyfin, so it proves nothing)
for path in /System/Logs /Library/VirtualFolders /Users/$USER_ID/Policy; do
  method=GET; [[ "$path" == */Policy ]] && method=POST
  code="$(req "$method" "$path" "$TOKEN")"
  [[ "$code" == 401 || "$code" == 403 ]] || fail "$method $path as $REVIEW_USER answered $code, expected 401 or 403"
done
pass "admin endpoints are refused to $REVIEW_USER"

# 5. The library: only the expected titles, each attributed, none with online metadata
fields='Overview,ProviderIds,Path'
[[ "$(req GET "/Items?userId=$USER_ID&Recursive=true&IncludeItemTypes=Movie,Episode&Fields=$fields" "$TOKEN")" == 200 ]] \
  || fail "listing the library failed"
cp "$TMP/body" "$TMP/items.json"
count="$(jq '.Items | length' "$TMP/items.json")"
names="$(jq -r '[.Items[].Name] | join(", ")' "$TMP/items.json")"
[[ "$count" == "$EXPECTED_TITLES" ]] || fail "library has $count titles, expected $EXPECTED_TITLES: $names"
unattributed="$(jq -r '[.Items[] | select((.Overview // "") | test("CC BY|Creative Commons Attribution") | not) | .Name] | join(", ")' "$TMP/items.json")"
[[ -z "$unattributed" ]] || fail "no Creative Commons attribution in the overview of: $unattributed"
online="$(jq -r '[.Items[] | select((.ProviderIds // {}) | length > 0) | "\(.Name) \(.ProviderIds)"] | join("; ")' "$TMP/items.json")"
[[ -z "$online" ]] || fail "titles carry online provider ids: $online"
rated="$(jq -r '[.Items[] | select(.CommunityRating != null) | .Name] | join(", ")' "$TMP/items.json")"
[[ -z "$rated" ]] || fail "titles carry a community rating (online metadata): $rated"
pass "$count titles, each attributed, none with online metadata"

# 6. Series and seasons too: no online ids
[[ "$(req GET "/Items?userId=$USER_ID&Recursive=true&IncludeItemTypes=Series,Season&Fields=ProviderIds" "$TOKEN")" == 200 ]] \
  || fail "listing series failed"
online="$(jq -r '[.Items[] | select((.ProviderIds // {}) | length > 0) | "\(.Name) \(.ProviderIds)"] | join("; ")' "$TMP/body")"
[[ -z "$online" ]] || fail "series or seasons carry online provider ids: $online"
pass "series and seasons carry no online metadata"

# 7. People and studios: no online ids or images (they refresh from server-wide
#    options, not the library's)
for kind in Persons Studios; do
  [[ "$(req GET "/$kind?userId=$USER_ID&Fields=ProviderIds" "$TOKEN")" == 200 ]] || fail "listing $kind failed"
  online="$(jq -r '[.Items[] | select(((.ProviderIds // {}) | length > 0) or ((.ImageTags // {}) | length > 0)) | .Name] | join(", ")' "$TMP/body")"
  [[ -z "$online" ]] || fail "$kind with online ids or images: $online"
done
pass "people and studios carry no online ids or images"

# 8. Deleting is refused
item="$(jq -r '.Items[0].Id' "$TMP/items.json")"
code="$(req DELETE "/Items/$item" "$TOKEN")"
[[ "$code" == 401 || "$code" == 403 ]] || fail "DELETE /Items/$item as $REVIEW_USER answered $code, expected 401 or 403"
pass "deleting an item is refused to $REVIEW_USER ($code)"

# Sign the check's own session out, so sessions don't pile up
req POST /Sessions/Logout "$TOKEN" >/dev/null || true
echo "All checks passed."
