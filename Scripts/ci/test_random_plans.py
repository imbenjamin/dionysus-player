"""The random-order unit plans stay copies of their plans (TQ-26).

`UnitTests-Random` and `TVUnitTests-Random` exist only because xcodebuild has
no `-test-execution-ordering` flag: the nightly flake hunt runs them in place
of `UnitTests` and `TVUnitTests` (TESTING.md, "The nightly unit flake hunt").
A target, skipped test or option added to one plan and not its copy would make
the hunt run something other than what the PRs run, and no one would notice.
So each pair must match apart from the order and the configuration's id.

Run with `python3 -m unittest discover -s Scripts/ci -v`.
"""

import copy
import json
import os
import unittest

PLANS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "TestPlans")
PAIRS = [("UnitTests", "UnitTests-Random"), ("TVUnitTests", "TVUnitTests-Random")]


def load(name):
    with open(os.path.join(PLANS, name + ".xctestplan")) as f:
        return json.load(f)


def without_ordering(plan):
    """The plan with what may differ taken out: the random order, and the
    configurations' ids (each plan file needs its own)."""
    plan = copy.deepcopy(plan)
    plan.get("defaultOptions", {}).pop("testExecutionOrdering", None)
    for configuration in plan.get("configurations", []):
        configuration.pop("id", None)
    return plan


class RandomPlansTests(unittest.TestCase):
    maxDiff = None

    def test_eachRandomPlan_matchesItsPlan_apartFromTheOrder(self):
        for plan, random in PAIRS:
            with self.subTest(plan=plan):
                self.assertEqual(
                    without_ordering(load(random)),
                    without_ordering(load(plan)),
                    f"{random}.xctestplan has drifted from {plan}.xctestplan: "
                    "make the same change in both",
                )

    def test_eachRandomPlan_isRandom_andItsPlanIsNot(self):
        for plan, random in PAIRS:
            with self.subTest(plan=plan):
                self.assertEqual(load(random)["defaultOptions"].get("testExecutionOrdering"), "random")
                self.assertIsNone(load(plan)["defaultOptions"].get("testExecutionOrdering"))

    def test_everyRandomPlan_isPaired(self):
        randoms = {f[: -len(".xctestplan")] for f in os.listdir(PLANS) if f.endswith("-Random.xctestplan")}
        self.assertEqual(randoms, {random for _, random in PAIRS})

    def test_aDriftedCopy_isCaught(self):
        """The comparison sees a change that isn't the order (mutation check)."""
        plan = load("UnitTests")
        drifted = copy.deepcopy(plan)
        drifted["testTargets"][0]["skippedTests"] = ["SomeTests"]
        self.assertNotEqual(without_ordering(drifted), without_ordering(plan))
        drifted = copy.deepcopy(plan)
        drifted["defaultOptions"]["codeCoverage"] = True
        self.assertNotEqual(without_ordering(drifted), without_ordering(plan))


if __name__ == "__main__":
    unittest.main()
