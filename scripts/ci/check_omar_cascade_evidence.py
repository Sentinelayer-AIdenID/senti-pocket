"""Fail closed unless a passed deep cascade reviewed this exact source tree."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import tempfile
from pathlib import Path


class CascadeEvidenceError(ValueError):
    pass


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CascadeEvidenceError(message)


def validate_deep_evidence(run_dir: Path, repo_root: Path, expected_head: str) -> None:
    scope = json.loads((run_dir / "SOURCE_SCOPE.json").read_text(encoding="utf-8"))
    routing = json.loads((run_dir / "REVIEW_ROUTING.json").read_text(encoding="utf-8"))
    _require(isinstance(scope, dict) and isinstance(routing, dict), "deep evidence is malformed")
    _require(routing.get("source_scope") == scope, "routing evidence differs from source scope")
    _require(scope.get("schema") == "omargate.source-scope.v1", "unknown deep source-scope schema")
    _require(scope.get("complete") is True, "deep source review is incomplete")
    _require(not scope.get("reason_code"), "deep source review has a failure reason")

    manifest = scope.get("scope")
    _require(isinstance(manifest, dict), "deep source manifest is missing")
    _require(manifest.get("scan_mode") == "deep", "Omar did not review the full deep scope")
    _require(manifest.get("source_head") == expected_head, "reviewed source head differs from the event")
    hashes = manifest.get("source_hashes")
    _require(isinstance(hashes, dict) and bool(hashes), "deep source hashes are missing")
    root = repo_root.resolve()
    for name, digest in hashes.items():
        _require(isinstance(name, str) and isinstance(digest, str), "invalid source hash entry")
        relative = Path(name)
        _require(not relative.is_absolute() and ".." not in relative.parts, "source path escapes the checkout")
        path = root / relative
        _require(path.is_file() and not path.is_symlink(), "reviewed source file is missing or linked")
        _require(path.resolve().is_relative_to(root), "reviewed source path escapes the checkout")
        _require(hashlib.sha256(path.read_bytes()).hexdigest() == digest, "reviewed source bytes changed")

    planned = scope.get("planned_partitions")
    reviewed = scope.get("reviewed_partition_ids")
    completed = scope.get("partitions")
    _require(isinstance(planned, list) and bool(planned), "no deep partitions were planned")
    _require(isinstance(reviewed, list) and isinstance(completed, list), "deep partition ledger is missing")
    planned_ids = [row.get("partition_id") for row in planned if isinstance(row, dict)]
    _require(len(planned_ids) == len(planned) and all(isinstance(item, str) and item for item in planned_ids),
             "deep partition plan is malformed")
    _require(len(set(planned_ids)) == len(planned_ids), "deep partition plan has duplicate IDs")
    _require(reviewed == planned_ids, "not every planned deep partition was reviewed")
    _require(scope.get("attempted_partition_ids") == planned_ids, "not every deep partition was attempted")
    _require(scope.get("unattempted_partition_ids") == [], "unattempted deep partitions remain")
    _require(scope.get("residual_partition_ids") == [], "unreviewed deep partitions remain")
    _require(len(completed) == len(planned_ids), "deep partition receipts are incomplete")
    for expected_id, row in zip(planned_ids, completed):
        _require(isinstance(row, dict) and row.get("partition_id") == expected_id,
                 "deep partition receipt does not match the plan")
        _require(row.get("success") is True and row.get("output_valid") is True,
                 "deep partition review did not succeed")
        route = row.get("review_routing")
        _require(isinstance(route, dict) and isinstance(route.get("routes"), list) and bool(route["routes"]),
                 "deep partition has no cascade route evidence")
        _require(isinstance(route["routes"][-1], dict) and route["routes"][-1].get("success") is True,
                 "final deep partition route did not succeed")


def _self_test() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        source = root / "app.py"
        source.write_text("value = 1\n", encoding="utf-8")
        head = "a" * 40
        partition = "partition-1"
        scope = {
            "schema": "omargate.source-scope.v1", "complete": True, "reason_code": None,
            "scope": {"scan_mode": "deep", "source_head": head,
                      "source_hashes": {"app.py": hashlib.sha256(source.read_bytes()).hexdigest()}},
            "planned_partitions": [{"partition_id": partition}],
            "attempted_partition_ids": [partition], "reviewed_partition_ids": [partition],
            "unattempted_partition_ids": [], "residual_partition_ids": [],
            "partitions": [{"partition_id": partition, "success": True, "output_valid": True,
                            "review_routing": {"routes": [{"success": True}]}}],
        }
        run_dir = root / "run"
        run_dir.mkdir()

        def check(candidate: dict, *, should_pass: bool) -> None:
            (run_dir / "SOURCE_SCOPE.json").write_text(json.dumps(candidate), encoding="utf-8")
            (run_dir / "REVIEW_ROUTING.json").write_text(
                json.dumps({"source_scope": candidate}), encoding="utf-8")
            try:
                validate_deep_evidence(run_dir, root, head)
            except CascadeEvidenceError:
                assert not should_pass
            else:
                assert should_pass

        check(scope, should_pass=True)
        for field, invalid in (("complete", False), ("residual_partition_ids", [partition]),
                               ("reviewed_partition_ids", [])):
            candidate = copy.deepcopy(scope)
            candidate[field] = invalid
            check(candidate, should_pass=False)
        for field, invalid in (("source_head", "b" * 40), ("scan_mode", "pr-diff"),
                               ("source_hashes", {"app.py": "0" * 64})):
            candidate = copy.deepcopy(scope)
            candidate["scope"][field] = invalid
            check(candidate, should_pass=False)
        candidate = copy.deepcopy(scope)
        candidate["partitions"][0]["review_routing"]["routes"] = []
        check(candidate, should_pass=False)
        (run_dir / "REVIEW_ROUTING.json").write_text(
            json.dumps({"source_scope": {}}), encoding="utf-8")
        try:
            validate_deep_evidence(run_dir, root, head)
        except CascadeEvidenceError:
            pass
        else:
            raise AssertionError("mismatched deep routing evidence was accepted")
        source.write_text("value = 2\n", encoding="utf-8")
        check(scope, should_pass=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("--expected-head")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        _self_test()
        return 0
    if not args.run_dir or not args.expected_head:
        parser.error("--run-dir and --expected-head are required")
    try:
        validate_deep_evidence(args.run_dir, args.repo_root, args.expected_head)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"::error::Omar deep cascade evidence invalid: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
