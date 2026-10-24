from __future__ import annotations

import argparse
import sys
from pathlib import Path


class OmarWorkflowContractError(ValueError):
    pass


BRIDGE_OR_BROKEN_MARKERS = (
    "GitHub App bridge",
    "thin GitHub App bridge",
    "Playwright + SBOM + model policy",
    "721bc7efe1402fcce416becea3d247b838119ed2",
    "fc444dee5bab4c79136775eb6930f1dea020d07c",
)


def _line_has_managed_llm_enabled(line: str) -> bool:
    normalized = line.split("#", 1)[0].strip().lower().replace("'", '"')
    return normalized in {
        'sentinelayer_managed_llm: "true"',
        "sentinelayer_managed_llm: true",
    }


# The canonical deep Omar Gate runs the released TypeSafe intent cascade. The
# cascade itself selects gpt-6-sol/max for unresolved reviews; the caller must
# not override model selection or silently fall back to a second legacy scan.
ALLOWED_OPENAI_API_KEY_LINE = "openai_api_key: ${{ secrets.OPENAI_API_KEY }}"
ALLOWED_TYPESAFE_API_KEY_LINE = "typesafe_api_key: ${{ secrets.TYPESAFE_API_KEY }}"
ALLOWED_INTENT_MODEL_PIN_LINE = "intent_model_pin: ${{ secrets.INTENT_MODEL_PIN }}"
ALLOWED_INTENT_POLICY_LINE = "intent_policy: ${{ secrets.INTENT_POLICY }}"
ALLOWED_LLM_PROVIDER_LINE = "llm_provider: typesafe"
ALLOWED_REVIEW_ROUTING_LINE = "review_routing: intent-cascade-v1"
ALLOWED_MANAGED_LLM_LINE = 'sentinelayer_managed_llm: "false"'
ALLOWED_CODEX_MODEL_LINE = "codex_model: gpt-6-sol"
ALLOWED_USE_CODEX_LINE = 'use_codex: "false"'
ALLOWED_PRICE_PROFILE_LINE = "intent_price_profile: typesafe-input-20261020"
ALLOWED_SCAN_MODE_LINE = "scan_mode: ${{ github.event_name == 'workflow_dispatch' && inputs.scan_mode || 'deep' }}"
TELEMETRY_LOG_DOWNLOAD_FRAGMENTS = (
    "curl --silent --show-error --location --fail-with-body",
    "--proto-redir '=https' --max-redirs 3",
    '--header "Authorization: Bearer ${GH_TOKEN}"',
    '"https://api.github.com/repos/${REPOSITORY}/actions/jobs/${job_id}/logs"',
)


def _repo_llm_configured(workflow_text: str) -> bool:
    return (
        ALLOWED_OPENAI_API_KEY_LINE in workflow_text
        and ALLOWED_TYPESAFE_API_KEY_LINE in workflow_text
        and ALLOWED_INTENT_MODEL_PIN_LINE in workflow_text
        and ALLOWED_INTENT_POLICY_LINE in workflow_text
        and ALLOWED_LLM_PROVIDER_LINE in workflow_text
        and ALLOWED_REVIEW_ROUTING_LINE in workflow_text
        and ALLOWED_MANAGED_LLM_LINE in workflow_text
        and ALLOWED_CODEX_MODEL_LINE in workflow_text
        and ALLOWED_USE_CODEX_LINE in workflow_text
        and ALLOWED_PRICE_PROFILE_LINE in workflow_text
        and ALLOWED_SCAN_MODE_LINE in workflow_text
    )


def _is_job_start(line: str) -> bool:
    stripped = line.strip()
    return (
        line.startswith("  ")
        and not line.startswith("    ")
        and stripped.endswith(":")
        and stripped[:-1].replace("_", "").replace("-", "").isalnum()
    )


def _find_omar_review_job_lines(lines: list[str]) -> list[str]:
    return _find_job_lines(lines, "omar-review")


