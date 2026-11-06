#!/usr/bin/env python3
"""Guard for the temporary split of known flaky room-list checks out of the gating job (ticket 9d7d62f1).

Warden, 2026-11-05: the b508c37d at-rest arrival check (with its paired follow-back) and the 96166f35 held-message
check fail often on PRs that do not touch the room list. Until their fix they run in LazyListKnownFlakyTests, in a job
of their own that reports without gating. This guard runs in the gating job and fails it when:

- it is past 2026-11-13 and the split is still here (the time box);
- a known flaky check (its marker, or its assertion) shows up in a gating test, or one has left its class;
- the class holds a test beyond its allow-list, or a test reaches it another way (an extension, or a test in the
  base class it inherits from);
- the workflow no longer skips the class in the gating job, or no longer runs it alone, without gating, in its own job.

Usage: known_flaky_guard.py [--root REPO] [--today YYYY-MM-DD]   (today defaults to the UTC date)
"""
from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re
import sys

TICKET = "9d7d62f1"
ENDS = dt.date(2026, 11, 13)
TESTS = pathlib.PurePosixPath("apps/SentiPocketApp/Tests")
FLAKY_CLASS = "LazyListKnownFlakyTests"
FLAKY_FILE = TESTS / f"{FLAKY_CLASS}.swift"
BASE_CLASS = "LazyListTestCase"
BASE_FILE = TESTS / f"{BASE_CLASS}.swift"
WORKFLOW = pathlib.PurePosixPath(".github/workflows/ios-verify.yml")
GATING_JOB = "hosted-app-tests"
FLAKY_JOB = "known-flaky-room-list"

# The only tests the non-gating class may hold.
ALLOWED_TESTS = {
    "test_b508c37d_another_arrival_builds_only_what_it_shows_and_the_room_follows_back",
    "test_96166f35_a_held_message_stays_in_view_as_messages_arrive_below",
}
# Each known flaky assertion carries its ticket's marker: how many of each the class holds.
MARKERS = {"[known-flaky b508c37d]": 2, "[known-flaky 96166f35]": 1}
# The assertions themselves, which no gating test may make again.
FLAKY_ASSERTIONS = (
    "another arrival: built",
    "followed the arrival back to its bottom",
    "stays in view as messages arrive below",
)
TEST_FUNC = re.compile(r"\bfunc\s+(test\w*)\s*\(")
ANOTHER_ARRIVAL_STEP = re.compile(r'\bstep\(\s*"another arrival"\s*,(?P<args>[^{]*)\{')


def read(root: pathlib.Path, path: pathlib.PurePosixPath) -> str | None:
    file = root / path
    return file.read_text(encoding="utf-8") if file.is_file() else None


def job_block(workflow: str, job: str) -> str | None:
    """The lines of one job under `jobs:` (two-space indent), up to the next job."""
    match = re.search(rf"^  {re.escape(job)}:\n(?P<body>(?:(?:    .*|[ \t]*)\n)*)", workflow, re.MULTILINE)
    return match.group("body") if match else None


