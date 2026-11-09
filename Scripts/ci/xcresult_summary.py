#!/usr/bin/env python3
"""Summarizes the tests of one or more result bundles: which failed, and which
passed only on a retry.

    python3 Scripts/ci/xcresult_summary.py <results.json> [<results.json> ...] [--rerun <results.json>]

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
          children (only when the test ran more than once): "Repetition", direct or
          under an intermediate node,
              ("First Run", "Retry 1", ...), each with its own result and its
              "Failure Message" children (name "failed - <message>")
          children (a test that ran once and failed): "Failure Message"

A test case's own result is its last repetition's, so it can't tell a retried
test from one that was simply run several times: each Repetition's own result
decides. Two modes make repetitions. With `-retry-tests-on-failure` a test is
flaky when some repetition failed and the last passed. With `-test-iterations N`
(the nightly unit flake hunt, plus `-run-tests-until-failure`) every test has N
repetitions, so a test none of which failed is just passed, and one that passed
and then failed under run-until-failure is a failure, reported as "failed on
iteration k of n after k-1 passes".

`--rerun` names the bundle of run-test-plan.sh's rerun of the tests the
Simulator's shutdown killed (crashed_tests.py). A failed test that passed
there is listed as rerun after the crash, with a `::warning title=Rerun after
a crash::`; one that failed there is listed with the rerun's outcome; the
runner relaunch xcodebuild reports as a test case is listed beside them, not
as a failure. Stdlib only.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field


@dataclass
class TestOutcome:
    __test__ = False  # not a test class, whatever pytest thinks of the name

    identifier: str
    attempts: int
    failure_messages: list[str] = field(default_factory=list)
    failed_count: int = 0  # repetitions that failed
    first_failure: int = 0  # 1-based index of the first failed repetition


@dataclass
class Summary:
    flaky: list[TestOutcome] = field(default_factory=list)
    failed: list[TestOutcome] = field(default_factory=list)
    passed_count: int = 0  # no repetition failed, however many there were
    passed: list[str] = field(default_factory=list)  # their identifiers
    rerun: list[TestOutcome] = field(default_factory=list)  # crashed, passed when rerun
    relaunches: list[TestOutcome] = field(default_factory=list)  # runner relaunch errors


# xcodebuild's pseudo test case for a relaunch of the runner that failed.
_RUNNER_ERROR = re.compile(r"-Runner \(\d+\) encountered an error$")


def _messages(node: dict) -> list[str]:
    return [c.get("name", "") for c in node.get("children", [])
            if c.get("nodeType") == "Failure Message"]


def _repetitions(node: dict):
    """Every Repetition below a node, however deep (a device or arguments node
    can sit between a test case and its repetitions)."""
    for child in node.get("children", []):
        if child.get("nodeType") == "Repetition":
            yield child
        else:
            yield from _repetitions(child)


def _outcome(case: dict) -> TestOutcome:
    repetitions = list(_repetitions(case))
    identifier = case.get("nodeIdentifier") or case.get("name", "?")
    if not repetitions:
        failed = 1 if case.get("result") == "Failed" else 0
        return TestOutcome(identifier, 1, _messages(case), failed, 1 if failed else 0)
    messages = [m for r in repetitions for m in _messages(r)]
    results = [r.get("result") for r in repetitions]
    failed = [i for i, r in enumerate(results, 1) if r == "Failed"]
    return TestOutcome(identifier, len(repetitions), messages, len(failed),
                       failed[0] if failed else 0)


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
            elif result == "Passed" and outcome.failed_count > 0:
                summary.flaky.append(outcome)
            elif result == "Passed":
                summary.passed_count += 1
                summary.passed.append(outcome.identifier)
    return summary


def apply_rerun(summary: Summary, rerun: Summary) -> None:
    """Folds in the rerun of the tests the Simulator's shutdown killed."""
    rerun_passed = set(rerun.passed) | {t.identifier for t in rerun.flaky}
    rerun_failed = {t.identifier: t for t in rerun.failed}
    failed = []
    for t in summary.failed:
        if _RUNNER_ERROR.search(t.identifier):
            summary.relaunches.append(t)
        elif t.identifier in rerun_passed:
            summary.rerun.append(t)
        else:
            failed.append(rerun_failed.get(t.identifier, t))
    summary.failed = failed


