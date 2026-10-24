import { randomUUID } from 'node:crypto';
import { validateDataset, partials, lastNamed, routerInput } from './dataset.mjs';
import { DecisionLog, hash, verifyDecisionDocument } from './record.mjs';

const DEFAULTS = Object.freeze({ partialMs: 250, charsPerPartial: 24, deadlineMs: 250,
  confidencePpm: 600000, maxCalls: 200, model: 'jev-1.13.0', mode: 'synthetic' });
const rate = (a, b) => b ? Math.round(a / b * 1000000) : null;
const counters = () => ({ turns: 0, partials: 0, correct_final: 0, final_accuracy_ppm: null,
  correct_partials: 0, partial_accuracy_ppm: null, abstentions: 0, wrong_activations: 0,
  flips: 0, stable_correct_picks: 0, stable_pick_offset_ms_total: 0, stable_pick_with_latency_ms_total: 0 });

function score(counter, decisions, target) {
  counter.turns++; counter.partials += decisions.length;
  counter.correct_final += Number(decisions.at(-1).choice === target);
  let stable = decisions.length;
  for (let i = decisions.length - 1; i >= 0 && decisions[i].choice === target; i--) stable = i;
  if (stable < decisions.length) {
    counter.stable_correct_picks++;
    counter.stable_pick_offset_ms_total += decisions[stable].offset_ms;
    counter.stable_pick_with_latency_ms_total += decisions[stable].offset_ms + decisions[stable].latency_ms;
  }
  decisions.forEach((decision, i) => {
    counter.correct_partials += Number(decision.choice === target);
    counter.abstentions += Number(decision.choice === 'keep_listening');
    counter.wrong_activations += Number(decision.choice !== 'keep_listening' && decision.choice !== target);
    counter.flips += Number(i > 0 && decision.choice !== decisions[i - 1].choice);
  });
  counter.final_accuracy_ppm = rate(counter.correct_final, counter.turns);
  counter.partial_accuracy_ppm = rate(counter.correct_partials, counter.partials);
}

export function validateConfig(options) {
  if (Object.keys(options).some((key) => !Object.hasOwn(DEFAULTS, key))) throw new Error('invalid_config');
  const config = { ...DEFAULTS, ...options };
  for (const key of ['partialMs', 'charsPerPartial', 'deadlineMs', 'confidencePpm', 'maxCalls']) {
    if (!Number.isSafeInteger(config[key])) throw new Error('invalid_config');
  }
  if (config.partialMs < 1 || config.partialMs > 10000 || config.deadlineMs < 1 || config.deadlineMs > config.partialMs ||
      config.charsPerPartial < 1 || config.charsPerPartial > 8000 || config.confidencePpm < 0 || config.confidencePpm > 1000000 ||
      config.maxCalls < 0 || config.maxCalls > 10000 || config.model !== 'jev-1.13.0' ||
      !['synthetic', 'typesafe-live'].includes(config.mode)) throw new Error('invalid_config');
  return config;
}

function validChoice(result, criteria, model) {
  const keys = Object.keys(criteria), probabilities = result?.probabilities;
  if (result?.ok !== true || result.model !== model || !Object.hasOwn(criteria, result.choice) || !probabilities ||
      Object.keys(probabilities).length !== keys.length || !keys.every((key) => Object.hasOwn(probabilities, key) &&
        Number.isFinite(probabilities[key]) && probabilities[key] >= 0 && probabilities[key] <= 1) ||
      !Number.isFinite(result.effectiveConfidence) || result.effectiveConfidence < 0 || result.effectiveConfidence > 1) return false;
  const sum = keys.reduce((acc, key) => acc + probabilities[key], 0);
  const max = Math.max(...keys.map((key) => probabilities[key]));
  const ties = keys.filter((key) => probabilities[key] === max);
  const computed = Math.max(0, (max - 1 / keys.length) / (1 - 1 / keys.length));
  return Math.abs(sum - 1) <= 0.01 && ties.length === 1 && ties[0] === result.choice &&
    result.effectiveConfidence <= computed + 0.025;
}

