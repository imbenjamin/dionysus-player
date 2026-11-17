"""Tests for Scripts/ui-test-shards.py, which splits a UI test target by class."""

import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent / "ui-test-shards.py"
_spec = importlib.util.spec_from_file_location("ui_test_shards", SCRIPT)
shards_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(shards_module)


def _write(folder: pathlib.Path, relative: str, source: str) -> None:
    path = folder / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")


def _class(name: str, base: str, tests: int) -> str:
    body = "".join(f"    func test{i}() {{}}\n" for i in range(tests))
    return f"import XCTest\n\nfinal class {name}: {base} {{\n{body}    func helper() {{}}\n}}\n"


class ClassesTests(unittest.TestCase):
    def test_finds_classes_in_subfolders_and_counts_their_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            _write(root, "Journeys/A.swift", _class("AJourneyTests", "UITestCase", 3))
            _write(root, "Journeys/Deep/B.swift", _class("BJourneyTests", "UITestCase", 1))
            _write(root, "Support/UITestCase.swift", "class UITestCase: XCTestCase {}\n")
            self.assertEqual(
                shards_module.classes(root, "UITestCase"),
                {"AJourneyTests": 3, "BJourneyTests": 1},
            )

    def test_reads_only_the_named_base_class(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            _write(root, "A.swift", _class("ATests", "TVUITestCase", 2))
            _write(root, "B.swift", _class("BTests", "UITestCase", 2))
            self.assertEqual(shards_module.classes(root, "TVUITestCase"), {"ATests": 2})

    def test_refuses_two_classes_in_one_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            _write(root, "A.swift", _class("ATests", "UITestCase", 1) + _class("BTests", "UITestCase", 1))
            with self.assertRaises(SystemExit):
                shards_module.classes(root, "UITestCase")


class ShardsTests(unittest.TestCase):
    def test_one_shard_runs_the_plan_as_it_is(self):
        self.assertEqual(
            shards_module.shards("T", {"A": 1, "B": 2}, 1),
            [{"index": 1, "count": 1, "tests": ""}],
        )

    def test_deals_the_largest_class_first_to_the_lightest_shard(self):
        result = shards_module.shards("T", {"A": 10, "B": 6, "C": 5, "D": 1}, 2)
        self.assertEqual([s["tests"] for s in result], ["T/A T/D", "T/B T/C"])
        self.assertEqual([(s["index"], s["count"]) for s in result], [(1, 2), (2, 2)])

    def test_every_class_lands_in_exactly_one_shard(self):
        weights = {f"C{i}": i % 7 + 1 for i in range(23)}
        result = shards_module.shards("T", weights, 2)
        named = [t for s in result for t in s["tests"].split()]
        self.assertEqual(sorted(named), sorted(f"T/{n}" for n in weights))


class MainTests(unittest.TestCase):
    def _run(self, root: pathlib.Path, *args: str) -> list:
        out = io.StringIO()
        with redirect_stdout(out):
            shards_module.main(list(args), root)
        return json.loads(out.getvalue())

    def test_prints_the_shards_of_the_named_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            _write(root, "Target/Journeys/A.swift", _class("ATests", "UITestCase", 2))
            _write(root, "Target/Journeys/B.swift", _class("BTests", "UITestCase", 2))
            result = self._run(root, "Target", "UITestCase", "2")
            self.assertEqual(sorted(s["tests"] for s in result), ["Target/ATests", "Target/BTests"])

    def test_refuses_more_shards_than_classes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            _write(root, "Target/A.swift", _class("ATests", "UITestCase", 2))
            with self.assertRaises(SystemExit):
                self._run(root, "Target", "UITestCase", "2")

    def test_refuses_a_target_with_no_classes(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                self._run(pathlib.Path(tmp), "Missing", "UITestCase", "1")

    def test_splits_this_repository_s_targets(self):
        root = HERE.parent.parent
        for target, base in [("DionysusPlayerUITests", "UITestCase"), ("DionysusTVUITests", "TVUITestCase")]:
            with self.subTest(target=target):
                result = self._run(root, target, base, "2")
                self.assertEqual(len(result), 2)
                self.assertTrue(all(s["tests"] for s in result))


if __name__ == "__main__":
    unittest.main()
