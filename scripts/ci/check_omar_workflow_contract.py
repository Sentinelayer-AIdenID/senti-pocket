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


# The canonical Omar workflow uses the existing legacy route with only the
# repository's OpenAI key. The action pin must include GPT-6 temperature
# handling; no Codex CLI, managed capacity, or alternate provider may run.
ALLOWED_ACTION_LINE = (
    "uses: mrrCarter/sentinelayer-v1-action@2d5a8edd485595148254926c9fb318e0adae416a"
)
ALLOWED_OPENAI_API_KEY_LINE = "openai_api_key: ${{ secrets.OPENAI_API_KEY }}"
ALLOWED_REVIEW_ROUTING_LINE = "review_routing: legacy"
ALLOWED_LLM_PROVIDER_LINE = "llm_provider: openai"
ALLOWED_MANAGED_LLM_LINE = 'sentinelayer_managed_llm: "false"'
ALLOWED_MODEL_LINE = "model: gpt-6.1-sol"
ALLOWED_CODEX_MODEL_LINE = "codex_model: gpt-6.1-sol"
ALLOWED_MODEL_FALLBACK_LINE = "model_fallback: gpt-6.1-sol"
ALLOWED_USE_CODEX_LINE = 'use_codex: "false"'
ALLOWED_CODEX_ONLY_LINE = 'codex_only: "false"'
ALLOWED_FAILURE_POLICY_LINE = "llm_failure_policy: block"
# One retry, and only this shape: after a billing or quota 429 the same action, model and contract run again on
# its backup endpoint. The dispatch drill and the org's Azure route (vars.OMAR_ROUTE is azure) skip the first
# attempt and run only that one. The key and the endpoint are secrets, so neither is ever printed in a log.
ALLOWED_RETRY_API_KEY_LINE = "openai_api_key: ${{ secrets.AZURE_SOL61_API_KEY }}"
ALLOWED_RETRY_BASE_URL_LINE = "OPENAI_BASE_URL: ${{ secrets.AZURE_SOL61_BASE_URL }}"
FIRST_ATTEMPT_IF_LINE = (
    "if: ${{ !(github.event_name == 'workflow_dispatch' && inputs.quota_retry_drill) && vars.OMAR_ROUTE != 'azure' }}"
)
CLASSIFY_ROUTE_LINE = "ROUTE: ${{ vars.OMAR_ROUTE || '' }}"
RETRY_IF_LINE = "if: ${{ steps.classify.outputs.retry == 'true' }}"
CONTINUE_ON_ERROR_LINE = "continue-on-error: true"
RESOLVE_FAIL_CLOSED_LINES = (
    "FIRST_OUTCOME: ${{ steps.omar.outcome }}",
    'if [ "${RETRIED}" != "true" ] && [ "${FIRST_OUTCOME}" != "success" ]; then',
    'echo "::error::The first Omar attempt did not succeed and was not retried (outcome: ${FIRST_OUTCOME}). Blocking merge."',
    "exit 1",
)
FIRST_ATTEMPT_READERS = (
    "name: Classify Omar provider failure",
    "name: Resolve the Omar result that counts",
)
COMMON_ACTION_INPUT_LINES = frozenset(
    {
        "review_routing: legacy",
        "llm_provider: openai",
        'sentinelayer_managed_llm: "false"',
        "model: gpt-6.1-sol",
        "codex_model: gpt-6.1-sol",
        "model_fallback: gpt-6.1-sol",
        'use_codex: "false"',
        'codex_only: "false"',
        "llm_failure_policy: block",
    }
)
TELEMETRY_LOG_DOWNLOAD_FRAGMENTS = (
    "curl --silent --show-error --location --fail-with-body",
    "--proto-redir '=https' --max-redirs 3",
    '--header "Authorization: Bearer ${GH_TOKEN}"',
    '"https://api.github.com/repos/${REPOSITORY}/actions/jobs/${job_id}/logs"',
)


def _step_blocks(job_lines: list[str]) -> list[list[str]]:
    starts = [index for index, line in enumerate(job_lines) if line.startswith("      - ")]
    return [job_lines[a:b] for a, b in zip(starts, starts[1:] + [len(job_lines)])]


