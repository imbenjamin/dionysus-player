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

    def test_iterationsAllPassed_isPassedNotFlaky(self):
        # `-test-iterations 3`, no retry: three Repetitions, none failed.
        summary = xcresult_summary.summarize(load("test-results-iterations-passed.json"))
        self.assertEqual((summary.flaky, summary.failed), ([], []))
        self.assertEqual(summary.passed_count, 1)

    def test_passesThenFailure_isFailedOnIterationK(self):
        # `-test-iterations 3 -run-tests-until-failure`: passes, passes, fails.
        summary = xcresult_summary.summarize(load("test-results-iterations-then-failure.json"))
        (failed,) = summary.failed
        self.assertEqual((failed.attempts, failed.failed_count, failed.first_failure), (3, 1, 3))
        self.assertEqual(summary.flaky, [])
        text = xcresult_summary.markdown(summary)
        self.assertIn("failed on iteration 3 of 3 after 2 passes", text)
        self.assertNotIn("failed 3 of 3", text)

    def test_manyPassingIterations_raiseNoWarnings(self):
        summary = xcresult_summary.summarize(tree(
            case("testA", "Passed", [("Passed", [])] * 5),
            case("testB", "Passed", [("Passed", [])] * 5)))
        self.assertEqual((summary.flaky, summary.passed_count), ([], 2))
        self.assertEqual(xcresult_summary.warnings(summary), [])

    def test_failedKOfN_countsFailedRepetitionsOnly(self):
        # Retry mode: fails, passes, fails, fails -> final Failed, 3 of 4.
        summary = xcresult_summary.summarize(tree(case("testA", "Failed", [
            ("Failed", ["a"]), ("Passed", []), ("Failed", ["b"]), ("Failed", ["c"])])))
        (failed,) = summary.failed
        self.assertEqual(failed.failed_count, 3)
        self.assertIn("failed 3 of 4 attempts", xcresult_summary.markdown(summary))

    def test_passedFirstTime_isNeither(self):
        summary = xcresult_summary.summarize(tree(case("testA", "Passed")))
        self.assertEqual((summary.flaky, summary.failed), ([], []))
        self.assertEqual(summary.passed_count, 1)

    def test_failedWithoutRepetitions_isOneAttempt(self):
        summary = xcresult_summary.summarize(
            tree(case("testA", "Failed", messages=["boom"])))
        (failed,) = summary.failed
        self.assertEqual((failed.attempts, failed.failure_messages), (1, ["boom"]))

    def test_repetitionsUnderAnIntermediateNode_stillFlaky(self):
        flaky = case("testA", "Passed", [("Failed", ["z"]), ("Passed", [])])
        flaky["children"] = [{"nodeType": "Device", "name": "iPhone", "children": flaky["children"]}]
        summary = xcresult_summary.summarize(tree(flaky))
        (outcome,) = summary.flaky
        self.assertEqual((outcome.attempts, outcome.failure_messages), (2, ["z"]))
        self.assertEqual(summary.passed_count, 0)

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
        self.assertIn("failed 1 of 2 attempts, then passed on attempt 2", text)
        self.assertIn("failed 2 of 2 attempts", text)
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


CRASHED = ("PlayerPanelJourneyTests/"
           "test_audio_selectMovesTheTick_andTheChoiceIsRememberedNextTime()")


def rerun_tree(result, messages=()):
    """run-test-plan.sh's rerun of shard 2's crashed test."""
    return tree(dict(case("x", result, messages=messages), nodeIdentifier=CRASHED))


class RerunTests(unittest.TestCase):
    def test_aCrashedTestThatPassesWhenRerun_isListedApart_withAWarning(self):
        summary = xcresult_summary.summarize(load("test-results-simulator-shutdown.json"))
        xcresult_summary.apply_rerun(summary, xcresult_summary.summarize(rerun_tree("Passed")))
        self.assertEqual(summary.failed, [])
        (rerun,) = summary.rerun
        self.assertEqual(rerun.identifier, CRASHED)
        self.assertEqual(len(summary.flaky), 2)  # the plan's own retries stay flaky
        text = xcresult_summary.markdown(summary)
        self.assertIn("1 rerun after a crash, 0 failed", text)
        self.assertIn("### Rerun after the Simulator shut down", text)
        self.assertIn("Test crashed with signal term.", text)
        self.assertNotIn("### Failed", text)
        self.assertIn(
            f"::warning title=Rerun after a crash::{CRASHED} was killed by the Simulator "
            "shutting down, and passed when run again",
            xcresult_summary.warnings(summary),
        )

    def test_aCrashedTestThatFailsWhenRerun_staysFailed_withTheRerunsOutcome(self):
        summary = xcresult_summary.summarize(load("test-results-simulator-shutdown.json"))
        xcresult_summary.apply_rerun(
            summary, xcresult_summary.summarize(rerun_tree("Failed", ["XCTAssertEqual failed"])))
        (failed,) = summary.failed
        self.assertEqual((failed.identifier, failed.failure_messages),
                         (CRASHED, ["XCTAssertEqual failed"]))
        self.assertEqual(summary.rerun, [])

    def test_theRunnersFailedRelaunch_isNotedNotFailed(self):
        summary = xcresult_summary.summarize(load("test-results-simulator-shutdown-relaunch.json"))
        crashed = ("CollectionGridJourneyTests/"
                   "test_pills_nameTheirFacet_andReadTheirChoiceAsTheirValue()")
        rerun = tree(dict(case("x", "Passed"), nodeIdentifier=crashed))
        xcresult_summary.apply_rerun(summary, xcresult_summary.summarize(rerun))
        self.assertEqual(summary.failed, [])
        self.assertEqual(len(summary.relaunches), 1)
        self.assertIn("relaunch of the test runner failed once",
                      xcresult_summary.markdown(summary))

    def test_withoutARerun_theCrashIsAFailure(self):
        summary = xcresult_summary.summarize(load("test-results-simulator-shutdown.json"))
        self.assertEqual([t.identifier for t in summary.failed], [CRASHED])


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *paths):
        return subprocess.run([sys.executable, os.path.join(HERE, "xcresult_summary.py"), *paths],
                              capture_output=True, text=True)

    def test_flakyFixture_writesMarkdownToStdoutAndWarningToStderr_exit0(self):
        result = self.run_cli(os.path.join(HERE, "fixtures", "test-results-flaky.json"))
        self.assertEqual(result.returncode, 0)
        self.assertIn("Flaky", result.stdout)
        self.assertIn("::warning title=Flaky test::", result.stderr)

    def test_rerunFlag_foldsTheRerunIn(self):
        rerun = os.path.join(self.tmp(), "rerun.json")
        with open(rerun, "w") as f:
            json.dump(rerun_tree("Passed"), f)
        result = self.run_cli(
            os.path.join(HERE, "fixtures", "test-results-simulator-shutdown.json"), "--rerun", rerun)
        self.assertEqual(result.returncode, 0)
        self.assertIn("1 rerun after a crash, 0 failed", result.stdout)
        self.assertIn("::warning title=Rerun after a crash::", result.stderr)

    def tmp(self):
        import shutil
        import tempfile
        path = tempfile.mkdtemp(prefix="xcresult-summary-")
        self.addCleanup(shutil.rmtree, path)
        return path

    def test_unreadableInput_warnsAndExits0(self):
        result = self.run_cli(os.path.join(HERE, "fixtures", "assertion-failure.log"),
                              "/nonexistent.json")
        self.assertEqual(result.returncode, 0)
        self.assertIn("::warning::", result.stderr)


if __name__ == "__main__":
    unittest.main()
