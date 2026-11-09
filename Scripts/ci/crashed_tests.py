#!/usr/bin/env python3
"""Lists the tests a failed plan lost to the Simulator shutting down, so
run-test-plan.sh can run just those once more.

    python3 Scripts/ci/crashed_tests.py <results.json>

The argument is `xcrun xcresulttool get test-results tests --path <bundle>`'s
output. Prints one `-only-testing` identifier per line (`Bundle/Class/test`),
or nothing, and exits 0 either way.

Since the runner image of 2026-11-04 (which added Xcode 27.2 and its
Simulator runtimes beside 27.1) each tvOS 27.0 shard of the nightly has lost
its Simulator once, 7 to 8.5 minutes after booting it: testmanagerd loses the
daemon, the Simulator reads "Shutdown", and the test running then fails with
"Test crashed with signal term." xcodebuild boots the Simulator again and
runs the rest of the plan, but not that test, which no retry reaches either.

So the tests are listed only when *every* failure is of that kind: each
failed test's last repetition failed only with that message (an earlier
repetition may have failed for real, as a retry would have run anyway; the
rerun is retried as the plan's tests are). xcodebuild may also report a
relaunch of the runner that didn't take ("<Bundle>-Runner (N) encountered an
error", "Failed to install or launch the test runner") as a test case; that
isn't a test and doesn't block the rerun, but it never causes one alone. Any
other failure prints nothing: the plan failed for real. A file that can't be
read prints nothing too. Stdlib only.
"""

from __future__ import annotations

import json
import re
import sys

from xcresult_summary import _cases, _messages, _repetitions

CRASH = "Test crashed with signal term"
RUNNER_LAUNCH = "Failed to install or launch the test runner"
_RUNNER_ERROR = re.compile(r"-Runner \(\d+\) encountered an error$")


def _bundles(node: dict, bundle: str | None = None):
    """(bundle name, test case) for every test case below a node."""
    if node.get("nodeType") in ("UI test bundle", "Unit test bundle"):
        bundle = node.get("name")
    if node.get("nodeType") == "Test Case":
        yield bundle, node
        return
    for child in node.get("children", []):
        yield from _bundles(child, bundle)


def _crashed_last(case: dict) -> bool:
    repetitions = list(_repetitions(case))
    last = repetitions[-1] if repetitions else case
    messages = _messages(last)
    return last.get("result") == "Failed" and bool(messages) and all(CRASH in m for m in messages)


def is_runner_relaunch(case: dict) -> bool:
    """The pseudo test case for a runner relaunch that didn't take."""
    return bool(_RUNNER_ERROR.search(case.get("name", ""))) and all(
        RUNNER_LAUNCH in m for m in _messages(case)
    ) and bool(_messages(case))


def crashed_tests(nodes: dict) -> list[str]:
    """`Bundle/Class/test` per test lost to the shutdown, or [] if anything
    else failed."""
    crashed: list[str] = []
    for root in nodes.get("testNodes", []):
        for bundle, case in _bundles(root):
            if case.get("result") != "Failed":
                continue
            if is_runner_relaunch(case):
                continue
            identifier = case.get("nodeIdentifier", "")
            if not (bundle and _crashed_last(case) and "/" in identifier):
                return []
            crashed.append(f"{bundle}/{identifier.removesuffix('()')}")
    return crashed


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <results.json>", file=sys.stderr)
        return 0
    try:
        with open(argv[1], encoding="utf-8") as f:
            nodes = json.load(f)
    except (OSError, ValueError) as error:
        print(f"Couldn't read {argv[1]}: {error}", file=sys.stderr)
        return 0
    for test in crashed_tests(nodes):
        print(test)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
