#!/usr/bin/env python3
"""Splits a UI test target's classes into balanced shards, one job each.

Used by .github/workflows/tv-ui-tests.yml (DionysusTVUITests) and
ui-tests.yml (DionysusPlayerUITests) to run a whole-class plan (TVUITests,
UITests-Full) as parallel jobs: in one job the Apple TV plan took about an
hour on a shared runner, and the iOS plan ran past its 150-minute limit on
the iPad and the iPhone Duo (#480), every test passing.

Every `final class … : <base class>` under the target's folder (subfolders
included) is one unit, weighted by its number of `func test…` methods, and
the classes are dealt largest first to the lightest shard. A new class is
picked up with no edit here.

    ui-test-shards.py <target> <base class> <shard count>
    ui-test-shards.py DionysusTVUITests TVUITestCase 4

prints a JSON array for a job matrix, one object per shard:
{"index": 1, "count": 4, "tests": "DionysusTVUITests/A DionysusTVUITests/B"}.
A shard count of 1 gives one shard with empty `tests`, which runs the plan
as it is (a plan that selects single tests, like UITests-Smoke, must not be
sharded: its classes would run whole).
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

TEST = re.compile(r"^\s*func (test\w*)\s*\(", re.MULTILINE)


def classes(folder: pathlib.Path, base: str) -> dict[str, int]:
    """Each test class under `folder` and its number of tests."""
    pattern = re.compile(rf"^final class (\w+)\s*:\s*{re.escape(base)}\b", re.MULTILINE)
    weights: dict[str, int] = {}
    for path in sorted(folder.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        names = pattern.findall(source)
        if len(names) > 1:
            sys.exit(f"{path}: one {base} class per file, so tests can be counted per class")
        if names:
            weights[names[0]] = len(TEST.findall(source))
    return weights


def shards(target: str, weights: dict[str, int], count: int) -> list[dict]:
    if count == 1:
        return [{"index": 1, "count": 1, "tests": ""}]
    bins: list[list[str]] = [[] for _ in range(count)]
    loads = [0] * count
    for name, weight in sorted(weights.items(), key=lambda item: (-item[1], item[0])):
        lightest = loads.index(min(loads))
        bins[lightest].append(name)
        loads[lightest] += weight
    return [
        {"index": i + 1, "count": count, "tests": " ".join(f"{target}/{n}" for n in sorted(names))}
        for i, names in enumerate(bins)
    ]


def main(argv: list[str], root: pathlib.Path) -> None:
    if len(argv) != 3:
        sys.exit("usage: ui-test-shards.py <target> <base class> <shard count>")
    target, base, count = argv[0], argv[1], int(argv[2])
    weights = classes(root / target, base)
    if not weights:
        sys.exit(f"no `final class … : {base}` under {target}/")
    if not 1 <= count <= len(weights):
        sys.exit(f"shard count must be 1–{len(weights)}, got {count}")
    print(json.dumps(shards(target, weights, count)))


if __name__ == "__main__":
    main(sys.argv[1:], pathlib.Path(__file__).resolve().parent.parent)