def _find_job_lines(lines: list[str], job_id: str) -> list[str]:
    start = None
    for index, line in enumerate(lines):
        if line.rstrip() == f"  {job_id}:":
            start = index
            break

    if start is None:
        raise OmarWorkflowContractError(f"omar-gate.yml is missing jobs.{job_id}")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if _is_job_start(lines[index]):
            end = index
            break

    return lines[start:end]


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise OmarWorkflowContractError(message)


def _top_level_permissions_include_oidc_write(lines: list[str]) -> bool:
    permissions_start = None
    for index, line in enumerate(lines):
        if line.rstrip() == "permissions:":
            permissions_start = index
            break

    if permissions_start is None:
        return False

    for line in lines[permissions_start + 1 :]:
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        if not line.startswith("  "):
            break
        if line.split("#", 1)[0].strip() == "id-token: write":
            return True

    return False


def _job_permissions_include_oidc_write(job_lines: list[str]) -> bool:
    permissions_start = None
    for index, line in enumerate(job_lines):
        if line.rstrip() == "    permissions:":
            permissions_start = index
            break

    if permissions_start is None:
        return False

    for line in job_lines[permissions_start + 1 :]:
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        if not line.startswith("      "):
            break
        if line.split("#", 1)[0].strip() == "id-token: write":
            return True

    return False


