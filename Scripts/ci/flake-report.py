#!/usr/bin/env python3
"""Reports how often CI needed a rerun and what failed, as Markdown.

    python3 Scripts/ci/flake-report.py --since 2026-10-12 [--until 2026-11-02]
        [--workflow pr-checks.yml ...] [--repo owner/name] [--no-logs]

The analysis behind the CI flake-reduction plan's Findings, kept so it can be
repeated after a change to see whether it helped. Per workflow it counts the
runs that finished as success or failure ("green first time": attempt 1 and
success; "needed a rerun": attempt > 1, `attempt` being the run's latest),
then, for every attempt that failed (all attempts of a failed run, all but
the last of a successful one), lists the failed jobs by name, the failing
tests by count (the lines after `Failing tests:` in the job log) and the
infrastructure signature by count (`xcodebuild_failure.classify`).

`--until` is inclusive, so a window is reproducible. `--no-logs` stops after
the table and the failed jobs, which needs no log downloads. Logs are cached
in a temp directory (`--cache-dir`) so a rerun of the report is quick.

Shells out to an authenticated `gh`; the parsing and counting below it are
pure and are what test_flake_report.py covers. Stdlib only.
"""

from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import date, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WORKFLOWS = ("pr-checks.yml", "nightly-ui-tests.yml", "release.yml")
DEFAULT_REPO = "imbenjamin/dionysus-player"

_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
_FAILING_TESTS_HEADER = re.compile(r"^Failing tests:\s*$")


def _classify(text: str) -> tuple[str, str | None]:
    spec = importlib.util.spec_from_file_location(
        "xcodebuild_failure", os.path.join(HERE, "xcodebuild_failure.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.classify(text)


def clean_log(raw: str) -> str:
    """The log without ANSI escapes and the leading timestamp of each line."""
    lines = (_TIMESTAMP.sub("", _ANSI.sub("", line)) for line in raw.splitlines())
    return "\n".join(lines)


def parse_log(raw: str) -> tuple[list[str], str | None]:
    """`(failing test names, infrastructure signature or None)` of one job log.

    The names are the indented lines after `Failing tests:`, once per name per
    log: xcodebuild prints the list again after a retry.
    """
    text = clean_log(raw)
    tests: list[str] = []
    in_list = False
    for line in text.splitlines():
        if _FAILING_TESTS_HEADER.match(line):
            in_list = True
        elif in_list and line[:1] in ("\t", " ") and line.strip():
            name = line.strip()
            if name not in tests:
                tests.append(name)
        elif in_list:
            in_list = False
    kind, signature = _classify(text)
    return tests, signature if kind == "infrastructure" else None


def failed_attempts(run: dict) -> list[int]:
    """Attempt numbers of a run that failed: all of a failed run's, all but the
    last of a successful one's."""
    if run["conclusion"] == "failure":
        return list(range(1, run["attempt"] + 1))
    return list(range(1, run["attempt"]))


def tally(runs: list[dict]) -> dict[str, dict[str, int]]:
    """Per workflow name: runs counted (success or failure), green first time,
    needed a rerun, and failed outright."""
    table: dict[str, dict[str, int]] = collections.OrderedDict()
    for run in sorted(runs, key=lambda r: r["workflowName"]):
        if run["conclusion"] not in ("success", "failure"):
            continue
        row = table.setdefault(
            run["workflowName"], {"runs": 0, "green": 0, "rerun": 0, "failed": 0}
        )
        row["runs"] += 1
        if run["attempt"] == 1 and run["conclusion"] == "success":
            row["green"] += 1
        if run["attempt"] > 1:
            row["rerun"] += 1
        if run["conclusion"] == "failure":
            row["failed"] += 1
    return table


def _counts_table(title: str, heading: str, counter: collections.Counter) -> list[str]:
    lines = [f"### {title}", ""]
    if not counter:
        return lines + ["None.", ""]
    lines += [f"| {heading} | Count |", "| --- | ---: |"]
    for name, count in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0])):
        escaped = name.replace("|", "\\|")
        lines.append(f"| {escaped} | {count} |")
    return lines + [""]


