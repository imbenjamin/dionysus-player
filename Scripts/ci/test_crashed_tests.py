"""Tests for crashed_tests.py against real `xcresulttool get test-results
tests` JSON from the nightly of 2026-11-09 (two tvOS 27.0 shards, Xcode 27.1,
trimmed to their failed and retried tests and two that passed) and small
hand-made trees for the other shapes.

Run with `python3 -m unittest discover -s Scripts/ci -v`.
"""

import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import crashed_tests  # noqa: E402

CRASH = "Test crashed with signal term."
RELAUNCH = (
    "Failed to install or launch the test runner. (Underlying Error: Failed to find "
    "service com.apple.CoreSimulator.host_support in session …)"
)


def load(name):
    with open(os.path.join(HERE, "fixtures", name)) as f:
        return json.load(f)


def case(identifier, result, repetitions=(), messages=()):
    children = [
        {"nodeType": "Repetition", "name": f"Run {i}", "result": r,
         "children": [{"nodeType": "Failure Message", "name": m} for m in ms]}
        for i, (r, ms) in enumerate(repetitions, 1)
    ] + [{"nodeType": "Failure Message", "name": m} for m in messages]
    return {"nodeType": "Test Case", "name": identifier.split("/")[-1],
            "nodeIdentifier": identifier, "result": result, "children": children}


def tree(*cases):
    return {"testNodes": [{"nodeType": "Test Plan", "name": "P", "result": "Failed",
                           "children": [{"nodeType": "UI test bundle", "name": "TVUITests",
                                         "children": [{"nodeType": "Test Suite", "name": "Suite",
                                                       "children": list(cases)}]}]}]}


class CrashedTestsTests(unittest.TestCase):
    def test_aTestKilledByTheShutdown_isListed_besideRetriedFlakes(self):
        # Shard 2: one crash, two tests that failed and passed on a retry.
        self.assertEqual(
            crashed_tests.crashed_tests(load("test-results-simulator-shutdown.json")),
            ["DionysusTVUITests/PlayerPanelJourneyTests/"
             "test_audio_selectMovesTheTick_andTheChoiceIsRememberedNextTime"],
        )

    def test_theRunnersFailedRelaunch_isNotATestAndDoesNotBlockTheRerun(self):
        # Shard 4: the crash, then "DionysusTVUITests-Runner (8561) encountered an error".
        self.assertEqual(
            crashed_tests.crashed_tests(load("test-results-simulator-shutdown-relaunch.json")),
            ["DionysusTVUITests/CollectionGridJourneyTests/"
             "test_pills_nameTheirFacet_andReadTheirChoiceAsTheirValue"],
        )

    def test_aCrashOnTheRetryOfARealFailure_isListed(self):
        # Shard 1's shape: the retry a real failure earned was the one killed.
        nodes = tree(case("Suite/test_a()", "Failed",
                          repetitions=[("Failed", ["XCTAssertTrue failed"]), ("Failed", [CRASH])]))
        self.assertEqual(crashed_tests.crashed_tests(nodes), ["TVUITests/Suite/test_a"])

    def test_aCrashBeforeARealFailure_isNotListed(self):
        nodes = tree(case("Suite/test_a()", "Failed",
                          repetitions=[("Failed", [CRASH]), ("Failed", ["XCTAssertTrue failed"])]))
        self.assertEqual(crashed_tests.crashed_tests(nodes), [])

    def test_anyRealFailureBesideTheCrash_listsNothing(self):
        nodes = tree(case("Suite/test_a()", "Failed", messages=[CRASH]),
                     case("Suite/test_b()", "Failed", messages=["XCTAssertEqual failed"]))
        self.assertEqual(crashed_tests.crashed_tests(nodes), [])

    def test_aRelaunchErrorAlone_listsNothing(self):
        nodes = tree(case("TVUITests-Runner (8561) encountered an error", "Failed",
                          messages=[RELAUNCH]))
        self.assertEqual(crashed_tests.crashed_tests(nodes), [])

    def test_anyOtherRunnerError_listsNothing(self):
        nodes = tree(case("Suite/test_a()", "Failed", messages=[CRASH]),
                     case("TVUITests-Runner (8561) encountered an error", "Failed",
                          messages=["Early unexpected exit, operation never finished bootstrapping"]))
        self.assertEqual(crashed_tests.crashed_tests(nodes), [])

    def test_anotherSignal_isNotTheShutdown(self):
        nodes = tree(case("Suite/test_a()", "Failed", messages=["Test crashed with signal abrt."]))
        self.assertEqual(crashed_tests.crashed_tests(nodes), [])

    def test_ordinaryFailuresAndPasses_listNothing(self):
        self.assertEqual(crashed_tests.crashed_tests(load("test-results-failing.json")), [])
        self.assertEqual(crashed_tests.crashed_tests(load("test-results-flaky.json")), [])

    def test_theScript_printsOnePerLine_andNothingForAnUnreadableFile(self):
        script = os.path.join(HERE, "crashed_tests.py")
        fixture = os.path.join(HERE, "fixtures", "test-results-simulator-shutdown.json")
        out = subprocess.run([sys.executable, script, fixture], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(len(out.stdout.splitlines()), 1)
        missing = subprocess.run([sys.executable, script, "/nonexistent.json"],
                                 capture_output=True, text=True)
        self.assertEqual((missing.returncode, missing.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
