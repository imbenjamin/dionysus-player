#!/usr/bin/env python3
"""Splits the Apple TV UI tests into balanced shards, one job each.

Used by .github/workflows/tv-ui-tests.yml to run a whole-class plan
(TVUITests) as parallel jobs: on a shared runner the full plan takes about
an hour in one job, which leaves its 90-minute limit no room for retries.

Every `final class … : TVUITestCase` in DionysusTVUITests/ is one unit,
weighted by its number of `func test…` methods, and the classes are dealt
largest first to the lightest shard. A new class is picked up with no edit
here.

    tv-ui-test-shards.py <shard count>

prints a JSON array for a job matrix, one object per shard:
{"index": 1, "count": 4, "tests": "DionysusTVUITests/A DionysusTVUITests/B"}.
A shard count of 1 gives one shard with empty `tests`, which runs the plan
as it is (a plan that selects single tests, like TVUITests-Smoke, must not
be sharded: its classes would run whole).
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

TARGET = "DionysusTVUITests"
CLASS = re.compile(r"^final class (\w+)\s*:\s*TVUITestCase\b", re.MULTILINE)
TEST = re.compile(r"^\s*func (test\w*)\s*\(", re.MULTILINE)


def classes(root: pathlib.Path) -> dict[str, int]:
    weights: dict[str, int] = {}
    for path in sorted((root / TARGET).glob("*.swift")):
        source = path.read_text(encoding="utf-8")
        names = CLASS.findall(source)
        if len(names) > 1:
            sys.exit(f"{path}: one TVUITestCase class per file, so tests can be counted per class")
        if names:
            weights[names[0]] = len(TEST.findall(source))
    return weights


def shards(weights: dict[str, int], count: int) -> list[dict]:
    if count == 1:
        return [{"index": 1, "count": 1, "tests": ""}]
    bins: list[list[str]] = [[] for _ in range(count)]
    loads = [0] * count
    for name, weight in sorted(weights.items(), key=lambda item: (-item[1], item[0])):
        lightest = loads.index(min(loads))
        bins[lightest].append(name)
        loads[lightest] += weight
    return [
        {"index": i + 1, "count": count, "tests": " ".join(f"{TARGET}/{n}" for n in sorted(names))}
        for i, names in enumerate(bins)
    ]


def main() -> None:
    count = int(sys.argv[1])
    weights = classes(pathlib.Path(__file__).resolve().parent.parent)
    if not 1 <= count <= len(weights):
        sys.exit(f"shard count must be 1–{len(weights)}, got {count}")
    print(json.dumps(shards(weights, count)))


if __name__ == "__main__":
    main()
