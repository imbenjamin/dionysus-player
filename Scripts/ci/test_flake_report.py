"""Tests for flake-report.py's pure parts: log parsing and the runs table.

The `gh` layer is not tested. Run with
`python3 -m unittest discover -s Scripts/ci -v`.
"""

import collections
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "flake_report", os.path.join(HERE, "flake-report.py")
)
report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(report)


def stamped(text: str) -> str:
    """A GitHub job log: ANSI colours and a timestamp ahead of every line."""
    return "\n".join(
        f"2026-10-12T07:16:49.6350000Z \x1b[31;1m{line}\x1b[0m" for line in text.splitlines()
    )


class ParseLogTests(unittest.TestCase):
    def test_failingTests_areTheIndentedLinesAfterTheHeader(self):
        log = stamped(
            "Test Case '-[A.B testX]' failed (1.0 seconds).\n"
            "Failing tests:\n\tCollectionGridJourneyTests.test_tile()\n"
            "\tSearchJourneyTests.test_a()\n\n** TEST EXECUTE FAILED **\n"
        )
        tests, signature = report.parse_log(log)
        self.assertEqual(
            tests, ["CollectionGridJourneyTests.test_tile()", "SearchJourneyTests.test_a()"]
        )
        self.assertIsNone(signature)

    def test_aTestListedTwice_countsOncePerLog(self):
        log = "Failing tests:\n\tA.b()\n\nFailing tests:\n\tA.b()\n"
        self.assertEqual(report.parse_log(log)[0], ["A.b()"])

    def test_infrastructureFailure_namesItsSignature(self):
        log = stamped(
            "Testing failed:\n\tRunner encountered an error (Early unexpected exit, "
            "operation never finished bootstrapping - no restart will be attempted."
        )
        tests, signature = report.parse_log(log)
        self.assertEqual(tests, [])
        self.assertEqual(
            signature, "Early unexpected exit, operation never finished bootstrapping"
        )

    def test_aLogWithNeither_isEmpty(self):
        self.assertEqual(report.parse_log("Build succeeded\n"), ([], None))

    def test_realFixture_hasItsFailingTest(self):
        with open(os.path.join(HERE, "fixtures", "assertion-failure.log")) as f:
            tests, signature = report.parse_log(f.read())
        self.assertEqual(
            tests, ["CollectionGridJourneyTests.test_tile_opensItsDetailPage_andMenuReturnsToIt()"]
        )
        self.assertIsNone(signature)


def run(workflow, conclusion, attempt):
    return {"workflowName": workflow, "conclusion": conclusion, "attempt": attempt,
            "databaseId": 1, "createdAt": "2026-10-20T00:00:00Z"}


class TallyTests(unittest.TestCase):
    def test_countsGreenFirstTimeRerunsAndFailures(self):
        table = report.tally([
            run("PR checks", "success", 1),
            run("PR checks", "success", 1),
            run("PR checks", "success", 2),
            run("PR checks", "failure", 1),
            run("PR checks", "failure", 3),
            run("PR checks", "cancelled", 1),
            run("PR checks", None, 1),
            run("Nightly", "success", 1),
        ])
        self.assertEqual(table["PR checks"], {"runs": 5, "green": 2, "rerun": 2, "failed": 2})
        self.assertEqual(table["Nightly"], {"runs": 1, "green": 1, "rerun": 0, "failed": 0})

    def test_failedAttempts_allOfAFailedRun_allButTheLastOfASuccessfulOne(self):
        self.assertEqual(report.failed_attempts(run("w", "failure", 2)), [1, 2])
        self.assertEqual(report.failed_attempts(run("w", "success", 3)), [1, 2])
        self.assertEqual(report.failed_attempts(run("w", "success", 1)), [])


class RenderTests(unittest.TestCase):
    def test_markdown_hasTheTableAndTheCounts_mostFrequentFirst(self):
        text = report.render(
            "since 2026-10-12",
            report.tally([run("PR checks", "success", 1)]),
            collections.Counter({"job a": 1, "job b": 3}),
            collections.Counter({"T.x()": 2}),
            collections.Counter(),
        )
        self.assertIn("| PR checks | 1 | 1 | 0 | 0 |", text)
        self.assertLess(text.index("job b"), text.index("job a"))
        self.assertIn("| T.x() | 2 |", text)
        self.assertIn("### Infrastructure signatures\n\nNone.", text)

    def test_noLogs_saysWhatIsMissing(self):
        text = report.render("w", {}, collections.Counter(), None, None)
        self.assertIn("`--no-logs`", text)



class DefaultRepoTests(unittest.TestCase):
    def test_ghRepoWins_thenTheRunnersRepository_thenTheBuiltInDefault(self):
        both = {"GH_REPO": "a/b", "GITHUB_REPOSITORY": "c/d"}
        self.assertEqual(report.default_repo(both), "a/b")
        self.assertEqual(report.default_repo({"GITHUB_REPOSITORY": "c/d"}), "c/d")
        self.assertEqual(report.default_repo({}), report.DEFAULT_REPO)


if __name__ == "__main__":
    unittest.main()