def render(
    window: str,
    table: dict[str, dict[str, int]],
    failed_jobs: collections.Counter,
    failing_tests: collections.Counter | None,
    signatures: collections.Counter | None,
) -> str:
    lines = [
        f"## CI flake report, {window}",
        "",
        "| Workflow | Runs | Green first time | Needed a rerun | Failed |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for name, row in table.items():
        lines.append(
            f"| {name} | {row['runs']} | {row['green']} | {row['rerun']} | {row['failed']} |"
        )
    lines.append("")
    lines += _counts_table("Failed jobs", "Job", failed_jobs)
    if failing_tests is None or signatures is None:
        lines += ["Failing tests and signatures need the job logs (omitted by `--no-logs`).", ""]
    else:
        lines += _counts_table("Failing tests", "Test", failing_tests)
        lines += _counts_table("Infrastructure signatures", "Signature", signatures)
    return "\n".join(lines)


# ---- the thin gh layer (untested) ----


def gh(*args: str, attempts: int = 3, backoff: float = 2.0) -> str:
    """Runs `gh`, trying again after a non-zero exit (a transient 5xx)."""
    for attempt in range(1, attempts + 1):
        result = subprocess.run(["gh", *args], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout
        if attempt == attempts:
            raise RuntimeError(f"gh {' '.join(args)}: {result.stderr.strip()}")
        time.sleep(backoff * attempt)
    raise AssertionError("unreachable")


def list_runs(workflow: str, since: str, until: str | None) -> list[dict]:
    # `--created` takes a range; the end date is exclusive of the day after.
    created = f">={since}"
    if until:
        end = date.fromisoformat(until) + timedelta(days=1)
        created = f"{since}..{end.isoformat()}"
    out = gh(
        "run", "list", "--workflow", workflow, "--limit", "200", "--created", created,
        "--json", "databaseId,workflowName,conclusion,attempt,createdAt",
    )
    runs = json.loads(out)
    if until:  # the range's end is a timestamp; keep the last day inclusive only
        runs = [r for r in runs if r["createdAt"][:10] <= until]
    return runs


def failed_jobs_of(repo: str, run_id: int, attempt: int) -> list[dict]:
    out = gh("api", f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
    return [
        j for j in json.loads(out)["jobs"] if j["conclusion"] in ("failure", "timed_out")
    ]


def job_log(repo: str, job_id: int, cache_dir: str) -> str:
    path = os.path.join(cache_dir, f"{job_id}.log")
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    text = gh("api", "--allow-escape-sequences", f"repos/{repo}/actions/jobs/{job_id}/logs")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return text


def default_repo(env: dict[str, str]) -> str:
    """The repository to read: `GH_REPO`, else the runner's `GITHUB_REPOSITORY`."""
    return env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or DEFAULT_REPO


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--since", required=True, help="YYYY-MM-DD")
    parser.add_argument("--until", help="YYYY-MM-DD, inclusive")
    parser.add_argument("--workflow", action="append", help="workflow file; repeatable")
    parser.add_argument("--repo", default=default_repo(os.environ),
                        help="owner/name; default $GH_REPO, then $GITHUB_REPOSITORY")
    parser.add_argument("--no-logs", action="store_true")
    parser.add_argument("--cache-dir", default=os.path.join(tempfile.gettempdir(), "flake-report-logs"))
    args = parser.parse_args(argv[1:])
    os.makedirs(args.cache_dir, exist_ok=True)

    runs: list[dict] = []
    for workflow in args.workflow or DEFAULT_WORKFLOWS:
        runs += list_runs(workflow, args.since, args.until)

    failed_jobs: collections.Counter = collections.Counter()
    tests: collections.Counter = collections.Counter()
    signatures: collections.Counter = collections.Counter()
    for run in runs:
        if run["conclusion"] not in ("success", "failure"):
            continue
        for attempt in failed_attempts(run):
            for job in failed_jobs_of(args.repo, run["databaseId"], attempt):
                failed_jobs[job["name"]] += 1
                if args.no_logs:
                    continue
                names, signature = parse_log(job_log(args.repo, job["id"], args.cache_dir))
                tests.update(names)
                if signature:
                    signatures[signature] += 1

    window = f"{args.since} to {args.until}" if args.until else f"since {args.since}"
    print(render(window, tally(runs), failed_jobs,
                 None if args.no_logs else tests, None if args.no_logs else signatures))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
