"""Tests for xcodebuild_failure.py, the classifier that decides whether a
failed `xcodebuild test-without-building` earns one rerun on a rebooted
Simulator (run-test-plan.sh).

Run with `python3 -m unittest discover -s Scripts/ci -v`.

Fixtures (fixtures/) are excerpts of real CI job logs, with ANSI escapes and
the runner's leading timestamps stripped. A job log holds xcodebuild's stderr
verbatim, but its stdout only as xcbeautify printed it, which drops the raw
`Test Case '…' failed` lines; run-test-plan.sh classifies the raw output of
both. Where a fixture is not a real excerpt its name starts `handmade-`.

- early-exit.log: job 125091015476 (UI smoke, iPhone, iOS 27.0, 2026-11-02),
  the Test step's output from its start. The runner crashed in
  `handleStalledWait` while bootstrapping; no test ran. All 21 early exits in
  the logs looked like this.
- assertion-failure.log: job 114698173776 (tvOS UI smoke, 2026-10-12), a
  journey's XCTAssertTrue failing both attempts.
- background-assertion-in-a-test.log: job 121158581923 (UI smoke, iPad,
  iOS 27.0, 2026-10-25), and launch-timeout-in-a-test.log: job 115818853969
  (UI smoke, iPad, iOS 26.5, 2026-10-14). The repeated
  IDELaunchParametersSnapshot/IDESchemeActionSDKRecord lines are dropped.
  In every log in the sample these two messages are test failures (a test's
  `app.launch()` failing), listed under "Failing tests:", which the plan's
  own retry handles: they are not infrastructure failures there.
- compile-error.log: job 123400487750 (tvOS UI smoke, 2026-10-23), lines
  1420-1424 and 1490-1500 of the Build step joined.
- handmade-background-assertion-runner.log and
  handmade-launch-timeout-runner.log: the same messages raised for the test
  runner itself before any test, which the sample doesn't contain. Built on
  early-exit.log's shape with the error text swapped.
- handmade-signature-after-a-test-failure.log: raw xcodebuild stdout (as
  run-test-plan.sh tees it) in which a test ran and failed and the runner then
  exited with an infrastructure signature.
"""

import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import xcodebuild_failure  # noqa: E402
from xcodebuild_failure import SIGNATURES, classify  # noqa: E402

EARLY_EXIT = "Early unexpected exit, operation never finished bootstrapping"
BACKGROUND_ASSERTION = "Failed to get background assertion"
LAUNCH_TIMEOUT = "Timed out while launching application"


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return f.read()


class ClassifyTests(unittest.TestCase):
    def test_earlyExit_isInfrastructure(self):
        self.assertEqual(classify(fixture("early-exit.log")), ("infrastructure", EARLY_EXIT))

    def test_backgroundAssertion_isInfrastructure(self):
        self.assertEqual(
            classify(fixture("handmade-background-assertion-runner.log")),
            ("infrastructure", BACKGROUND_ASSERTION),
        )

    def test_launchTimeout_isInfrastructure(self):
        self.assertEqual(
            classify(fixture("handmade-launch-timeout-runner.log")),
            ("infrastructure", LAUNCH_TIMEOUT),
        )

    def test_assertionFailure_isTest(self):
        log = fixture("assertion-failure.log")
        self.assertIn("XCTAssertTrue failed", log)
        self.assertEqual(classify(log), ("test", None))

    def test_compileError_isTest(self):
        log = fixture("compile-error.log")
        self.assertIn("BUILD FAILED", log)
        self.assertEqual(classify(log), ("test", None))

    def test_signatureAfterATestFailure_isStillTest(self):
        log = fixture("handmade-signature-after-a-test-failure.log")
        self.assertIn(EARLY_EXIT, log)
        self.assertEqual(classify(log), ("test", None))

    def test_backgroundAssertionInATest_isTest(self):
        # A real job log: xcbeautify dropped the `Test Case … failed` lines,
        # but xcodebuild's stderr still lists the test under "Failing tests:".
        log = fixture("background-assertion-in-a-test.log")
        self.assertIn(BACKGROUND_ASSERTION, log)
        self.assertEqual(classify(log), ("test", None))

    def test_launchTimeoutInATest_isTest(self):
        log = fixture("launch-timeout-in-a-test.log")
        self.assertIn(LAUNCH_TIMEOUT, log)
        self.assertEqual(classify(log), ("test", None))

    def test_eachSignatureAlone_isInfrastructure(self):
        for signature in SIGNATURES:
            with self.subTest(signature=signature):
                log = f"Testing failed:\n\tRunner (1) encountered an error ({signature} …)\n"
                self.assertEqual(classify(log), ("infrastructure", signature))

    def test_theFiveSignatures(self):
        self.assertEqual(
            SIGNATURES,
            (
                EARLY_EXIT,
                BACKGROUND_ASSERTION,
                LAUNCH_TIMEOUT,
                "Test runner never began executing tests",
                "The test runner crashed while preparing to run tests",
            ),
        )

    def test_parallelTestCaseSpelling_isStillTest(self):
        # xcodebuild's own line for a test run on a clone, "Test case" in
        # lower case.
        log = (
            "Test case 'SmokeJourneyTests.testOpeningAnItemFromHome()' failed on "
            "'Clone 1 of iPhone 16 - Dionysus (123)' (31.204 seconds)\n"
            f"Testing failed:\n\tRunner (1) encountered an error ({EARLY_EXIT})\n"
        )
        self.assertEqual(classify(log), ("test", None))

    def test_aPassedTestCase_doesNotCountAsAFailure(self):
        log = (
            "Test Case '-[DionysusPlayerUITests.HarnessTests testA]' passed (3.001 seconds).\n"
            f"Testing failed:\n\tRunner (1) encountered an error ({EARLY_EXIT})\n"
        )
        self.assertEqual(classify(log), ("infrastructure", EARLY_EXIT))

    def test_emptyLog_isTest(self):
        self.assertEqual(classify(""), ("test", None))


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, xcodebuild_failure.__file__, *args],
            capture_output=True,
            text=True,
        )

    def test_printsInfrastructureAndTheSignature(self):
        result = self.run_cli(os.path.join(HERE, "fixtures", "early-exit.log"))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, f"infrastructure:{EARLY_EXIT}\n")

    def test_printsTest(self):
        result = self.run_cli(os.path.join(HERE, "fixtures", "assertion-failure.log"))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "test\n")

    def test_aMissingLog_isTest(self):
        # No log to read means no evidence of an infrastructure failure.
        result = self.run_cli(os.path.join(HERE, "fixtures", "no-such.log"))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "test\n")


if __name__ == "__main__":
    unittest.main()
