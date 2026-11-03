"""Tests for xcresult_summary.py against real `xcresulttool get test-results
tests` JSON (Xcode 27.1; see the fixtures' provenance in the script's
docstring) and small hand-made trees for the shapes a run doesn't produce
here (a test that passed first time, a skip).

Run with `python3 -m unittest discover -s Scripts/ci -v`.
"""

import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import xcresult_summary  # noqa: E402


def load(name):
    with open(os.path.join(HERE, "fixtures", name)) as f:
        return json.load(f)


def case(name, result, repetitions=(), messages=()):
    children = [
        {"nodeType": "Repetition", "name": f"Run {i}", "result": r,
         "children": [{"nodeType": "Failure Message", "name": m} for m in ms]}
        for i, (r, ms) in enumerate(repetitions, 1)
    ] + [{"nodeType": "Failure Message", "name": m} for m in messages]
    return {"nodeType": "Test Case", "name": f"{name}()", "nodeIdentifier": f"Suite/{name}()",
            "result": result, "children": children}


def tree(*cases):
    return {"testNodes": [{"nodeType": "Test Plan", "name": "P", "result": "Failed",
                           "children": [{"nodeType": "Test Suite", "name": "Suite",
                                         "children": list(cases)}]}]}


class SummarizeTests(unittest.TestCase):
    def test_retriedThenPassed_isFlaky(self):
        summary = xcresult_summary.summarize(load("test-results-flaky.json"))
        (flaky,) = summary.flaky
        self.assertEqual(flaky.identifier, "HarnessTests/testEmptyLibraryScenarioIsServed()")
        self.assertEqual(flaky.attempts, 2)
        self.assertEqual(flaky.failure_messages, ["failed - first attempt only (fixture)"])
        self.assertEqual(summary.failed, [])

    def test_failedEveryAttempt_isFailedNotFlaky(self):
        summary = xcresult_summary.summarize(load("test-results-failing.json"))
        (failed,) = summary.failed
        self.assertEqual(failed.identifier, "HarnessTests/testTmpAlwaysFails()")
        self.assertEqual(failed.attempts, 2)
        self.assertEqual(len(failed.failure_messages), 2)
        self.assertEqual(summary.flaky, [])

    def test_passedFirstTime_isNeither(self):
        summary = xcresult_summary.summarize(tree(case("testA", "Passed")))
        self.assertEqual((summary.flaky, summary.failed), ([], []))
        self.assertEqual(summary.passed_count, 1)

    def test_failedWithoutRepetitions_isOneAttempt(self):
        summary = xcresult_summary.summarize(
            tree(case("testA", "Failed", messages=["boom"])))
        (failed,) = summary.failed
        self.assertEqual((failed.attempts, failed.failure_messages), (1, ["boom"]))

    def test_skipped_isNotCountedAsPassed(self):
        summary = xcresult_summary.summarize(tree(case("testA", "Skipped")))
        self.assertEqual(summary.passed_count, 0)

    def test_emptyOrUnknownTree_summarizesNothing(self):
        summary = xcresult_summary.summarize({})
        self.assertEqual((summary.flaky, summary.failed, summary.passed_count), ([], [], 0))


class MarkdownTests(unittest.TestCase):
    def test_markdown_listsFlakyThenFailed(self):
        summary = xcresult_summary.summarize(tree(
            case("testFailed", "Failed", [("Failed", ["x"]), ("Failed", ["y"])]),
            case("testFlaky", "Passed", [("Failed", ["z"]), ("Passed", [])]),
            case("testOk", "Passed"),
        ))
        text = xcresult_summary.markdown(summary)
        self.assertLess(text.index("Flaky"), text.index("Failed"))
        self.assertIn("Suite/testFlaky()", text)
        self.assertIn("passed on attempt 2 of 2", text)
        self.assertIn("Suite/testFailed()", text)
        self.assertIn("1 passed first time", text)

    def test_allGreen_saysSo(self):
        text = xcresult_summary.markdown(xcresult_summary.summarize(tree(case("a", "Passed"))))
        self.assertIn("No failed or retried tests", text)

    def test_warnings_nameEachFlakyTest(self):
        summary = xcresult_summary.summarize(load("test-results-flaky.json"))
        self.assertEqual(
            xcresult_summary.warnings(summary),
            ["::warning title=Flaky test::HarnessTests/testEmptyLibraryScenarioIsServed() "
             "passed on attempt 2 of 2"],
        )


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *paths):
        return subprocess.run([sys.executable, os.path.join(HERE, "xcresult_summary.py"), *paths],
                              capture_output=True, text=True)

    def test_flakyFixture_writesMarkdownToStdoutAndWarningToStderr_exit0(self):
        result = self.run_cli(os.path.join(HERE, "fixtures", "test-results-flaky.json"))
        self.assertEqual(result.returncode, 0)
        self.assertIn("Flaky", result.stdout)
        self.assertIn("::warning title=Flaky test::", result.stderr)

    def test_unreadableInput_warnsAndExits0(self):
        result = self.run_cli(os.path.join(HERE, "fixtures", "assertion-failure.log"),
                              "/nonexistent.json")
        self.assertEqual(result.returncode, 0)
        self.assertIn("::warning::", result.stderr)


if __name__ == "__main__":
    unittest.main()
