#!/usr/bin/env python3
"""Decide whether a failed Omar Gate review failed only because the OpenAI account ran out of credit.

Reads the first attempt's FINDINGS.jsonl. Exits 0 when its LLM failure is a billing or quota 429
(insufficient_quota, credit_balance_exhausted, "no credits remaining") on every attempt, so the
workflow may retry the review once, with the same model, on its backup endpoint. Anything else exits 1 and
the failure stands: a rate limit, an auth error, a timeout, a mixed failure, no LLM failure at all,
or a file that cannot be read.

Run with --self-test to check these rules on fixed inputs.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from collections.abc import Iterable

QUOTA_MARKERS = ("insufficient_quota", "credit_balance_exhausted", "no credits remaining")


def _llm_failure_messages(lines: Iterable[str]) -> list[str]:
    messages = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict) and record.get("source") == "system" and record.get("category") == "LLM Failure":
            messages.append(str(record.get("message", "")))
    return messages


def _attempt_errors(message: str) -> list[str]:
    """Each attempt's error ("Primary failed: ...; Fallback failed: ..."), or the whole message."""
    lowered = message.lower()
    attempts = [part for part in re.split(r"\b(?:primary|fallback) failed:", lowered)[1:] if part.strip()]
    return attempts or [lowered]


def _is_quota(error: str) -> bool:
    return "429" in error and any(marker in error for marker in QUOTA_MARKERS)


def is_quota_failure(lines: Iterable[str]) -> bool:
    messages = _llm_failure_messages(lines)
    return bool(messages) and all(_is_quota(error) for message in messages for error in _attempt_errors(message))


def _record(message: str, source: str = "system", category: str = "LLM Failure") -> str:
    return json.dumps({"severity": "P0", "category": category, "source": source, "message": message})


QUOTA_ERROR = (
    "Error code: 429 - {'error': {'message': 'You have no credits remaining.', "
    "'type': 'insufficient_quota', 'param': None, 'code': 'credit_balance_exhausted'}}"
)


def _run_self_tests() -> None:
    cases = [
        ("both attempts out of credit",
         [_record(f"LLM analysis failed: Primary failed: {QUOTA_ERROR}; Fallback failed: {QUOTA_ERROR}. Blocking merge")],
         True),
        ("a single quota error", [_record(f"LLM analysis failed: {QUOTA_ERROR}")], True),
        ("unreadable lines around a quota error", ["not json", "[]", _record(f"Primary failed: {QUOTA_ERROR}")], True),
        ("the fallback timed out",
         [_record(f"LLM analysis failed: Primary failed: {QUOTA_ERROR}; Fallback failed: Request timed out.")],
         False),
        ("a rate limit is not a billing failure",
         [_record("Primary failed: Error code: 429 - {'error': {'type': 'requests', 'code': 'rate_limit_exceeded', "
                  "'message': 'Rate limit reached'}}")],
         False),
        ("an invalid key", [_record("Primary failed: Error code: 401 - {'error': {'code': 'invalid_api_key'}}")], False),
        ("a quota word without a 429", [_record("Primary failed: insufficient_quota reported by a proxy")], False),
        ("no LLM failure at all", [json.dumps({"severity": "P1", "category": "Injection", "source": "llm"})], False),
        ("an LLM failure not reported by the system", [_record(f"Primary failed: {QUOTA_ERROR}", source="llm")], False),
        ("an empty file", [], False),
    ]
    for name, lines, expected in cases:
        actual = is_quota_failure(lines)
        if actual != expected:
            raise AssertionError(f"{name}: expected {expected}, got {actual}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("findings", nargs="?", help="path to the first attempt's FINDINGS.jsonl")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        _run_self_tests()
        print("omar_quota_failure self-test passed")
        return 0
    if not args.findings:
        parser.error("a FINDINGS.jsonl path is required")
    try:
        lines = pathlib.Path(args.findings).read_text(encoding="utf-8").splitlines()
    except OSError:
        print("Omar first attempt: findings unreadable; no retry.")
        return 1
    if is_quota_failure(lines):
        print("Omar first attempt: billing or quota 429 on every attempt; retry once on the backup endpoint.")
        return 0
    print("Omar first attempt: not a billing or quota 429; no retry.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
