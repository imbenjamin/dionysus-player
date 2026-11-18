#!/bin/bash
# Passes when every part of a split UI-test plan recorded a pass.
#
#   check-part-results.sh <folder> <part count>
#
# ui-tests.yml's parts each leave a file `part-<n>` holding their job's
# status ("success", "failure" or "cancelled"), and the per-environment
# result jobs download them into <folder>. A part with no file never got as
# far as recording one (its runner was lost, or it never started), which
# fails too: the check must never pass on fewer parts than it was split into.
set -u

folder=${1:?usage: check-part-results.sh <folder> <part count>}
count=${2:?usage: check-part-results.sh <folder> <part count>}

failed=0
for part in $(seq 1 "$count"); do
  file="$folder/part-$part"
  if [ -f "$file" ]; then
    status=$(tr -d '[:space:]' < "$file")
  else
    status="no result"
  fi
  echo "Part $part of $count: $status"
  [ "$status" = success ] || failed=1
done

if [ "$failed" -ne 0 ]; then
  echo "::error::Not every part of this environment's plan passed; see the parts' own jobs."
fi
exit "$failed"
