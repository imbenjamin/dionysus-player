#!/usr/bin/env python3
"""Summarizes the tests of one or more result bundles: which failed, and which
passed only on a retry.

    python3 Scripts/ci/xcresult_summary.py <results.json> [<results.json> ...]

Each argument is the output of `xcrun xcresulttool get test-results tests
--path <bundle>`. Markdown goes to stdout (the build-and-test action appends
it to `$GITHUB_STEP_SUMMARY`), and one `::warning title=Flaky test::<Class>/<test>
passed on attempt N of M` per test that failed and then passed goes to
*stderr*, so the redirect of stdout into the summary file leaves the runner to
read them. Always exits 0: a file that can't be read or parsed becomes a
`::warning::` that the summary couldn't be built, never a failed job.

The JSON shape (Xcode 27.1, schema 0.5.0, as the fixtures hold it, made from a
UI test that fails its first run only and one that always fails, run with
`-retry-tests-on-failure -test-iterations 2`; no `--legacy` flag needed):

    testNodes[] > "Test Plan" > "UI test bundle" / "Unit test bundle"
      > "Test Suite" > "Test Case"
          name "testX()", nodeIdentifier "Class/testX()",
          result "Passed" | "Failed" | "Skipped" | "Expected Failure"
          children (only when the test ran more than once): "Repetition"
              ("First Run", "Retry 1", ...), each with its own result and its
              "Failure Message" children (name "failed - <message>")
          children (a test that ran once and failed): "Failure Message"

A test case's own result is its last repetition's, so "Passed" with more than
one repetition is a flaky test. Stdlib only.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field


@dataclass
class TestOutcome:
    __test__ = False  # not a test class, whatever pytest thinks of the name

    identifier: str
    attempts: int
    failure_messages: list[str] = field(default_factory=list)


@dataclass
class Summary:
    flaky: list[TestOutcome] = field(default_factory=list)
    failed: list[TestOutcome] = field(default_factory=list)
    passed_count: int = 0  # passed on the first attempt


def _messages(node: dict) -> list[str]:
    return [c.get("name", "") for c in node.get("children", [])
            if c.get("nodeType") == "Failure Message"]


def _outcome(case: dict) -> TestOutcome:
    repetitions = [c for c in case.get("children", []) if c.get("nodeType") == "Repetition"]
    identifier = case.get("nodeIdentifier") or case.get("name", "?")
    if not repetitions:
        return TestOutcome(identifier, 1, _messages(case))
    messages = [m for r in repetitions for m in _messages(r)]
    return TestOutcome(identifier, len(repetitions), messages)


def _cases(node: dict):
    if node.get("nodeType") == "Test Case":
        yield node
    else:
        for child in node.get("children", []):
            yield from _cases(child)


def summarize(nodes: dict) -> Summary:
    """Sorts the test cases of a `get test-results tests` document."""
    summary = Summary()
    for root in nodes.get("testNodes", []):
        for case in _cases(root):
            result = case.get("result")
            outcome = _outcome(case)
            if result == "Failed":
                summary.failed.append(outcome)
            elif result == "Passed" and outcome.attempts > 1:
                summary.flaky.append(outcome)
            elif result == "Passed":
                summary.passed_count += 1
    return summary


def _first(messages: list[str]) -> str:
    return messages[0] if messages else "no message recorded"


def markdown(summary: Summary) -> str:
    total = len(summary.flaky) + len(summary.failed) + summary.passed_count
    lines = [
        f"{summary.passed_count} passed first time, {len(summary.flaky)} flaky, "
        f"{len(summary.failed)} failed ({total} counted; skipped tests are not).",
        "",
    ]
    if summary.flaky:
        lines += ["### Flaky (passed only on a retry)", ""]
        for t in summary.flaky:
            lines.append(
                f"- `{t.identifier}`: passed on attempt {t.attempts} of {t.attempts}; "
                f"first failure: {_first(t.failure_messages)}"
            )
        lines.append("")
    if summary.failed:
        lines += ["### Failed", ""]
        for t in summary.failed:
            lines.append(
                f"- `{t.identifier}`: failed {t.attempts} of {t.attempts} attempts; "
                f"{_first(t.failure_messages)}"
            )
        lines.append("")
    if not summary.flaky and not summary.failed:
        lines += ["No failed or retried tests.", ""]
    return "\n".join(lines)


def warnings(summary: Summary) -> list[str]:
    return [
        f"::warning title=Flaky test::{t.identifier} passed on attempt {t.attempts} of {t.attempts}"
        for t in summary.flaky
    ]


def main(argv: list[str]) -> int:
    import json

    if len(argv) < 2:
        print(f"usage: {argv[0]} <results.json> [<results.json> ...]", file=sys.stderr)
        return 0
    combined = Summary()
    for path in argv[1:]:
        try:
            with open(path, encoding="utf-8") as f:
                summary = summarize(json.load(f))
        except (OSError, ValueError) as error:
            print(f"::warning::Couldn't build the test summary from {path}: {error}", file=sys.stderr)
            continue
        combined.flaky += summary.flaky
        combined.failed += summary.failed
        combined.passed_count += summary.passed_count
    print(markdown(combined))
    for line in warnings(combined):
        print(line, file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as error:  # never fail the job over a summary
        print(f"::warning::Couldn't build the test summary: {error}", file=sys.stderr)
        sys.exit(0)