def validate_omar_workflow_text(workflow_text: str) -> None:
    lines = workflow_text.splitlines()
    for marker in BRIDGE_OR_BROKEN_MARKERS:
        if marker in workflow_text:
            raise OmarWorkflowContractError(
                f"omar-gate.yml references bridge or broken Omar marker: {marker}"
            )

    for line in lines:
        stripped = line.split("#", 1)[0].strip()
        if stripped.startswith("pr_number:"):
            raise OmarWorkflowContractError(
                "full Omar action workflow must not pass bridge-only pr_number"
            )
        if stripped.startswith("openai_api_key:") and stripped != ALLOWED_OPENAI_API_KEY_LINE:
            raise OmarWorkflowContractError(
                "openai_api_key must come from secrets.OPENAI_API_KEY"
            )
        for input_name, allowed in (
            ("typesafe_api_key", ALLOWED_TYPESAFE_API_KEY_LINE),
            ("intent_model_pin", ALLOWED_INTENT_MODEL_PIN_LINE),
            ("intent_policy", ALLOWED_INTENT_POLICY_LINE),
            ("intent_price_profile", ALLOWED_PRICE_PROFILE_LINE),
            ("review_routing", ALLOWED_REVIEW_ROUTING_LINE),
            ("codex_model", ALLOWED_CODEX_MODEL_LINE),
            ("use_codex", ALLOWED_USE_CODEX_LINE),
            ("sentinelayer_managed_llm", ALLOWED_MANAGED_LLM_LINE),
            ("scan_mode", ALLOWED_SCAN_MODE_LINE),
        ):
            if line.startswith("          ") and stripped.startswith(f"{input_name}:") and stripped != allowed:
                raise OmarWorkflowContractError(f"{input_name} drifted from the pinned Omar cascade contract")
        if stripped.startswith(
            ("anthropic_api_key:", "xai_api_key:", "google_api_key:")
        ):
            raise OmarWorkflowContractError(
                "Omar cascade must not pass an unapproved provider key"
            )
        if stripped.startswith("llm_provider:") and stripped != ALLOWED_LLM_PROVIDER_LINE:
            raise OmarWorkflowContractError(
                "llm_provider must be pinned to typesafe"
            )
        if stripped.startswith(("model:", "model_fallback:")):
            raise OmarWorkflowContractError(
                "the intent cascade owns model selection; remove model overrides"
            )
        if stripped.startswith("comment_tag:"):
            raise OmarWorkflowContractError(
                "canonical Omar Gate must publish its untagged required check"
            )
        if stripped.startswith("publish_github:") and stripped != 'publish_github: "true"':
            raise OmarWorkflowContractError(
                "canonical Omar Gate must publish its PR check and comment"
            )

    managed_llm_enabled = any(_line_has_managed_llm_enabled(line) for line in lines)
    repo_llm_configured = _repo_llm_configured(workflow_text)
    if managed_llm_enabled or not repo_llm_configured:
        raise OmarWorkflowContractError(
            "omar-gate.yml must use the pinned TypeSafe intent cascade and repo-owned OpenAI handoff"
        )

    if not _top_level_permissions_include_oidc_write(lines):
        raise OmarWorkflowContractError(
            "top-level permissions must include id-token: write for managed/provenance-capable Omar scans"
        )

    omar_job_lines = _find_omar_review_job_lines(lines)
    if not _job_permissions_include_oidc_write(omar_job_lines):
        raise OmarWorkflowContractError(
            "jobs.omar-review.permissions must include id-token: write"
        )
    action_uses = [
        line.split("#", 1)[0].strip()
        for line in omar_job_lines
        if "sentinelayer-v1-action@" in line and line.lstrip().startswith("uses:")
    ]
    _require(
        action_uses == [
            "uses: Sentinelayer-AIdenID/sentinelayer-v1-action@e416dc53d2bc3177323d9717731dd07eaa59444d"
        ],
        "canonical Omar review must invoke the released cascade action exactly once",
    )
    for required_input in (
        ALLOWED_OPENAI_API_KEY_LINE,
        ALLOWED_TYPESAFE_API_KEY_LINE,
        ALLOWED_INTENT_MODEL_PIN_LINE,
        ALLOWED_INTENT_POLICY_LINE,
        ALLOWED_PRICE_PROFILE_LINE,
        ALLOWED_REVIEW_ROUTING_LINE,
        ALLOWED_LLM_PROVIDER_LINE,
        ALLOWED_MANAGED_LLM_LINE,
        ALLOWED_SCAN_MODE_LINE,
        ALLOWED_CODEX_MODEL_LINE,
        ALLOWED_USE_CODEX_LINE,
        'codex_only: "false"',
        "llm_failure_policy: block",
        "fork_policy: block",
        'publish_github: "true"',
    ):
        _require(
            any(line.split("#", 1)[0].strip() == required_input for line in omar_job_lines),
            f"canonical Omar review is missing required input: {required_input.split(':', 1)[0]}",
        )

    fork_job_lines = _find_job_lines(lines, "omar-fork-static")
    finalize_job_lines = _find_job_lines(lines, "omar-gate-finalize")
    fork_job_text = "\n".join(line.lower() for line in fork_job_lines)
    finalize_job_text = "\n".join(line.lower() for line in finalize_job_lines)

    for forbidden_fork_fragment in (
        "playwright baseline (fork fallback)",
        "npx playwright install --with-deps",
        "npm run test:e2e:baseline",
    ):
        if forbidden_fork_fragment in workflow_text.lower():
            raise OmarWorkflowContractError(
                f"fork fallback must not use browser baseline in place of deterministic no-secret checks: {forbidden_fork_fragment}"
            )

    _require(
        "persist-credentials: false" in fork_job_text,
        "fork static checkout must disable persisted credentials",
    )
    _require(
        "github.event.pull_request.head.repo.full_name" in fork_job_text
        and "github.event.pull_request.head.sha" in fork_job_text,
        "fork static checkout must read the untrusted pull request head explicitly",
    )
    _require(
        "run deterministic fork fallback checks" in fork_job_text,
        "fork static job must run deterministic fallback checks",
    )
    _require(
        "git ls-files" in fork_job_text and ".env" in fork_job_text,
        "fork static job must fail closed on tracked dotenv files",
    )
    _require(
        "needs: [omar-precheck, omar-review, omar-fork-static]" in finalize_job_text,
        "Omar Gate Finalize must depend on trusted and fork Omar jobs",
    )
    _require(
        "omar_review_result" in finalize_job_text
        and "omar_fork_static_result" in finalize_job_text,
        "Omar Gate Finalize must inspect trusted and fork job results",
    )
    _require(
        "::error::omar fork static result is" in finalize_job_text,
        "Omar Gate Finalize must fail closed when fork static checks fail",
    )
    _require(
        "::error::omar gate review result is" in finalize_job_text,
        "Omar Gate Finalize must fail closed when trusted Omar review fails",
    )

    forbidden_comment_fragments = (
        "wait_for_" + "authoritative" + "_omar_review.py",
        "sentinelayer-omar-" + "summary",
        "--summary-out",
        "--upsert" + "-comment",
    )
    for fragment in forbidden_comment_fragments:
        if fragment in workflow_text:
            raise OmarWorkflowContractError(
                f"omar-gate.yml must not require PR summary-comment evidence: {fragment}"
            )

    required_direct_fragments = (
        "Assert exact Omar source checkout",
        "ref: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || github.sha }}",
        "fetch-depth: 0",
        "persist-credentials: false",
        'if [ "${actual_source_sha}" != "${EXPECTED_SOURCE_SHA}" ]; then',
        "Reject tracked symlinks before Omar provider calls",
        'git ls-files --stage > "${index_file}"',
        "grep -q '^120000 '",
        "Validate Omar workflow contract",
        "check_omar_cascade_evidence.py --self-test",
        "check_forbidden_omar_surface.py --self-test",
        "check_forbidden_omar_surface.py",
        "Validate Omar provider secrets",
        "OPENAI_API_KEY is required for the Omar cascade deep-review handoff",
        "TypeSafe key, private model pin, and private review policy are required",
        "Sentinelayer-AIdenID/sentinelayer-v1-action@e416dc53d2bc3177323d9717731dd07eaa59444d",
        "Omar Gate",
        "openai_api_key: ${{ secrets.OPENAI_API_KEY }}",
        "typesafe_api_key: ${{ secrets.TYPESAFE_API_KEY }}",
        "intent_model_pin: ${{ secrets.INTENT_MODEL_PIN }}",
        "intent_policy: ${{ secrets.INTENT_POLICY }}",
        "intent_price_profile: typesafe-input-20261020",
        "review_routing: intent-cascade-v1",
        "llm_provider: typesafe",
        'sentinelayer_managed_llm: "false"',
        ALLOWED_SCAN_MODE_LINE,
        "codex_model: gpt-6-sol",
        'use_codex: "false"',
        'codex_only: "false"',
        "llm_failure_policy: block",
        "fork_policy: block",
        'publish_github: "true"',
        "Assert Omar cascade evidence and gate status",
        "check_omar_cascade_evidence.py",
        "python3 scripts/ci/check_omar_cascade_evidence.py \\",
        '--run-dir ".sentinelayer/runs/${RUN_ID}"',
        '--expected-head "${EXPECTED_SOURCE_SHA}"',
        "Omar deep cascade source scope complete; gate passed",
        "Omar Gate did not pass",
        "Resolve sanitized Omar artifact directory",
        'artifact_dir=".sentinelayer/runs/${normalized_run_id}"',
        "Upload Omar Gate artifacts",
        "actions/upload-artifact",
        "path: ${{ steps.artifact_path.outputs.artifact_dir }}",
        "Compute PR-scoped P2 count",
        "count_scoped_p2.py",
        "Enforce Omar reviewer merge thresholds",
        "WEB_PUSH_P2_MAX_ALLOWED",
        "Omar Gate merge threshold passed",
        "Emit Omar run summary",
        "merge_threshold",
        "Omar Gate Finalize",
        *TELEMETRY_LOG_DOWNLOAD_FRAGMENTS,
    )
    for fragment in required_direct_fragments:
        if fragment not in workflow_text:
            raise OmarWorkflowContractError(
                f"omar-gate.yml is missing direct Omar Gate evidence fragment: {fragment}"
            )

    _require(
        "--location-trusted" not in workflow_text,
        "telemetry job-log download must not forward authorization across origins",
    )


