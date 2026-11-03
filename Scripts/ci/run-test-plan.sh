#!/bin/bash
# Runs one test plan on an already-built app: the build-and-test action's
# "Test" step, kept here so Scripts/ci/test_run_test_plan.py can run it
# against fake tools.
#
# If the test runner dies before running a test (xcodebuild_failure.py's
# signatures: a Simulator fault no test-level retry reaches), it reboots the
# Simulator, sets the Duo's pose again if there is one, and runs the plan
# once more, with a `::warning::` naming the signature. Never a third time:
# a genuine crash at launch reads the same as a runner fault, and must fail.
# Any other failure, and a second failure, exits with xcodebuild's status.
#
# Diagnostics collection is off: on a failure xcodebuild otherwise spends up
# to 10 minutes collecting a sysdiagnose from the Simulator, which nobody
# reads (TESTING.md, "Where they run in CI").
#
# Inputs, from the environment (the action's inputs of the same names):
#   SCHEME, PROJECT, TEST_PLAN, PLATFORM ("iOS" or "tvOS"), UDID,
#   RESULT_BUNDLE_PATH (attempt 2 writes "<name>-attempt-2.xcresult" beside
#   it), RETRY_TESTS_ON_FAILURE ("true"/"false"), RUN_TESTS_UNTIL_FAILURE
#   ("true"/"false"; xcodebuild refuses it together with the retry flag, so
#   both set is an error), TEST_ITERATIONS,
#   ONLY_TESTING (space-separated), DUO_POSE (empty, or a pose for
#   Scripts/duo-pose/set-duo-pose.sh).
# For the tests: LOG_DIR (default .build) and DUO_POSE_SCRIPT.
#
# Runs on macOS's /bin/bash 3.2: no `set -u` (an empty array is "unbound"
# there) and no waiting on process substitutions.
set -eo pipefail

for name in SCHEME PROJECT TEST_PLAN PLATFORM UDID RESULT_BUNDLE_PATH; do
  if [ -z "${!name}" ]; then
    echo "::error::run-test-plan.sh: $name is not set." >&2
    exit 2
  fi
done

if [ "$RETRY_TESTS_ON_FAILURE" = "true" ] && [ "$RUN_TESTS_UNTIL_FAILURE" = "true" ]; then
  echo "::error::run-test-plan.sh: RETRY_TESTS_ON_FAILURE and RUN_TESTS_UNTIL_FAILURE can't both be true." >&2
  exit 2
fi

here=$(cd "$(dirname "$0")" && pwd)
log_dir=${LOG_DIR:-.build}
pose_script=${DUO_POSE_SCRIPT:-$here/../duo-pose/set-duo-pose.sh}
mkdir -p "$log_dir"

args=(
  -scheme "$SCHEME"
  -project "$PROJECT"
  -testPlan "$TEST_PLAN"
  -destination "platform=$PLATFORM Simulator,id=$UDID"
  -collect-test-diagnostics never
  # The directory setup-ios-project caches; the build used it too, so this
  # run doesn't resolve the packages again.
  -clonedSourcePackagesDirPath .build/SourcePackages
)
if [ "$RETRY_TESTS_ON_FAILURE" = "true" ]; then
  args+=(-retry-tests-on-failure)
  if [ -n "$TEST_ITERATIONS" ]; then
    args+=(-test-iterations "$TEST_ITERATIONS")
  fi
fi
if [ "$RUN_TESTS_UNTIL_FAILURE" = "true" ]; then
  args+=(-run-tests-until-failure)
  if [ -n "$TEST_ITERATIONS" ]; then
    args+=(-test-iterations "$TEST_ITERATIONS")
  fi
fi
# Word-split on purpose: one identifier per word.
# shellcheck disable=SC2086
for test in $ONLY_TESTING; do
  args+=("-only-testing:$test")
done

# run_attempt <n> <result bundle>: xcodebuild's stdout goes through xcbeautify
# as before, and its stderr (where "Testing failed:" and the runner's error
# go, which xcbeautify would drop) straight to the job log as before. Both are
# also kept, raw, in $log_dir/test-attempt-<n>.log for the classifier: stdout
# first, then stderr. The descriptor swap keeps both pipelines ones bash
# waits for, and pipefail carries xcodebuild's status out of each.
run_attempt() {
  local log="$log_dir/test-attempt-$1.log"
  local err="$log_dir/test-attempt-$1.stderr.log"
  local status=0
  { xcodebuild test-without-building "${args[@]}" -resultBundlePath "$2" \
      2>&1 1>&3 3>&- | tee "$err" 3>&- >&2; } 3>&1 \
    | tee "$log" | xcbeautify --renderer github-actions || status=$?
  # A newline first: stdout may end mid-line, which would glue the stderr
  # log's first line onto it.
  echo >> "$log"
  cat "$err" >> "$log"
  return "$status"
}

classify() {
  python3 "$here/xcodebuild_failure.py" "$log_dir/test-attempt-$1.log" || echo test
}

# Polls instead of `timeout`, which macOS lacks.
wait_for_boot() {
  local limit=600 start=$SECONDS out="$log_dir/bootstatus.log" pid
  xcrun simctl bootstatus "$UDID" -b > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      kill "$pid" 2>/dev/null || true
      tail -n 20 "$out"
      return 1
    fi
    sleep 2
  done
  if ! wait "$pid"; then
    tail -n 20 "$out"
    return 1
  fi
}

# A leftover marker from an earlier run must not claim a rerun that didn't happen.
rm -f "$log_dir/test-rerun.txt"
status=0
run_attempt 1 "$RESULT_BUNDLE_PATH" || status=$?
if [ "$status" -eq 0 ]; then
  exit 0
fi

classification=$(classify 1)
case "$classification" in
  infrastructure:*) signature=${classification#infrastructure:} ;;
  *)
    echo "The plan failed (xcodebuild exit $status) after running tests; not rerunning it."
    exit "$status"
    ;;
esac

echo "$signature" > "$log_dir/test-rerun.txt" # read by xcresult_summary.py's step
echo "::warning::Infrastructure failure ($signature); rebooting the simulator and running the plan once more"
xcrun simctl shutdown "$UDID" || true
if ! xcrun simctl boot "$UDID"; then
  echo "'simctl boot' failed; 'simctl bootstatus -b' boots it instead."
fi
if ! wait_for_boot; then
  echo "::error::The simulator ($UDID) didn't come back after the reboot, so the plan wasn't rerun." >&2
  exit "$status"
fi
if [ -n "$DUO_POSE" ]; then
  if ! "$pose_script" "$UDID" "$DUO_POSE"; then
    echo "::error::The iPhone Duo's $DUO_POSE pose didn't take after the reboot, so the plan wasn't rerun." >&2
    exit "$status"
  fi
fi

status=0
run_attempt 2 "${RESULT_BUNDLE_PATH%.xcresult}-attempt-2.xcresult" || status=$?
if [ "$status" -ne 0 ]; then
  echo "::error::The plan failed again on the rebooted simulator (xcodebuild exit $status, $(classify 2)); it isn't run a third time."
fi
exit "$status"
