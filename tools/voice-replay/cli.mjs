import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { validateDataset, bytesHash, lastNamed } from './dataset.mjs';
import { replay, validateConfig } from './replay.mjs';
import { hash } from './record.mjs';
import { createTypeSafeRouter } from './typesafe.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const parseInteger = (s) => { if (!/^\d+$/.test(s)) throw new Error('invalid_argument'); return Number(s); };
function parseArgs(args) {
  const values = {}, flags = new Set(['--live', '--prepare']);
  const allowed = new Set(['--input', '--out', '--source-map', '--freeze', '--split', '--max-calls', '--confidence-ppm', '--chars-per-partial']);
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (Object.hasOwn(values, key)) throw new Error('duplicate_argument');
    if (flags.has(key)) values[key] = true;
    else if (allowed.has(key) && i + 1 < args.length && !args[i + 1].startsWith('--')) values[key] = args[++i];
    else throw new Error('invalid_argument');
  }
  return values;
}
function readJson(file) {
  if (fs.statSync(file).size > 32 * 1024 * 1024) throw new Error('input_too_large');
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
}
function writeNew(file, value) { fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', { encoding: 'utf8', flag: 'wx' }); }

export async function main(args) {
  const options = parseArgs(args), live = !!options['--live'];
  const inputPath = path.resolve(options['--input'] || path.join(directory, 'synthetic.json'));
  const dataset = validateDataset(readJson(inputPath));
  const split = options['--split'] || 'development';
  if (!['development', 'holdout'].includes(split)) throw new Error('invalid_split');
  const selected = { ...dataset, sessions: dataset.sessions.filter((s) => s.split === split) };
  if (!selected.sessions.length) throw new Error('empty_split');
  const config = validateConfig({ partialMs: 250, charsPerPartial: parseInteger(options['--chars-per-partial'] || '24'), deadlineMs: 250,
    confidencePpm: parseInteger(options['--confidence-ppm'] || '600000'), maxCalls: parseInteger(options['--max-calls'] || '200'),
    model: 'jev-1.13.0', mode: live ? 'typesafe-live' : 'synthetic' });
  const sourceMap = options['--source-map'] ? readJson(path.resolve(options['--source-map'])) : {};
  const verified = [];
  for (const session of dataset.sessions.filter((s) => s.source_kind === 'recorded')) {
    const sourcePath = sourceMap[session.session_id];
    if (typeof sourcePath !== 'string' || fs.statSync(sourcePath).size > 128 * 1024 * 1024 ||
        bytesHash(fs.readFileSync(sourcePath)) !== session.source_sha256) throw new Error('recorded_source_not_verified');
    verified.push(session.source_sha256);
  }
  const freeze = { schema: 'voice-replay.freeze.v1', corpus_hash: hash(dataset), config_hash: hash(config), config, split };
  const freezePath = options['--freeze'] && path.resolve(options['--freeze']);
  if (options['--prepare']) {
    if (!freezePath) throw new Error('freeze_path_required');
    writeNew(freezePath, freeze);
    process.stdout.write(JSON.stringify({ prepared: true, freeze_hash: hash(freeze), provider_calls: 0 }) + '\n');
    return;
  }
  if (live && (!freezePath || hash(readJson(freezePath)) !== hash(freeze))) throw new Error('freeze_mismatch');
  const apiKey = live ? process.env.TYPESAFE_API_KEY : undefined;
  if (live && !apiKey) throw new Error('provider_key_required');
  const runId = randomUUID(), output = path.resolve(options['--out'] || path.join(directory, 'results', runId));
  // Real inputs and outputs belong only under explicitly gitignored runtime directories.
  // Never create/overwrite a caller-supplied existing directory.
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.mkdirSync(output);
  if (live && split === 'holdout') writeNew(freezePath + '.consumed', { run_id: runId, freeze_hash: hash(freeze) });
  const router = live ? createTypeSafeRouter({ apiKey, model: config.model, timeoutMs: config.deadlineMs }) : async ({ state, criteria }) => {
    const choice = lastNamed(state.partial_text, state.available_agents);
    return { ok: true, dispatched: false, model: config.model, choice, effectiveConfidence: 1,
      probabilities: Object.fromEntries(Object.keys(criteria).map((id) => [id, Number(id === choice)])), usage: null };
  };
  const result = await replay(selected, { router, runId, config, verifiedSourceHashes: verified,
    evaluationBinding: live ? { freeze_hash: hash(freeze), full_corpus_hash: hash(dataset), requested_split: split } : null });
  writeNew(path.join(output, 'report.json'), result.report);
  writeNew(path.join(output, 'last-named-record.json'), result.records.baseline);
  writeNew(path.join(output, 'signal-record.json'), result.records.signal);
  // This synthetic router deliberately mirrors baseline; it is not a measured Jev result.
  process.stdout.write(JSON.stringify(result.report) + '\n');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(() => { process.stderr.write('voice-replay: failed; no untrusted error details emitted\n'); process.exitCode = 1; });
}
