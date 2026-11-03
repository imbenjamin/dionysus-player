"""Tests for run-test-plan.sh, the build-and-test action's "Test" step.

Each test runs the script with fake `xcodebuild`, `xcrun` and `xcbeautify`
first on PATH (and a fake Duo pose script), so it runs anywhere bash and
python3 do, ubuntu-latest included. The fake xcodebuild plays one outcome per
invocation from FAKE_OUTCOMES: `pass`, `infra` (the runner's early exit, on
stderr, as xcodebuild prints it) or `test` (a failed test case).

What they pin is the plan's first review point: an infrastructure failure
gets exactly one rerun on a rebooted Simulator, so a genuine launch-crash
regression fails after that one rerun and never loops, and an ordinary test
failure is never rerun at this level.

Run with `python3 -m unittest discover -s Scripts/ci -v`.
"""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "run-test-plan.sh")
SIGNATURE = "Early unexpected exit, operation never finished bootstrapping"
WARNING = (
    f"::warning::Infrastructure failure ({SIGNATURE}); "
    "rebooting the simulator and running the plan once more"
)

FAKE_XCODEBUILD = textwrap.dedent(
    r"""
    #!/bin/bash
    echo "$*" >> "$FAKE_DIR/xcodebuild.calls"
    echo "xcodebuild $*" >> "$FAKE_DIR/all.calls"
    n=$(wc -l < "$FAKE_DIR/xcodebuild.calls" | tr -d ' ')
    read -r -a outcomes <<< "$FAKE_OUTCOMES"
    outcome=${outcomes[$((n - 1))]:-missing}
    echo "Test Suite 'Selected tests' started at 2026-11-03 10:00:00.000."
    case "$outcome" in
      pass)
        echo "Test Case '-[DionysusPlayerUITests.SmokeJourneyTests testA]' passed (1.000 seconds)."
        exit 0 ;;
      infra)
        printf 'Testing failed:\n\tDionysusPlayerUITests-Runner (42740) encountered an error (%s - no restart will be attempted. (Underlying Error: The test runner crashed while preparing to run tests: DionysusPlayerUITests-Runner at -[XCTWaiter(StallHandling) handleStalledWait:]))\n\n** TEST EXECUTE FAILED **\n' \
          "Early unexpected exit, operation never finished bootstrapping" >&2
        exit 65 ;;
      test)
        echo "Test Case '-[DionysusPlayerUITests.SmokeJourneyTests testA]' failed (1.000 seconds)."
        printf 'Failing tests:\n\tSmokeJourneyTests.testA()\n\n** TEST EXECUTE FAILED **\n' >&2
        exit 65 ;;
      *)
        echo "fake xcodebuild: no outcome for invocation $n" >&2
        exit 99 ;;
    esac
    """
).lstrip()

FAKE_XCRUN = textwrap.dedent(
    r"""
    #!/bin/bash
    echo "xcrun $*" >> "$FAKE_DIR/all.calls"
    if [ "$1 $2" = "simctl bootstatus" ] && [ -n "$FAKE_BOOTSTATUS_FAILS" ]; then
      echo "fake bootstatus: failed" >&2
      exit 1
    fi
    exit 0
    """
).lstrip()

# Marks what passed through it, so a test can tell stdout (piped through
# xcbeautify) from stderr (printed as it is).
FAKE_XCBEAUTIFY = textwrap.dedent(
    r"""
    #!/bin/bash
    while IFS= read -r line; do echo "xcbeautify| $line"; done
    """
).lstrip()

FAKE_POSE = textwrap.dedent(
    r"""
    #!/bin/bash
    echo "pose $*" >> "$FAKE_DIR/all.calls"
    exit "${FAKE_POSE_STATUS:-0}"
    """
).lstrip()


class RunTestPlanTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="run-test-plan-")
        self.addCleanup(shutil.rmtree, self.dir)
        self.bin = os.path.join(self.dir, "bin")
        os.mkdir(self.bin)
        for name, body in (
            ("xcodebuild", FAKE_XCODEBUILD),
            ("xcrun", FAKE_XCRUN),
            ("xcbeautify", FAKE_XCBEAUTIFY),
        ):
            self.write_executable(os.path.join(self.bin, name), body)
        self.pose = os.path.join(self.dir, "set-duo-pose.sh")
        self.write_executable(self.pose, FAKE_POSE)
        self.logs = os.path.join(self.dir, "logs")

    def write_executable(self, path, body):
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o755)

    def run_script(self, outcomes, **env):
        environment = {
            "PATH": self.bin + os.pathsep + os.environ["PATH"],
            "FAKE_DIR": self.dir,
            "FAKE_OUTCOMES": outcomes,
            "SCHEME": "DionysusPlayer",
            "PROJECT": "DionysusPlayer.xcodeproj",
            "TEST_PLAN": "UITests-Smoke",
            "PLATFORM": "iOS",
            "UDID": "4B0BE77E-AB8A-41A1-8820-8A2922D761E0",
            "RESULT_BUNDLE_PATH": ".build/UITestResults.xcresult",
            "RETRY_TESTS_ON_FAILURE": "false",
            "TEST_ITERATIONS": "",
            "ONLY_TESTING": "",
            "DUO_POSE": "",
            "LOG_DIR": self.logs,
            "DUO_POSE_SCRIPT": self.pose,
        }
        environment.update(env)
        return subprocess.run(
            ["bash", SCRIPT],
            env=environment,
            cwd=self.dir,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def xcodebuild_calls(self):
        path = os.path.join(self.dir, "xcodebuild.calls")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return f.read().splitlines()

    def all_calls(self):
        path = os.path.join(self.dir, "all.calls")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return f.read().splitlines()

    def simctl_calls(self):
        return [c for c in self.all_calls() if c.startswith("xcrun simctl")]

    # (a)
    def test_infrastructureThenPass_rerunsOnceAfterARebootAndPasses(self):
        result = self.run_script("infra pass")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.xcodebuild_calls()
        self.assertEqual(len(calls), 2)
        self.assertIn("-resultBundlePath .build/UITestResults.xcresult", calls[0])
        self.assertIn("-resultBundlePath .build/UITestResults-attempt-2.xcresult", calls[1])
        self.assertIn(WARNING, result.stdout.splitlines())
        udid = "4B0BE77E-AB8A-41A1-8820-8A2922D761E0"
        self.assertEqual(
            self.simctl_calls(),
            [
                f"xcrun simctl shutdown {udid}",
                f"xcrun simctl boot {udid}",
                f"xcrun simctl bootstatus {udid} -b",
            ],
        )
        # The reboot comes between the two attempts.
        everything = self.all_calls()
        self.assertTrue(everything[0].startswith("xcodebuild "))
        self.assertTrue(everything[-1].startswith("xcodebuild "))

    # (b)
    def test_infrastructureTwice_failsAfterOneRerunAndNeverRunsAThird(self):
        result = self.run_script("infra infra pass")
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertEqual(len(self.xcodebuild_calls()), 2)
        self.assertEqual(result.stdout.count("::warning::Infrastructure failure"), 1)
        self.assertIn("::error::", result.stdout + result.stderr)

    # (c)
    def test_testFailure_failsWithoutARerunOrAReboot(self):
        result = self.run_script("test pass")
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertEqual(len(self.xcodebuild_calls()), 1)
        self.assertEqual(self.simctl_calls(), [])
        self.assertNotIn("::warning::", result.stdout + result.stderr)

    # (d)
    def test_pass_runsOnce(self):
        result = self.run_script("pass pass")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.xcodebuild_calls()), 1)
        self.assertEqual(self.simctl_calls(), [])
        self.assertNotIn("::warning::", result.stdout + result.stderr)

    # (e)
    def test_duoPose_isSetAgainAfterTheRebootAndBeforeTheRerun(self):
        result = self.run_script("infra pass", DUO_POSE="book")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        everything = self.all_calls()
        pose = everything.index(
            "pose 4B0BE77E-AB8A-41A1-8820-8A2922D761E0 book"
        )
        bootstatus = next(i for i, c in enumerate(everything) if "simctl bootstatus" in c)
        second_run = max(i for i, c in enumerate(everything) if c.startswith("xcodebuild "))
        self.assertLess(bootstatus, pose)
        self.assertLess(pose, second_run)

    def test_withoutADuoPose_thePoseScriptIsNotRun(self):
        self.run_script("infra pass")
        self.assertFalse(any(c.startswith("pose ") for c in self.all_calls()))

    def test_aPoseThatDoesNotTake_failsWithoutTheRerun(self):
        result = self.run_script("infra pass", DUO_POSE="book", FAKE_POSE_STATUS="1")
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertEqual(len(self.xcodebuild_calls()), 1)

    def test_aSimulatorThatDoesNotComeBack_failsWithoutTheRerun(self):
        result = self.run_script("infra pass", FAKE_BOOTSTATUS_FAILS="1")
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertEqual(len(self.xcodebuild_calls()), 1)

    def test_diagnosticsAreNeverCollected(self):
        self.run_script("infra pass")
        for call in self.xcodebuild_calls():
            self.assertIn("-collect-test-diagnostics never", call)

    def test_theInputsReachXcodebuild(self):
        self.run_script(
            "pass",
            RETRY_TESTS_ON_FAILURE="true",
            TEST_ITERATIONS="5",
            ONLY_TESTING="T/A T/B/test_c",
        )
        (call,) = self.xcodebuild_calls()
        self.assertTrue(call.startswith("test-without-building "))
        for expected in (
            "-scheme DionysusPlayer",
            "-project DionysusPlayer.xcodeproj",
            "-testPlan UITests-Smoke",
            "-destination platform=iOS Simulator,id=4B0BE77E-AB8A-41A1-8820-8A2922D761E0",
            "-retry-tests-on-failure -test-iterations 5",
            "-only-testing:T/A -only-testing:T/B/test_c",
        ):
            self.assertIn(expected, call)

    def test_noRetryFlagsUnlessAskedFor(self):
        self.run_script("pass", TEST_ITERATIONS="5")
        (call,) = self.xcodebuild_calls()
        self.assertNotIn("-retry-tests-on-failure", call)
        self.assertNotIn("-test-iterations", call)
        self.assertNotIn("-only-testing", call)

    def test_stdoutGoesThroughXcbeautify_stderrDoesNot_andTheLogKeepsBoth(self):
        result = self.run_script("infra pass")
        self.assertIn("xcbeautify| Test Suite 'Selected tests' started", result.stdout)
        self.assertIn("Testing failed:", result.stderr)
        self.assertNotIn("xcbeautify| Testing failed:", result.stdout)
        with open(os.path.join(self.logs, "test-attempt-1.log")) as f:
            first = f.read()
        self.assertIn("Test Suite 'Selected tests' started", first)
        self.assertIn(SIGNATURE, first)
        self.assertTrue(os.path.exists(os.path.join(self.logs, "test-attempt-2.log")))


if __name__ == "__main__":
    unittest.main()