def _assert_fails(workflow_text: str) -> None:
    try:
        validate_omar_workflow_text(workflow_text)
    except OmarWorkflowContractError:
        return
    raise AssertionError("invalid Omar workflow should fail validation")


def _run_self_tests() -> None:
    valid = r"""
name: Omar Gate
permissions:
  contents: read
  id-token: write
jobs:
  omar-review:
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          ref: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || github.sha }}
          fetch-depth: 0
          persist-credentials: false
      - name: Assert exact Omar source checkout
        run: |
          if [ "${actual_source_sha}" != "${EXPECTED_SOURCE_SHA}" ]; then
            exit 1
          fi
      - name: Reject tracked symlinks before Omar provider calls
        run: |
          git ls-files --stage > "${index_file}"
          if grep -q '^120000 ' "${index_file}"; then
            exit 1
          fi
      - name: Validate Omar workflow contract
        run: |
          python3 scripts/ci/check_omar_workflow_contract.py --self-test
          python3 scripts/ci/check_omar_workflow_contract.py
          python3 scripts/ci/check_omar_cascade_evidence.py --self-test
          python3 scripts/ci/check_forbidden_omar_surface.py --self-test
          python3 scripts/ci/check_forbidden_omar_surface.py
      - name: Validate Omar provider secrets
        run: |
          echo "SENTINELAYER_TOKEN is required for Omar Gate telemetry, artifacts, and PR checks."
          echo "OPENAI_API_KEY is required for the Omar cascade deep-review handoff."
          echo "TypeSafe key, private model pin, and private review policy are required."
      - name: Omar Gate
        uses: Sentinelayer-AIdenID/sentinelayer-v1-action@e416dc53d2bc3177323d9717731dd07eaa59444d
        with:
          review_routing: intent-cascade-v1
          llm_provider: typesafe
          typesafe_api_key: ${{ secrets.TYPESAFE_API_KEY }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          intent_model_pin: ${{ secrets.INTENT_MODEL_PIN }}
          intent_policy: ${{ secrets.INTENT_POLICY }}
          intent_price_profile: typesafe-input-20261020
          sentinelayer_managed_llm: "false"
          scan_mode: ${{ github.event_name == 'workflow_dispatch' && inputs.scan_mode || 'deep' }}
          codex_model: gpt-6-sol
          use_codex: "false"
          codex_only: "false"
          llm_failure_policy: block
          fork_policy: block
          publish_github: "true"
      - name: Assert Omar cascade evidence and gate status
        run: |
          python3 scripts/ci/check_omar_cascade_evidence.py \
            --run-dir ".sentinelayer/runs/${RUN_ID}" \
            --expected-head "${EXPECTED_SOURCE_SHA}"
          echo "Omar deep cascade source scope complete; gate passed"
          echo "Omar Gate did not pass"
      - name: Resolve sanitized Omar artifact directory
        run: |
          artifact_dir=".sentinelayer/runs/${normalized_run_id}"
      - name: Upload Omar Gate artifacts
        uses: actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874
        with:
          path: ${{ steps.artifact_path.outputs.artifact_dir }}
      - name: Compute PR-scoped P2 count
        run: python3 .github/scripts/count_scoped_p2.py
      - name: Enforce Omar reviewer merge thresholds
        env:
          WEB_PUSH_P2_MAX_ALLOWED: "40"
        run: echo "Omar Gate merge threshold passed"
      - name: Emit Omar run summary
        run: echo "merge_threshold"
      - name: Assert Omar telemetry uploads
        run: |
          curl --silent --show-error --location --fail-with-body \
            --proto-redir '=https' --max-redirs 3 \
            --header "Authorization: Bearer ${GH_TOKEN}" \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2026-03-10" \
            --output "${log_file}" \
            "https://api.github.com/repos/${REPOSITORY}/actions/jobs/${job_id}/logs"
  omar-fork-static:
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          repository: ${{ github.event.pull_request.head.repo.full_name }}
          ref: ${{ github.event.pull_request.head.sha }}
          persist-credentials: false
      - name: Run deterministic fork fallback checks
        run: |
          git ls-files | grep -E '(^|/)\.env(\..+)?$'
  omar-gate-finalize:
    name: Omar Gate Finalize
    needs: [omar-precheck, omar-review, omar-fork-static]
    steps:
      - name: Consolidate Omar gate status
        env:
          OMAR_REVIEW_RESULT: success
          OMAR_FORK_STATIC_RESULT: success
        run: |
          echo "::error::Omar fork static result is bad"
          echo "::error::Omar Gate review result is bad"
"""
    validate_omar_workflow_text(valid)

    # Job logs can contain ANSI bytes and must be read before the parent run is
    # complete. Replacing the bounded job endpoint with either incompatible CLI
    # transport, or dropping its auth header, must fail the workflow contract.
    _assert_fails(
        valid.replace(
            TELEMETRY_LOG_DOWNLOAD_FRAGMENTS[0],
            'gh run view "${RUN_ID}" --repo "${REPOSITORY}" --log',
            1,
        )
    )
    _assert_fails(
        valid.replace(TELEMETRY_LOG_DOWNLOAD_FRAGMENTS[2], "", 1)
    )
    _assert_fails(
        valid.replace(
            "--location --fail-with-body",
            "--location-trusted --fail-with-body",
            1,
        )
    )

    # Every mutation starts from the valid cascade fixture, so each rejection
    # exercises one real contract rather than failing on unrelated missing data.
    for before, after in (
        ("Sentinelayer-AIdenID/sentinelayer-v1-action@e416dc53d2bc3177323d9717731dd07eaa59444d",
         "mrrCarter/sentinelayer-v1-action@8afb7dbb42a5e1c25233d422c4cabe401ba02380"),
        ("review_routing: intent-cascade-v1", "review_routing: legacy"),
        ("llm_provider: typesafe", "llm_provider: openai"),
        ("typesafe_api_key: ${{ secrets.TYPESAFE_API_KEY }}", "typesafe_api_key: ${{ secrets.OTHER_KEY }}"),
        ("intent_model_pin: ${{ secrets.INTENT_MODEL_PIN }}", ""),
        ("intent_policy: ${{ secrets.INTENT_POLICY }}", ""),
        ("intent_price_profile: typesafe-input-20261020", "intent_price_profile: future-alias"),
        ('sentinelayer_managed_llm: "false"', 'sentinelayer_managed_llm: "true"'),
        ("codex_model: gpt-6-sol", "codex_model: gpt-5.3-codex"),
        ('use_codex: "false"', 'use_codex: "true"'),
        ("llm_failure_policy: block", "llm_failure_policy: deterministic_only"),
        ("fork_policy: block", "fork_policy: allow"),
        ('publish_github: "true"', 'publish_github: "false"'),
        ("scan_mode: ${{ github.event_name == 'workflow_dispatch' && inputs.scan_mode || 'deep' }}",
         "scan_mode: pr-diff"),
        ("ref: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || github.sha }}",
         "ref: ${{ github.sha }}"),
        ("Assert exact Omar source checkout", "Source checkout unchecked"),
        ("Reject tracked symlinks before Omar provider calls", "Symlinks unchecked"),
        ('git ls-files --stage > "${index_file}"', 'echo skipped > "${index_file}"'),
        ("python3 scripts/ci/check_omar_cascade_evidence.py \\", "echo \\"),
        ("needs: [omar-precheck, omar-review, omar-fork-static]", "needs: [omar-precheck, omar-review]"),
    ):
        assert before in valid, before
        try:
            _assert_fails(valid.replace(before, after, 1))
        except AssertionError as exc:
            raise AssertionError(f"mutation passed validation: {before}") from exc

    # A second provider key, caller model override, or tagged report cannot
    # replace the single canonical required check.
    for extra in (
        "          google_api_key: ${{ secrets.GOOGLE_API_KEY }}\n",
        "          model: gpt-4o\n",
        "          model_fallback: gpt-4o\n",
        "          comment_tag: jev\n",
        "          pr_number: 259\n",
    ):
        _assert_fails(valid.replace("          review_routing: intent-cascade-v1\n",
                                    "          review_routing: intent-cascade-v1\n" + extra, 1))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify the canonical Pocket Omar Gate pins the released TypeSafe intent cascade."
    )
    parser.add_argument(
        "--workflow",
        default=".github/workflows/omar-gate.yml",
        help="Path to the Omar Gate workflow.",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        _run_self_tests()

    workflow_path = Path(args.workflow)
    try:
        validate_omar_workflow_text(workflow_path.read_text(encoding="utf-8"))
        parallel_jev = workflow_path.parent / "omar-gate-jev.yml"
        if parallel_jev.is_file():
            raise OmarWorkflowContractError(
                "parallel Omar Jev workflow would duplicate the canonical review"
            )
    except OmarWorkflowContractError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
