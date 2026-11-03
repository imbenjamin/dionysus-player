#!/usr/bin/env python3
"""Says whether a failed `xcodebuild test-without-building` failed its tests
or failed to start them.

    python3 Scripts/ci/xcodebuild_failure.py <log>

prints `infrastructure:<signature>` or `test`, and exits 0 either way. The log
is xcodebuild's raw output, stdout and stderr (run-test-plan.sh tees both),
not xcbeautify's.

An infrastructure failure is the test runner dying before it ran a test: the
Simulator, not the code, is at fault, and only a fresh Simulator helps, so
run-test-plan.sh reboots it and runs the plan once more. It needs one of the
signatures below *and* no sign that a test ran and failed: a `Test Case '…'
failed` line, or the "Failing tests:" list xcodebuild prints to stderr. A
real failure followed by a runner crash stays a test failure, and the plan's
own `retryOnFailure` has already had its go at it. A missing or unreadable
log reads as `test`: no evidence, no rerun.

Stdlib only; runs on the macOS runners' python3 and on ubuntu-latest.
"""

from __future__ import annotations

import re
import sys

# Exact substrings of xcodebuild's error text. Checked in this order, and the
# first present is the one reported (an early exit names the crash as its
# underlying error, so both of the first and last appear together).
SIGNATURES = (
    "Early unexpected exit, operation never finished bootstrapping",
    "Failed to get background assertion",
    "Timed out while launching application",
    "Test runner never began executing tests",
    "The test runner crashed while preparing to run tests",
)

# XCTest's line for a failed test, "Test Case '-[Module.Class test]' failed
# (1.234 seconds).", and xcodebuild's own for a test run on a clone, "Test
# case 'Class.test()' failed on 'Clone 1 of …' (1.234 seconds)".
_TEST_CASE_FAILED = re.compile(r"^\s*Test [Cc]ase '[^']+' failed\b", re.MULTILINE)
_FAILING_TESTS = re.compile(r"^Failing tests:\s*$", re.MULTILINE)


def classify(log_text: str) -> tuple[str, str | None]:
    """`("infrastructure", signature)` or `("test", None)`."""
    if _TEST_CASE_FAILED.search(log_text) or _FAILING_TESTS.search(log_text):
        return ("test", None)
    for signature in SIGNATURES:
        if signature in log_text:
            return ("infrastructure", signature)
    return ("test", None)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <log>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as error:
        print(f"Couldn't read {argv[1]}: {error}", file=sys.stderr)
        text = ""
    kind, signature = classify(text)
    print(f"infrastructure:{signature}" if signature else kind)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