def check(root: pathlib.Path, today: dt.date) -> list[str]:
    problems: list[str] = []
    flaky = read(root, FLAKY_FILE)
    if flaky is None:
        return [f"{FLAKY_FILE} is gone but the guard still runs: end the split whole (the job, this guard, the skip, "
                f"and the checks back into LazyListBuildTests), ticket {TICKET}"]

    # 1. The time box.
    if today > ENDS:
        problems.append(f"ticket {TICKET}: the known-flaky split ended on {ENDS.isoformat()} and is still here "
                        f"(today {today.isoformat()}). Put the checks back into the gating tests, or get a new date "
                        "from warden.")

    # 2. The class holds exactly its allow-listed tests, and no test reaches it any other way.
    classes = re.findall(r"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(\w+)", flaky, re.MULTILINE)
    if classes != [(FLAKY_CLASS, BASE_CLASS)]:
        problems.append(f"{FLAKY_FILE} must declare one class, {FLAKY_CLASS}: {BASE_CLASS}; it declares {classes}")
    tests = TEST_FUNC.findall(flaky)
    extra = sorted(set(tests) - ALLOWED_TESTS)
    missing = sorted(ALLOWED_TESTS - set(tests))
    if extra or len(tests) != len(set(tests)):
        problems.append(f"{FLAKY_CLASS} holds tests beyond its allow-list: {extra or tests} (ticket {TICKET} allows "
                        f"only {sorted(ALLOWED_TESTS)})")
    if missing:
        problems.append(f"{FLAKY_CLASS} lost allow-listed tests {missing}: end the split whole instead")
    for marker, count in MARKERS.items():
        if flaky.count(marker) != count:
            problems.append(f"{FLAKY_FILE} holds {flaky.count(marker)} checks marked {marker}, not {count}")
    base = read(root, BASE_FILE)
    if base is None:
        problems.append(f"{BASE_FILE} is missing")
    elif TEST_FUNC.search(base):
        problems.append(f"{BASE_FILE} holds a test ({TEST_FUNC.findall(base)}): it would run in {FLAKY_CLASS} too")

    # 3. No gating test makes a known flaky check, and nothing else adds tests to the split's classes.
    for file in sorted((root / TESTS.parts[0]).rglob("*.swift")) + sorted((root / "packages").rglob("*.swift")):
        relative = file.relative_to(root).as_posix()
        if relative == FLAKY_FILE.as_posix():
            continue
        text = file.read_text(encoding="utf-8", errors="replace")
        for marker in MARKERS:
            if marker in text:
                problems.append(f"{relative} holds {marker}: known flaky checks stay out of gating tests")
        for assertion in FLAKY_ASSERTIONS:
            if assertion in text:
                problems.append(f'{relative} makes the known flaky check "{assertion}" (ticket {TICKET}): it runs '
                                f"only in {FLAKY_CLASS}")
        for match in ANOTHER_ARRIVAL_STEP.finditer(text):
            if not re.search(r"\bmost:\s*nil\b", match.group("args")):
                problems.append(f'{relative}: the "another arrival" step checks a bound again; its bound is '
                                f"b508c37d's known flaky check (most: nil in gating tests)")
        if re.search(rf"\bextension\s+({FLAKY_CLASS}|{BASE_CLASS})\b", text):
            problems.append(f"{relative} extends {FLAKY_CLASS} or {BASE_CLASS}: tests could reach the split that way")
        if re.search(rf":\s*{FLAKY_CLASS}\b", text):
            problems.append(f"{relative} subclasses {FLAKY_CLASS}")

    # 4. The workflow: the gating job skips the class; its own job runs only it, without gating.
    workflow = read(root, WORKFLOW)
    gating = job_block(workflow, GATING_JOB) if workflow else None
    own = job_block(workflow, FLAKY_JOB) if workflow else None
    skip = f"-skip-testing:SentiPocketAppTests/{FLAKY_CLASS}"
    only = f"-only-testing:SentiPocketAppTests/{FLAKY_CLASS}"
    if gating is None or skip not in gating:
        problems.append(f"the gating job {GATING_JOB} does not skip {FLAKY_CLASS} ({skip})")
    if gating is not None and FLAKY_CLASS in gating.replace(skip, ""):
        problems.append(f"the gating job {GATING_JOB} names {FLAKY_CLASS} other than to skip it")
    if own is None:
        problems.append(f"no {FLAKY_JOB} job runs {FLAKY_CLASS}")
    else:
        if not re.search(r"^    continue-on-error:\s*true\s*$", own, re.MULTILINE):
            problems.append(f"the {FLAKY_JOB} job must not gate (continue-on-error: true)")
        if only not in own or re.findall(r"-only-testing:\S+", own) != [only]:
            problems.append(f"the {FLAKY_JOB} job must run {FLAKY_CLASS} alone ({only})")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".", type=pathlib.Path)
    parser.add_argument("--today", type=dt.date.fromisoformat,
                        default=dt.datetime.now(dt.timezone.utc).date())
    args = parser.parse_args(argv)
    problems = check(args.root.resolve(), args.today)
    for problem in problems:
        print(f"known-flaky guard: FAIL: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"known-flaky guard: OK. {FLAKY_CLASS} holds only {sorted(ALLOWED_TESTS)}; no gating test makes its "
          f"checks; the gating job skips it and {FLAKY_JOB} runs it without gating. Ends {ENDS.isoformat()} "
          f"(ticket {TICKET}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
