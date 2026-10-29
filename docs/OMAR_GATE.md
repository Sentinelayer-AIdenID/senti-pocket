# Omar Gate — Senti Pocket

The canonical [Omar Gate workflow](../.github/workflows/omar-gate.yml) uses the pinned full SentinelLayer Action. On trusted pushes and pull requests, its Deep Scan calls the repository's OpenAI key directly with `gpt-6.1-sol`. It selects `review_routing: legacy`, sets all model inputs to `gpt-6.1-sol`, disables Codex CLI and managed LLM routing, and blocks on LLM failure. No second provider or Jev cascade is configured.

`Omar Gate Precheck` keeps secrets away from fork pull requests. Forks run `Omar Gate Fork Static` against the untrusted head with persisted credentials disabled. `Omar Gate Finalize` consolidates the trusted scan or fork result and fails closed; this is the check to require in branch protection. Trusted scans also run `Telemetry Upload Assertion`.

When the first review fails only because the model account is out of credit (a billing or quota 429 on every attempt, as `.github/scripts/omar_quota_failure.py` decides from its findings), the job retries once. The retry uses the same action, model, and contract on the model's backup endpoint, whose key and URL are the `AZURE_SOL61_API_KEY` and `AZURE_SOL61_BASE_URL` secrets, so neither is printed. Any other failure, or a failed retry, fails the gate; there is no second retry. A `workflow_dispatch` run with `quota_retry_drill` reviews on the backup endpoint only, to prove that route. Pull requests and pushes cannot set it.

The workflow requires `OPENAI_API_KEY` for the direct model call and `SENTINELAYER_TOKEN` for Omar telemetry, artifacts, and PR checks. `SENTINELAYER_SPEC_ID` is an optional repository variable. On pull requests, the gate allows no P0/P1 findings and at most five P2 findings scoped to changed files. The push ceiling defaults to 40 P2 findings and can be set with `OMAR_PUSH_P2_MAX_ALLOWED` while the repository baseline is reduced.

Keep the Action on a reviewed full commit SHA and run `python3 scripts/ci/check_omar_workflow_contract.py --self-test` after changes to its route, model, or check topology. Enable the canonical workflow and require `Omar Gate Finalize` in GitHub before relying on it as a merge gate.