def _uncommented(line: str) -> str:
    return line.split("#", 1)[0].strip()


def _step_keys(step: list[str]) -> set[str]:
    """The step's own keys ("id: omar", "if: ...", "uses: ..."), not the lines nested under with: or env:."""
    keys = {_uncommented(step[0][len("      - "):])}
    for line in step[1:]:
        if line.startswith("        ") and not line.startswith("         "):
            keys.add(_uncommented(line))
    return keys


def _nested_lines(step: list[str], block: str) -> set[str]:
    """The lines directly under the step's `with:` or `env:`."""
    header = f"        {block}"
    lines = [line.rstrip() for line in step]
    if header not in lines:
        return set()
    nested: set[str] = set()
    for line in lines[lines.index(header) + 1 :]:
        if not line.startswith("          "):
            break
        if not line.startswith("            "):
            nested.add(_uncommented(line))
    return nested


def _direct_sol_configured(omar_job_lines: list[str]) -> bool:
    action_steps = [
        step
        for step in _step_blocks(omar_job_lines)
        if any("sentinelayer-v1-action@" in _uncommented(line) for line in step)
    ]
    if len(action_steps) != 2:
        return False
    first, retry = action_steps
    first_keys, retry_keys = _step_keys(first), _step_keys(retry)
    if ALLOWED_ACTION_LINE not in first_keys or ALLOWED_ACTION_LINE not in retry_keys:
        return False
    # The first attempt: repo-owned OpenAI; its failure is judged by the steps after it, never ignored.
    if not {"id: omar", FIRST_ATTEMPT_IF_LINE, CONTINUE_ON_ERROR_LINE} <= first_keys:
        return False
    if not COMMON_ACTION_INPUT_LINES | {ALLOWED_OPENAI_API_KEY_LINE} <= _nested_lines(first, "with:"):
        return False
    if ALLOWED_RETRY_API_KEY_LINE in _nested_lines(first, "with:") or _nested_lines(first, "env:"):
        return False
    # The retry: only after a classified billing or quota 429 (or the dispatch drill, or the org's Azure route), and
    # its failure fails the job.
    if not {"id: omar_retry", RETRY_IF_LINE} <= retry_keys or CONTINUE_ON_ERROR_LINE in retry_keys:
        return False
    if not COMMON_ACTION_INPUT_LINES | {ALLOWED_RETRY_API_KEY_LINE} <= _nested_lines(retry, "with:"):
        return False
    if ALLOWED_OPENAI_API_KEY_LINE in _nested_lines(retry, "with:"):
        return False
    return _nested_lines(retry, "env:") == {ALLOWED_RETRY_BASE_URL_LINE}


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
        if "sentinelayer-v1-action@" in stripped and stripped != ALLOWED_ACTION_LINE:
            raise OmarWorkflowContractError(
                "Omar action must use the reviewed GPT-6-compatible pin"
            )
        if stripped.startswith("pr_number:"):
            raise OmarWorkflowContractError(
                "full Omar action workflow must not pass bridge-only pr_number"
            )
        if stripped.startswith("openai_api_key:") and stripped not in (
            ALLOWED_OPENAI_API_KEY_LINE,
            ALLOWED_RETRY_API_KEY_LINE,
        ):
            raise OmarWorkflowContractError(
                "openai_api_key must come from secrets.OPENAI_API_KEY (or secrets.AZURE_SOL61_API_KEY on the quota retry)"
            )
        if stripped.startswith("OPENAI_BASE_URL:") and stripped != ALLOWED_RETRY_BASE_URL_LINE:
            raise OmarWorkflowContractError(
                "OPENAI_BASE_URL may only be the AZURE_SOL61_BASE_URL secret on the quota retry"
            )
        if "vars.AZURE_SOL61_BASE_URL" in stripped:
            raise OmarWorkflowContractError(
                "the retry endpoint must come from secrets.AZURE_SOL61_BASE_URL: a variable is printed in step logs"
            )
        if stripped.startswith(
            (
                "anthropic_api_key:",
                "xai_api_key:",
                "google_api_key:",
                "typesafe_api_key:",
            )
        ):
            raise OmarWorkflowContractError(
                "direct OpenAI Omar workflow must not pass alternate provider keys"
            )
        if (
            stripped.startswith("review_routing:")
            and stripped != ALLOWED_REVIEW_ROUTING_LINE
        ):
            raise OmarWorkflowContractError("review_routing must remain legacy")
        if (
            stripped.startswith("llm_provider:")
            and stripped != ALLOWED_LLM_PROVIDER_LINE
        ):
            raise OmarWorkflowContractError(
                "llm_provider must be pinned to openai on the direct path"
            )
        if stripped.startswith("model:") and stripped != ALLOWED_MODEL_LINE:
            raise OmarWorkflowContractError("model must be pinned to gpt-6.1-sol")
        if stripped.startswith("codex_model:") and stripped != ALLOWED_CODEX_MODEL_LINE:
            raise OmarWorkflowContractError("codex_model must be pinned to gpt-6.1-sol")
        if (
            stripped.startswith("model_fallback:")
            and stripped != ALLOWED_MODEL_FALLBACK_LINE
        ):
            raise OmarWorkflowContractError(
                "model_fallback must be pinned to gpt-6.1-sol"
            )
        if (
            stripped.startswith("sentinelayer_managed_llm:")
            and stripped != ALLOWED_MANAGED_LLM_LINE
        ):
            raise OmarWorkflowContractError("sentinelayer_managed_llm must be false")
        if stripped.startswith("use_codex:") and stripped != ALLOWED_USE_CODEX_LINE:
            raise OmarWorkflowContractError("use_codex must be false")
        if stripped.startswith("codex_only:") and stripped != ALLOWED_CODEX_ONLY_LINE:
            raise OmarWorkflowContractError("codex_only must be false")
        if (
            stripped.startswith("llm_failure_policy:")
            and stripped != ALLOWED_FAILURE_POLICY_LINE
        ):
            raise OmarWorkflowContractError("llm_failure_policy must be block")

    if not _top_level_permissions_include_oidc_write(lines):
        raise OmarWorkflowContractError(
            "top-level permissions must include id-token: write for Omar telemetry and provenance"
        )

    omar_job_lines = _find_omar_review_job_lines(lines)
    if not _direct_sol_configured(omar_job_lines):
        raise OmarWorkflowContractError(
            "Omar review action must use repo-owned OpenAI Sol 6.1 on the legacy route, with one quota retry gated on the classifier"
        )
    if sum(_uncommented(line) == CONTINUE_ON_ERROR_LINE for line in omar_job_lines) != 1:
        raise OmarWorkflowContractError(
            "only the first Omar attempt may continue on error; every other Omar step must fail closed"
        )
    resolve_steps = [
        step
        for step in _step_blocks(omar_job_lines)
        if "name: Resolve the Omar result that counts" in _step_keys(step)
    ]
    _require(
        len(resolve_steps) == 1
        and all(
            fragment in {line.strip() for line in resolve_steps[0]}
            for fragment in RESOLVE_FAIL_CLOSED_LINES
        ),
        "a first Omar attempt that failed and was not retried must fail the job, whatever gate_status it wrote",
    )
    for step in _step_blocks(omar_job_lines):
        if any("steps.omar.outputs." in line for line in step) and not (
            _step_keys(step) & set(FIRST_ATTEMPT_READERS)
        ):
            raise OmarWorkflowContractError(
                "after the retry only the resolved result counts: read steps.result.outputs, not steps.omar.outputs"
            )
    if not _job_permissions_include_oidc_write(omar_job_lines):
        raise OmarWorkflowContractError(
            "jobs.omar-review.permissions must include id-token: write"
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
        "Validate Omar workflow contract",
        "check_forbidden_omar_surface.py --self-test",
        "check_forbidden_omar_surface.py",
        "Validate Omar provider secrets",
        "OPENAI_API_KEY is required for repo-owned Omar LLM scans",
        ALLOWED_ACTION_LINE,
        "Omar Gate",
        ALLOWED_OPENAI_API_KEY_LINE,
        ALLOWED_REVIEW_ROUTING_LINE,
        ALLOWED_LLM_PROVIDER_LINE,
        ALLOWED_MANAGED_LLM_LINE,
        ALLOWED_MODEL_LINE,
        ALLOWED_CODEX_MODEL_LINE,
        ALLOWED_MODEL_FALLBACK_LINE,
        ALLOWED_USE_CODEX_LINE,
        ALLOWED_CODEX_ONLY_LINE,
        ALLOWED_FAILURE_POLICY_LINE,
        "python3 .github/scripts/omar_quota_failure.py --self-test",
        "quota_retry_drill:",
        "Classify Omar provider failure",
        CLASSIFY_ROUTE_LINE,
        "reason=azure_route",
        "DRILL: ${{ github.event_name == 'workflow_dispatch' && inputs.quota_retry_drill && 'true' || 'false' }}",
        'python3 .github/scripts/omar_quota_failure.py "${findings}"',
        "reason=billing_quota_429",
        "Validate the quota retry route",
        ALLOWED_RETRY_API_KEY_LINE,
        ALLOWED_RETRY_BASE_URL_LINE,
        "Resolve the Omar result that counts",
        "GATE_STATUS: ${{ steps.result.outputs.gate_status || '' }}",
        "Assert Omar LLM contract is active",
        "REQUESTED_LLM_PROVIDER: openai",
        "REQUESTED_ROUTING: legacy",
        "REQUESTED_MODEL: gpt-6.1-sol",
        "REQUESTED_CODEX_MODEL: gpt-6.1-sol",
        "REQUESTED_FALLBACK_MODEL: gpt-6.1-sol",
        'REQUESTED_USE_CODEX: "false"',
        'REQUESTED_CODEX_ONLY: "false"',
        'REQUESTED_MANAGED_LLM: "false"',
        "REQUESTED_FAILURE_POLICY: block",
        "Omar LLM contract active",
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
      - name: Validate Omar workflow contract
        run: |
          python3 scripts/ci/check_omar_workflow_contract.py --self-test
          python3 scripts/ci/check_omar_workflow_contract.py
          python3 scripts/ci/check_forbidden_omar_surface.py --self-test
          python3 scripts/ci/check_forbidden_omar_surface.py
          python3 .github/scripts/omar_quota_failure.py --self-test
      - name: Validate Omar provider secrets
        run: |
          echo "SENTINELAYER_TOKEN is required for Omar Gate telemetry, artifacts, and PR checks."
          echo "OPENAI_API_KEY is required for repo-owned Omar LLM scans."
      - name: Omar Gate
        id: omar
        if: ${{ !(github.event_name == 'workflow_dispatch' && inputs.quota_retry_drill) && vars.OMAR_ROUTE != 'azure' }}
        continue-on-error: true
        uses: mrrCarter/sentinelayer-v1-action@2d5a8edd485595148254926c9fb318e0adae416a
        with:
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          review_routing: legacy
          llm_provider: openai
          sentinelayer_managed_llm: "false"
          model: gpt-6.1-sol
          codex_model: gpt-6.1-sol
          model_fallback: gpt-6.1-sol
          use_codex: "false"
          codex_only: "false"
          llm_failure_policy: block
      - name: Classify Omar provider failure
        id: classify
        env:
          ROUTE: ${{ vars.OMAR_ROUTE || '' }}
          DRILL: ${{ github.event_name == 'workflow_dispatch' && inputs.quota_retry_drill && 'true' || 'false' }}
          FIRST_FAILURE_CLASS: ${{ steps.omar.outputs.llm_failure_class || '' }}
        run: |
          echo "quota_retry_drill:"
          reason=azure_route
          python3 .github/scripts/omar_quota_failure.py "${findings}"
          reason=billing_quota_429
      - name: Validate the quota retry route
        if: ${{ steps.classify.outputs.retry == 'true' }}
        run: echo "route"
      - name: Omar Gate (quota retry)
        id: omar_retry
        if: ${{ steps.classify.outputs.retry == 'true' }}
        uses: mrrCarter/sentinelayer-v1-action@2d5a8edd485595148254926c9fb318e0adae416a
        env:
          OPENAI_BASE_URL: ${{ secrets.AZURE_SOL61_BASE_URL }}
        with:
          openai_api_key: ${{ secrets.AZURE_SOL61_API_KEY }}
          review_routing: legacy
          llm_provider: openai
          sentinelayer_managed_llm: "false"
          model: gpt-6.1-sol
          codex_model: gpt-6.1-sol
          model_fallback: gpt-6.1-sol
          use_codex: "false"
          codex_only: "false"
          llm_failure_policy: block
      - name: Resolve the Omar result that counts
        id: result
        env:
          FIRST_OUTCOME: ${{ steps.omar.outcome }}
          FIRST_GATE_STATUS: ${{ steps.omar.outputs.gate_status || '' }}
          RETRY_GATE_STATUS: ${{ steps.omar_retry.outputs.gate_status || '' }}
        run: |
          echo "resolved"
          if [ "${RETRIED}" != "true" ] && [ "${FIRST_OUTCOME}" != "success" ]; then
            echo "::error::The first Omar attempt did not succeed and was not retried (outcome: ${FIRST_OUTCOME}). Blocking merge."
            exit 1
          fi
      - name: Assert Omar LLM contract is active
        env:
          GATE_STATUS: ${{ steps.result.outputs.gate_status || '' }}
          REQUESTED_LLM_PROVIDER: openai
          REQUESTED_ROUTING: legacy
          REQUESTED_MODEL: gpt-6.1-sol
          REQUESTED_CODEX_MODEL: gpt-6.1-sol
          REQUESTED_FALLBACK_MODEL: gpt-6.1-sol
          REQUESTED_USE_CODEX: "false"
          REQUESTED_CODEX_ONLY: "false"
          REQUESTED_MANAGED_LLM: "false"
          REQUESTED_FAILURE_POLICY: block
        run: |
          echo "Omar LLM contract active"
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
    _assert_fails(valid.replace(TELEMETRY_LOG_DOWNLOAD_FRAGMENTS[2], "", 1))
    _assert_fails(
        valid.replace(
            "--location --fail-with-body",
            "--location-trusted --fail-with-body",
            1,
        )
    )

    # Bridge/broken action pin plus bridge-only pr_number must be rejected.
    _assert_fails(
        """
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
      - uses: mrrCarter/sentinelayer-v1-action@721bc7efe1402fcce416becea3d247b838119ed2
        with:
          pr_number: 259
          sentinelayer_managed_llm: "true"
"""
    )

    # Each independent route/model guard must fail if changed, even if the
    # workflow still includes all of the other expected evidence.
    mutations = (
        (
            ALLOWED_ACTION_LINE,
            "uses: mrrCarter/sentinelayer-v1-action@8afb7dbb42a5e1c25233d422c4cabe401ba02380",
        ),
        (ALLOWED_REVIEW_ROUTING_LINE, "review_routing: intent-cascade-v1"),
        (ALLOWED_LLM_PROVIDER_LINE, "llm_provider: anthropic"),
        (ALLOWED_MANAGED_LLM_LINE, 'sentinelayer_managed_llm: "true"'),
        (ALLOWED_MODEL_LINE, "model: gpt-4o"),
        (ALLOWED_CODEX_MODEL_LINE, "codex_model: gpt-4o"),
        (ALLOWED_MODEL_FALLBACK_LINE, "model_fallback: gemini-2.5-flash"),
        (ALLOWED_USE_CODEX_LINE, 'use_codex: "true"'),
        (ALLOWED_CODEX_ONLY_LINE, 'codex_only: "true"'),
        (ALLOWED_FAILURE_POLICY_LINE, "llm_failure_policy: warn"),
    )
    for original, replacement in mutations:
        assert original in valid
        _assert_fails(valid.replace(original, replacement, 1))

    # A commented model line elsewhere in the job does not configure the action.
    _assert_fails(
        valid.replace(
            "          model: gpt-6.1-sol", "          # model: gpt-6.1-sol", 1
        )
    )

    _run_retry_self_tests(valid)

    # Supplying an alternate-provider credential can bypass the intended
    # single-provider behavior, regardless of the selected model.
    _assert_fails(
        valid.replace(
            ALLOWED_OPENAI_API_KEY_LINE,
            ALLOWED_OPENAI_API_KEY_LINE
            + "\n          google_api_key: ${{ secrets.GOOGLE_API_KEY }}",
            1,
        )
    )


def _replace_last(text: str, old: str, new: str) -> str:
    head, sep, tail = text.rpartition(old)
    assert sep, old
    return head + new + tail


def _run_retry_self_tests(valid: str) -> None:
    retry_step = valid[valid.index("      - name: Omar Gate (quota retry)") : valid.index(
        "      - name: Resolve the Omar result that counts"
    )]
    breaks = {
        "the retry key on the first attempt": valid.replace(
            ALLOWED_OPENAI_API_KEY_LINE, ALLOWED_RETRY_API_KEY_LINE, 1
        ),
        "the primary key on the retry": _replace_last(valid, ALLOWED_RETRY_API_KEY_LINE, ALLOWED_OPENAI_API_KEY_LINE),
        "a retry not gated on the classifier": _replace_last(valid, "        " + RETRY_IF_LINE + "\n", ""),
        "a retry that may fail without failing the job": _replace_last(
            valid, "        id: omar_retry\n", "        id: omar_retry\n        continue-on-error: true\n"
        ),
        "the endpoint from a variable": valid.replace(
            ALLOWED_RETRY_BASE_URL_LINE, "OPENAI_BASE_URL: ${{ vars.AZURE_SOL61_BASE_URL }}", 1
        ),
        "an endpoint on the first attempt": valid.replace(
            "        continue-on-error: true\n        uses:",
            "        continue-on-error: true\n        env:\n          " + ALLOWED_RETRY_BASE_URL_LINE + "\n        uses:",
            1,
        ),
        "a third action step": valid.replace(retry_step, retry_step + retry_step.replace("id: omar_retry", "id: omar_retry_two"), 1),
        "no retry step at all": valid.replace(retry_step, "", 1),
        "a first attempt that fails the job by itself": valid.replace("        continue-on-error: true\n", "", 1),
        "a drill switch any event can set": valid.replace(
            FIRST_ATTEMPT_IF_LINE, "if: ${{ !inputs.quota_retry_drill }}", 1
        ),
        "a first attempt the org route does not skip": valid.replace(
            FIRST_ATTEMPT_IF_LINE, "if: ${{ !(github.event_name == 'workflow_dispatch' && inputs.quota_retry_drill) }}", 1
        ),
        "an org route the classifier does not read": valid.replace("          " + CLASSIFY_ROUTE_LINE + "\n", "", 1),
        "a later step that ignores its own failure": valid.replace(
            "      - name: Assert Omar LLM contract is active\n",
            "      - name: Assert Omar LLM contract is active\n        continue-on-error: true\n",
            1,
        ),
        "an unretried first-attempt failure that can pass on gate_status": valid.replace(
            '          if [ "${RETRIED}" != "true" ] && [ "${FIRST_OUTCOME}" != "success" ]; then\n'
            '            echo "::error::The first Omar attempt did not succeed and was not retried (outcome: ${FIRST_OUTCOME}). Blocking merge."\n'
            "            exit 1\n"
            "          fi\n",
            "",
            1,
        ),
        "the resolve step not reading the first attempt's outcome": valid.replace(
            "          FIRST_OUTCOME: ${{ steps.omar.outcome }}\n          FIRST_GATE_STATUS", "          FIRST_GATE_STATUS", 1
        ),
        "the assertion reading the first attempt": valid.replace(
            "GATE_STATUS: ${{ steps.result.outputs.gate_status || '' }}",
            "GATE_STATUS: ${{ steps.omar.outputs.gate_status || '' }}",
            1,
        ),
    }
    for name, broken in breaks.items():
        assert broken != valid, name
        try:
            _assert_fails(broken)
        except AssertionError as exc:
            raise AssertionError(f"{name}: {exc}") from exc
    # The retry runs the same model and contract as the first attempt.
    for line in COMMON_ACTION_INPUT_LINES:
        _assert_fails(_replace_last(valid, line, line.split(":", 1)[0] + ": changed"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify the senti-pocket Omar Gate workflow pins direct repo-owned OpenAI Sol 6.1."
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
    except OmarWorkflowContractError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
