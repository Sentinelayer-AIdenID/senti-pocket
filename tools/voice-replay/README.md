# VOICE-01 text routing replay

Node 22+, no dependencies. Offline text replay only. It never grants a floor,
opens a microphone, writes an answer, or changes a room. The committed fixture is
invented; the default synthetic router deliberately repeats the baseline. A
synthetic result is not Jev evidence.

```sh
node --test tools/voice-replay/*.test.mjs
node tools/voice-replay/cli.mjs
```

Each Unicode prefix adds 24 codepoints at a synthetic 250ms interval. Both lanes
see the same prefix. Last-named selects the last complete agent alias, or
`keep_listening`. The typed lane asks one CHOICE over available agents,
`keep_listening`, and `interrupt`. It uses version-pinned `jev-1.13.0`, a 250ms
deadline, a predeclared 600000ppm confidence threshold, and at most 200 router
attempts per run. These defaults are experimental, not calibrated thresholds.
Low confidence, ties, invalid answers, errors, late answers, and exhausted budget
fall back to that prefix's baseline. No retries occur.

Real data stays local. Put transcript-bearing files, derived datasets, and the
source-map JSON in `tools/voice-replay/local/` (gitignored). Never commit real
Carter/crew transcripts. Results default to gitignored `results/<run-id>/`.
Reports and signed records contain hashes, aggregate counts, and decision IDs,
never transcript, prior-context, provider-body, credential, or prompt text.
Do not point `--out` at an existing directory: runs are never overwritten.

Use `synthetic.json` as the dataset schema example. Each recorded session needs
its own immutable `source_sha256`, a whole-session `development` or `holdout`
split, at least two eligible agents with unique aliases, and turns in time order.
`start_us` and context `utc_us` are integer microseconds. Context must precede the
question and cannot reference its future reply. A first-reply label needs
`basis: "observed_first_reply"` and `reply_source_key`; it is an observational
proxy, not adjudicated ground truth. Exact normalized duplicate questions across
splits and duplicate source files are refused. This does not establish semantic
independence between related rooms. The source-map JSON maps session IDs to the
original local source paths; their exact file hashes are checked before a run.

Freeze the complete corpus, labels, split and final configuration before live
evaluation. Tune on development data only. Preparation makes no provider calls:

```sh
node tools/voice-replay/cli.mjs --live --prepare --input tools/voice-replay/local/corpus.private.json --source-map tools/voice-replay/local/source-map.private.json --split development --freeze tools/voice-replay/local/dev-freeze.json
node tools/voice-replay/cli.mjs --live --input tools/voice-replay/local/corpus.private.json --source-map tools/voice-replay/local/source-map.private.json --split development --freeze tools/voice-replay/local/dev-freeze.json
```

Set `TYPESAFE_API_KEY` privately in the process environment for the second command.
It is read only by the CLI live path. The endpoint is fixed to
`https://api.typesafe.ai/v1/systemone`, redirects are refused, and request/response
sizes are bounded. Source contract: [TypeSafe API](https://docs.typesafe.ai/api)
and [CHOICE](https://docs.typesafe.ai/primitives/choice). The confidence formula is
normalized maximum probability, not the probability that a route is correct.
Reported/computed confidence is checked with explicit rounding tolerance.

For final evaluation, prepare a separate freeze with `--split holdout` after
selecting the development configuration. A live holdout consumes a `*.consumed`
marker before dispatch; reusing the same freeze fails closed, even after an
interrupted run. Local markers prevent accidental reuse, not a malicious
operator from resetting the experiment. Config/corpus drift is refused.
The full-corpus hash, requested split and freeze-artifact hash are bound into
both signed lane manifests and the report, alongside the selected-split hash.

Every report puts baseline and typed-lane counts beside each other, by session
hash and split. Accuracy uses the final observed reply label; partial accuracy
uses that same final label and does not certify that an incomplete prefix was
answerable. Time-to-pick is the earliest *stable* correct suffix, with synthetic
prefix offset and measured request latency kept distinct. Wrong activations,
abstentions, flips, fallback reasons and call counts remain visible. A dispatch
count means attempted fetch invocations, not proof of receipt or billing.
Known usage totals and unknown usage attempts are separate; missing usage is
never treated as zero. Aborted calls may still be billed.

`last-named-record.json` and `signal-record.json` each use an Ed25519 hash chain
compatible with the Thermal `/verify` single-lane format. The first signed event
binds the run, lane and manifest; the last closes the count and final chain hash.
The local verifier additionally checks those expected bindings. Numeric signed
fields are integers; canonical JSON escapes Unicode to match Python. Each run
generates an ephemeral private key in memory and never persists it. The supplied
public key proves integrity only, not agent identity. Upload both records to the
existing `/verify` viewer for independent interoperability verification.

The harness always leaves `ticket_complete: false`: source tests, a verified
hash chain, or a good aggregate score cannot establish the ticket's independent
acceptance. VOICE-01 needs at least three suitable actual recorded sessions,
one whole-room holdout, measured comparison, and independent review. Audio and
live floor control are separate dependent work.