async function boundedCall(router, input, deadlineMs, clock) {
  const start = clock(); let timer;
  try {
    const result = await Promise.race([
      Promise.resolve().then(() => router(input)),
      new Promise((resolve) => { timer = setTimeout(() => resolve({ ok: false }), deadlineMs); }),
    ]);
    const latency = Math.ceil(Math.max(0, clock() - start));
    return { result, latency_ms: latency, late: latency >= deadlineMs };
  } catch { return { result: null, latency_ms: Math.ceil(Math.max(0, clock() - start)), late: false }; }
  finally { clearTimeout(timer); }
}

/** Sequential offline prefixes, not an audio/STT scheduler. No state-changing room operation exists here. */
export async function replay(input, { router, runId = randomUUID(), config: supplied = {},
  verifiedSourceHashes = [], evaluationBinding = null, clock = () => performance.now(), recordClock = Date.now } = {}) {
  const dataset = validateDataset(input), config = validateConfig(supplied);
  if (typeof router !== 'function') throw new Error('router_required');
  const totalPartials = dataset.sessions.reduce((sum, session) => sum + session.turns.reduce((n, turn) =>
    n + Math.ceil([...turn.text].length / config.charsPerPartial), 0), 0);
  if (totalPartials > 20000) throw new Error('replay_too_large');
  evaluationBinding = structuredClone(evaluationBinding);
  if (evaluationBinding !== null && (Object.keys(evaluationBinding).sort().join(',') !== 'freeze_hash,full_corpus_hash,requested_split' ||
      !/^[0-9a-f]{64}$/.test(evaluationBinding.freeze_hash) || !/^[0-9a-f]{64}$/.test(evaluationBinding.full_corpus_hash) ||
      !['development', 'holdout'].includes(evaluationBinding.requested_split) ||
      dataset.sessions.some((s) => s.split !== evaluationBinding.requested_split))) throw new Error('invalid_evaluation_binding');
  const dispatchStart = typeof router.getDispatchCount === 'function' ? router.getDispatchCount() : null;
  const manifest = {
    schema: 'voice-replay.run.v1', dataset_hash: hash(dataset), config, config_hash: hash(config), evaluation_binding: evaluationBinding,
    source_hashes: dataset.sessions.map((s) => s.source_sha256).sort(),
    split_hash: hash(dataset.sessions.map((s) => ({ session_hash: hash(s.session_id), split: s.split, source_hash: s.source_sha256 }))),
    label_hash: hash(dataset.sessions.map((s) => s.turns.map((t) => ({ source_hash: hash(t.source_key), label: t.label })))),
    timing: 'synthetic_unicode_prefix_schedule_plus_measured_request_latency',
    label_interpretation: 'observed_first_reply_is_a_proxy_not_ground_truth',
  };
  const baselineLog = new DecisionLog({ runId, laneId: 'last_named', manifest, clock: recordClock });
  const signalLog = new DecisionLog({ runId, laneId: 'signal', manifest, clock: recordClock });
  const partitions = Object.fromEntries(['development', 'holdout'].map((split) => [split, { baseline: counters(), signal: counters() }]));
  const reasons = {}; let calls = 0, dispatched = 0, knownUsage = 0, inputTokens = 0, outputTokens = 0, unknownUsage = 0;
  const perSession = [];
  for (const session of dataset.sessions) {
    const counts = { baseline: counters(), signal: counters() };
    for (const turn of session.turns) {
      const baselineDecisions = [], signalDecisions = [];
      for (const partial of partials(turn.text, config)) {
        const state = routerInput(session, turn, partial.prefix);
        const baseline = lastNamed(partial.prefix, session.agents);
        let choice = baseline, reason = 'call_cap', latency = 0, response = null;
        if (calls < config.maxCalls) {
          calls++;
          const observed = await boundedCall(router, state, config.deadlineMs, clock);
          latency = observed.latency_ms; response = observed.result;
          if (response?.dispatched === true) dispatched++;
          if (observed.late) reason = 'deadline';
          else if (!validChoice(response, state.criteria, config.model)) reason = 'invalid_or_unavailable';
          else if (Math.round(response.effectiveConfidence * 1000000) < config.confidencePpm) reason = 'low_confidence';
          else { choice = response.choice; reason = 'typed_choice'; }
          const usage = response?.usage;
          if (Number.isSafeInteger(usage?.input_tokens) && usage.input_tokens >= 0 &&
              Number.isSafeInteger(usage?.output_tokens) && usage.output_tokens >= 0) {
            knownUsage++; inputTokens += usage.input_tokens; outputTokens += usage.output_tokens;
          } else unknownUsage++;
        }
        reasons[reason] = (reasons[reason] || 0) + 1;
        const base = { choice: baseline, offset_ms: partial.offset_ms, latency_ms: 0 };
        const signal = { choice, offset_ms: partial.offset_ms, latency_ms: latency };
        baselineDecisions.push(base); signalDecisions.push(signal);
        const common = { session_hash: hash(session.session_id), turn_hash: hash(turn.source_key),
          input_hash: hash(state), partial_hash: hash(partial.prefix), offset_ms: partial.offset_ms, final: partial.final };
        baselineLog.append('routing_decision', { ...common, output_hash: hash(base), ...base });
        signalLog.append('routing_decision', { ...common, output_hash: hash(signal), ...signal, reason,
          reported_answer_hash: response ? hash({ choice: typeof response.choice === 'string' ? response.choice : null,
            confidence_text: Number.isFinite(response.effectiveConfidence) ? String(response.effectiveConfidence) : null }) : null });
      }
      for (const [lane, decisions] of [['baseline', baselineDecisions], ['signal', signalDecisions]]) {
        score(counts[lane], decisions, turn.label.target); score(partitions[session.split][lane], decisions, turn.label.target);
      }
    }
    perSession.push({ session_hash: hash(session.session_id), source_hash: session.source_sha256,
      source_kind: session.source_kind, split: session.split, ...counts });
  }
  const recorded = dataset.sessions.filter((s) => s.source_kind === 'recorded');
  const verified = new Set(verifiedSourceHashes);
  const dispatchEnd = typeof router.getDispatchCount === 'function' ? router.getDispatchCount() : null;
  const dispatchCountComplete = config.mode === 'synthetic' || (Number.isSafeInteger(dispatchStart) &&
    Number.isSafeInteger(dispatchEnd) && dispatchEnd >= dispatchStart && dispatchEnd - dispatchStart <= calls);
  const providerCalls = config.mode === 'synthetic' ? 0 : dispatchCountComplete ? dispatchEnd - dispatchStart : null;
  const report = { schema: 'voice-replay.report.v1', run_id: runId, manifest_hash: hash(manifest),
    config, dataset_hash: manifest.dataset_hash, source_hashes: manifest.source_hashes, evaluation_binding: evaluationBinding,
    mode: config.mode, total_partials: totalPartials, router_attempts: calls, provider_calls: providerCalls, call_cap: config.maxCalls,
    dispatch_count_complete: dispatchCountComplete, returned_dispatched_calls: dispatched, reasons,
    usage: { known_responses: knownUsage, unknown_responses: unknownUsage, known_input_tokens: inputTokens, known_output_tokens: outputTokens,
      input_tokens: unknownUsage ? null : inputTokens, output_tokens: unknownUsage ? null : outputTokens },
    partitions, sessions: perSession,
    evidence: { recorded_sessions: recorded.length, recorded_holdout_sessions: recorded.filter((s) => s.split === 'holdout').length,
      source_files_hash_verified: recorded.length > 0 && recorded.every((s) => verified.has(s.source_sha256)),
      three_recorded_sessions: recorded.length >= 3, synthetic_only: recorded.length === 0,
      freeze_artifact_bound: evaluationBinding !== null, independent_labels_verified: false, browser_verification: 'pending', ticket_complete: false,
      identityVerified: false, keyTrust: 'self-supplied-integrity-only' },
    limitations: ['Synthetic text timing is not STT latency.', 'First observed reply is a proxy, not an adjudicated speaker label.',
      'Threshold is predeclared, not calibrated.', 'No held-out independence or routing improvement is certified by this harness.',
      'Aborted requests may still incur provider usage. Missing usage is unknown, not zero.'],
  };
  for (const log of [baselineLog, signalLog]) log.append('evaluation_summary', { report_hash: hash(report), provider_calls: providerCalls, router_attempts: calls });
  const records = { baseline: baselineLog.close(), signal: signalLog.close() };
  for (const [lane, document] of Object.entries(records)) {
    const result = verifyDecisionDocument(document, { expectedRunId: runId,
      expectedLaneId: lane === 'baseline' ? 'last_named' : 'signal', expectedManifestHash: hash(manifest) });
    if (!result.ok) throw new Error('record_verification_failed');
  }
  return { report, records };
}
