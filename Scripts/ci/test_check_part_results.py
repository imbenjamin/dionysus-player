"""Tests for check-part-results.sh, which gives one environment's result for
a UI-test plan split into parts (ui-tests.yml's `*-result` jobs)."""

import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "check-part-results.sh")


class CheckPartResultsTests(unittest.TestCase):
    def _run(self, results: dict, count: int):
        with tempfile.TemporaryDirectory() as folder:
            for part, status in results.items():
                with open(os.path.join(folder, f"part-{part}"), "w") as f:
                    f.write(status + "\n")
            return subprocess.run(
                ["bash", SCRIPT, folder, str(count)], capture_output=True, text=True
            )

    def test_passes_when_every_part_passed(self):
        result = self._run({1: "success", 2: "success"}, 2)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Part 2 of 2: success", result.stdout)

    def test_passes_a_single_part(self):
        self.assertEqual(self._run({1: "success"}, 1).returncode, 0)

    def test_fails_when_a_part_failed(self):
        result = self._run({1: "success", 2: "failure"}, 2)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Part 2 of 2: failure", result.stdout)

    def test_fails_when_a_part_was_cancelled(self):
        self.assertEqual(self._run({1: "cancelled", 2: "success"}, 2).returncode, 1)

    def test_fails_when_a_part_left_no_result(self):
        result = self._run({1: "success"}, 2)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Part 2 of 2: no result", result.stdout)

    def test_fails_when_no_part_left_a_result(self):
        with tempfile.TemporaryDirectory() as parent:
            missing = os.path.join(parent, "never-downloaded")
            result = subprocess.run(["bash", SCRIPT, missing, "2"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