def _first(messages: list[str]) -> str:
    return messages[0] if messages else "no message recorded"


def _failure_line(t: TestOutcome) -> str:
    """"failed k of n attempts", or, when passes came first and the failure was
    the last word (run-until-failure), where in the run it broke."""
    if t.attempts > 1 and t.first_failure > 1 and t.failed_count == 1:
        k = t.first_failure
        passes = k - 1
        noun = "pass" if passes == 1 else "passes"
        return f"failed on iteration {k} of {t.attempts} after {passes} {noun}"
    return f"failed {t.failed_count} of {t.attempts} attempts"


def markdown(summary: Summary) -> str:
    total = len(summary.flaky) + len(summary.failed) + len(summary.rerun) + summary.passed_count
    rerun = f"{len(summary.rerun)} rerun after a crash, " if summary.rerun else ""
    lines = [
        f"{summary.passed_count} passed first time, {len(summary.flaky)} flaky, {rerun}"
        f"{len(summary.failed)} failed ({total} counted; skipped tests are not).",
        "",
    ]
    if summary.rerun or summary.relaunches:
        lines += ["### Rerun after the Simulator shut down", ""]
        for t in summary.rerun:
            lines.append(
                f"- `{t.identifier}`: killed when the Simulator shut down mid-test "
                f"({_failure_line(t)}; last: {t.failure_messages[-1] if t.failure_messages else 'no message recorded'}), "
                "passed when run again"
            )
        for t in summary.relaunches:
            lines.append(f"- xcodebuild's relaunch of the test runner failed once: {_first(t.failure_messages)}")
        lines.append("")
    if summary.flaky:
        lines += ["### Flaky (passed only on a retry)", ""]
        for t in summary.flaky:
            lines.append(
                f"- `{t.identifier}`: failed {t.failed_count} of {t.attempts} attempts, "
                f"then passed on attempt {t.attempts}; "
                f"first failure: {_first(t.failure_messages)}"
            )
        lines.append("")
    if summary.failed:
        lines += ["### Failed", ""]
        for t in summary.failed:
            lines.append(
                f"- `{t.identifier}`: {_failure_line(t)}; "
                f"{_first(t.failure_messages)}"
            )
        lines.append("")
    if not summary.flaky and not summary.failed and not summary.rerun:
        lines += ["No failed or retried tests.", ""]
    return "\n".join(lines)


def warnings(summary: Summary) -> list[str]:
    return [
        f"::warning title=Flaky test::{t.identifier} passed on attempt {t.attempts} of {t.attempts}"
        for t in summary.flaky
    ] + [
        f"::warning title=Rerun after a crash::{t.identifier} was killed by the Simulator "
        "shutting down, and passed when run again"
        for t in summary.rerun
    ]


def main(argv: list[str]) -> int:
    import json

    paths = argv[1:]
    rerun_path = None
    if "--rerun" in paths:
        i = paths.index("--rerun")
        rerun_path = paths[i + 1] if i + 1 < len(paths) else None
        paths = paths[:i] + paths[i + 2:]
    if not paths:
        print(f"usage: {argv[0]} <results.json> [<results.json> ...] [--rerun <results.json>]", file=sys.stderr)
        return 0

    def read(path):
        try:
            with open(path, encoding="utf-8") as f:
                return summarize(json.load(f))
        except (OSError, ValueError) as error:
            print(f"::warning::Couldn't build the test summary from {path}: {error}", file=sys.stderr)
            return None

    combined = Summary()
    for path in paths:
        summary = read(path)
        if summary is None:
            continue
        combined.flaky += summary.flaky
        combined.failed += summary.failed
        combined.passed_count += summary.passed_count
        combined.passed += summary.passed
    if rerun_path:
        rerun = read(rerun_path)
        if rerun is not None:
            apply_rerun(combined, rerun)
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
