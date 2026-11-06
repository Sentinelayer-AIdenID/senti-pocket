#!/usr/bin/env python3
"""Synthetic tests for known_flaky_guard.py (ticket 9d7d62f1): it passes on the repository as it is, and fails on
each way the split could grow or leak, on a copy of the files it reads."""
from __future__ import annotations

import datetime as dt
import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "known_flaky_guard.py"
REPOSITORY_ROOT = MODULE_PATH.parents[2]
SPEC = importlib.util.spec_from_file_location("known_flaky_guard", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
guard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guard
SPEC.loader.exec_module(guard)

BEFORE_THE_END = dt.date(2026, 11, 6)
TESTS = Path("apps/SentiPocketApp/Tests")
FLAKY = TESTS / "LazyListKnownFlakyTests.swift"
BASE = TESTS / "LazyListTestCase.swift"
GATING = TESTS / "LazyListBuildTests.swift"
WORKFLOW = Path(".github/workflows/ios-verify.yml")


class KnownFlakyGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for relative in (FLAKY, BASE, GATING, WORKFLOW):
            (self.root / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY_ROOT / relative, self.root / relative)
        (self.root / "packages").mkdir()

    def edit(self, relative: Path, old: str, new: str) -> None:
        path = self.root / relative
        text = path.read_text(encoding="utf-8")
        self.assertEqual(text.count(old), 1, old)
        path.write_text(text.replace(old, new), encoding="utf-8")

    def problems(self, today: dt.date = BEFORE_THE_END) -> list[str]:
        return guard.check(self.root, today)

    def assertFailsWith(self, fragment: str, today: dt.date = BEFORE_THE_END) -> None:
        problems = self.problems(today)
        self.assertTrue(any(fragment in problem for problem in problems), f"{fragment!r} not in {problems}")

    def test_the_repository_as_it_is_passes(self) -> None:
        self.assertEqual(guard.check(REPOSITORY_ROOT, BEFORE_THE_END), [])
        self.assertEqual(self.problems(), [])

    def test_a_third_test_in_the_known_flaky_class_fails(self) -> None:
        self.edit(FLAKY, "    func test_96166f35_",
                  "    func test_another_flaky_check() throws {}\n\n    func test_96166f35_")
        self.assertFailsWith("holds tests beyond its allow-list: ['test_another_flaky_check']")

    def test_the_same_test_twice_fails(self) -> None:
        self.edit(FLAKY, "    func test_96166f35_a_held_message_stays_in_view_as_messages_arrive_below() throws {",
                  "    func test_96166f35_a_held_message_stays_in_view_as_messages_arrive_below() throws {}\n"
                  "    func test_96166f35_a_held_message_stays_in_view_as_messages_arrive_below(_ x: Int) throws {")
        self.assertFailsWith("holds tests beyond its allow-list")

    def test_a_test_in_the_base_class_fails(self) -> None:
        self.edit(BASE, "    func pump(", "    func test_runs_in_both_classes() {}\n\n    func pump(")
        self.assertFailsWith("holds a test (['test_runs_in_both_classes'])")

    def test_an_extension_adding_tests_to_the_class_fails(self) -> None:
        (self.root / TESTS / "More.swift").write_text(
            "extension LazyListKnownFlakyTests {\n    func test_more() {}\n}\n", encoding="utf-8")
        self.assertFailsWith("extends LazyListKnownFlakyTests or LazyListTestCase")

    def test_the_marker_in_a_gating_test_fails(self) -> None:
        self.edit(GATING, "// MARK: - The room\n", "// MARK: - The room\n    // [known-flaky b508c37d]\n")
        self.assertFailsWith("LazyListBuildTests.swift holds [known-flaky b508c37d]")

    def test_the_follow_back_check_back_in_a_gating_test_fails(self) -> None:
        self.edit(GATING, "            // Whether it followed back to its bottom is checked in LazyListKnownFlakyTests",
                  '            XCTAssertLessThan(0, 1, "the room followed the arrival back to its bottom")\n'
                  "            // Whether it followed back to its bottom is checked in LazyListKnownFlakyTests")
        self.assertFailsWith('makes the known flaky check "followed the arrival back to its bottom"')

    def test_the_held_message_check_back_in_a_gating_test_fails(self) -> None:
        self.edit(GATING, "        // Whether it stayed in view (moved less than half a screen)",
                  '        XCTAssertLessThan(moved, 1, "the held message stays in view as messages arrive below")\n'
                  "        // Whether it stayed in view (moved less than half a screen)")
        self.assertFailsWith('makes the known flaky check "stays in view as messages arrive below"')

    def test_the_another_arrival_bound_back_in_a_gating_test_fails(self) -> None:
        self.edit(GATING, 'step("another arrival", rows: rows, list: .roomRow, most: nil) {',
                  'step("another arrival", rows: rows, list: .roomRow) {')
        self.assertFailsWith('the "another arrival" step checks a bound again')

    def test_a_check_leaving_the_known_flaky_class_fails(self) -> None:
        self.edit(FLAKY, " [known-flaky 96166f35]", "")
        self.assertFailsWith("holds 0 checks marked [known-flaky 96166f35], not 1")

    def test_the_gating_tests_running_the_class_fails(self) -> None:
        self.edit(WORKFLOW, "          -skip-testing:SentiPocketAppTests/LazyListKnownFlakyTests\n", "")
        self.assertFailsWith('the gating step "Run hosted unit tests" does not skip LazyListKnownFlakyTests')

    def test_the_known_flaky_step_before_the_gating_tests_fails(self) -> None:
        path = self.root / WORKFLOW
        text = path.read_text(encoding="utf-8")
        start = text.index("      - name: Known flaky room-list checks")
        end = text.index("      - name: Upload XCTest result bundle")
        step = text[start:end]
        text = text[:start] + text[end:]
        gating = text.index("      - name: Run hosted unit tests")
        path.write_text(text[:gating] + step + text[gating:], encoding="utf-8")
        self.assertFailsWith('the LazyListKnownFlakyTests step must come after "Run hosted unit tests"')

    def test_the_known_flaky_step_skipped_when_the_gating_tests_fail_fails(self) -> None:
        self.edit(WORKFLOW, "        if: always()\n        continue-on-error: true\n", "        continue-on-error: true\n")
        self.assertFailsWith("must run even when the gating tests fail (if: always())")

    def test_the_known_flaky_step_gating_fails(self) -> None:
        self.edit(WORKFLOW, "        continue-on-error: true\n", "")
        self.assertFailsWith("must not gate (continue-on-error: true)")

    def test_the_known_flaky_step_without_its_timeout_fails(self) -> None:
        self.edit(WORKFLOW, "        timeout-minutes: 10\n", "        timeout-minutes: 30\n")
        self.assertFailsWith("must stop after 10 minutes (timeout-minutes: 10)")

    def test_the_known_flaky_step_running_more_than_the_class_fails(self) -> None:
        self.edit(WORKFLOW, "            -only-testing:SentiPocketAppTests/LazyListKnownFlakyTests \\\n",
                  "            -only-testing:SentiPocketAppTests/LazyListKnownFlakyTests \\\n"
                  "            -only-testing:SentiPocketAppTests/LazyListBuildTests \\\n")
        self.assertFailsWith("must run that class alone, with one target")

    def test_another_job_running_the_class_fails(self) -> None:
        path = self.root / WORKFLOW
        path.write_text(path.read_text(encoding="utf-8") + (
            "\n  known-flaky-again:\n    runs-on: macos-26\n    steps:\n      - name: Again\n"
            "        run: xcodebuild -only-testing:SentiPocketAppTests/LazyListKnownFlakyTests test\n"),
            encoding="utf-8")
        self.assertFailsWith("the workflow names LazyListKnownFlakyTests outside its step")

    def test_after_the_thirteenth_the_split_fails_with_the_ticket(self) -> None:
        self.assertEqual(self.problems(dt.date(2026, 11, 13)), [], "the last day still passes")
        self.assertFailsWith("ticket 9d7d62f1: the known-flaky split ended on 2026-11-13", dt.date(2026, 11, 14))

    def test_the_class_gone_while_the_guard_runs_fails(self) -> None:
        (self.root / FLAKY).unlink()
        self.assertFailsWith("end the split whole")

    def test_the_command_line_exit_codes(self) -> None:
        self.assertEqual(guard.main(["--root", str(self.root), "--today", "2026-11-06"]), 0)
        self.assertEqual(guard.main(["--root", str(self.root), "--today", "2026-11-14"]), 1)


if __name__ == "__main__":
    unittest.main()
