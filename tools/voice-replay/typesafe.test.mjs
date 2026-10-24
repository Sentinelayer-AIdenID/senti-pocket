import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { createTypeSafeRouter } from './typesafe.mjs';

const KEY = 'fixture-credential-not-a-real-key';
const MODEL = 'jev-1.13.0';
const ENDPOINT = 'https://api.typesafe.ai/v1/systemone';
const request = () => ({
  state: { transcript_partial: 'Speaker A, could you respond?', eligible_speakers: ['speaker_a'] },
  criteria: { speaker_a: 'Offer speaker A the floor.', keep_listening: 'Wait for more text.', interrupt: 'Interrupt only on an explicit stop request.' },
});
const response = () => ({
  model: MODEL,
  answers: { route: { type: 'choice', choice: 'speaker_a',
    probabilities: { speaker_a: 0.8, keep_listening: 0.15, interrupt: 0.05 }, confidence: 0.7 } },
  usage: { input_tokens: 1000, output_tokens: 34 },
});
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const fixture = (body = response(), options = {}) => {
  const calls = [];
  const raw = typeof body === 'string' ? body : JSON.stringify(body);
  const route = createTypeSafeRouter({ apiKey: KEY, ...options, fetchImpl: async (url, init) => {
    calls.push({ url, init });
    return new Response(raw, { headers: { 'Content-Type': 'application/json' } });
  } });
  return { route, calls, raw };
};

test('one official Choice request has captured schema, bounded policy, and exact hashes', async () => {
  let tick = 100;
  const { route, calls, raw } = fixture(response(), { clock: () => tick += 4.4 });
  const result = await route(request());
  assert.equal(result.ok, true);
  assert.equal(result.model, MODEL);
  assert.equal(result.dispatched, true);
  assert.equal(result.choice, 'speaker_a');
  assert.deepEqual(result.probabilities, response().answers.route.probabilities);
  assert.equal(result.confidence, 0.7);
  assert.ok(Math.abs(result.effectiveConfidence - 0.7) < 1e-12);
  assert.deepEqual(result.usage, { input_tokens: 1000, output_tokens: 34 });
  assert.equal(result.latencyMs, 4);
  assert.equal(calls.length, 1);
  const [{ url, init }] = calls;
  assert.equal(url, ENDPOINT);
  assert.equal(init.method, 'POST');
  assert.equal(init.redirect, 'error');
  assert.deepEqual(init.headers, { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' });
  assert.ok(init.signal instanceof AbortSignal);
  assert.equal(init.signal.aborted, true);
  const wire = JSON.parse(init.body);
  assert.deepEqual(Object.keys(wire).sort(), ['model', 'questions', 'state']);
  assert.equal(wire.model, MODEL);
  assert.deepEqual(wire.state, request().state);
  assert.deepEqual(Object.keys(wire.questions), ['route']);
  assert.equal(wire.questions.route.type, 'choice');
  assert.match(wire.questions.route.instructions, /partial transcript/);
  assert.deepEqual(wire.questions.route.criteria, request().criteria);
  assert.equal(result.requestHash, sha(init.body));
  assert.equal(result.responseHash, sha(raw));
  assert.equal(JSON.stringify(result).includes(KEY), false);
});

test('canonical request hashes agree across insertion order; a changed state changes the hash', async () => {
  const { route } = fixture();
  const a = request();
  const b = { criteria: { interrupt: a.criteria.interrupt, keep_listening: a.criteria.keep_listening, speaker_a: a.criteria.speaker_a },
    state: { eligible_speakers: ['speaker_a'], transcript_partial: a.state.transcript_partial } };
  const first = await route(a);
  assert.equal((await route(b)).requestHash, first.requestHash);
  b.state.transcript_partial += ' Please.';
  assert.notEqual((await route(b)).requestHash, first.requestHash);
});

test('read-only dispatch counter survives failed results and excludes rejected preflight requests', async () => {
  const route = createTypeSafeRouter({ apiKey: KEY, fetchImpl: async () => { throw new Error(KEY); } });
  assert.equal(route.getDispatchCount(), 0);
  assert.throws(() => { route.getDispatchCount = () => 99; }, TypeError);
  const rejected = await route({ ...request(), unknown: true });
  assert.equal(rejected.dispatched, false);
  assert.equal(route.getDispatchCount(), 0);
  const failed = await route(request());
  assert.equal(failed.dispatched, true);
  assert.equal(failed.errorCode, 'network_error');
  assert.equal(route.getDispatchCount(), 1);
  assert.equal(JSON.stringify(failed).includes(KEY), false);
});

test('docs rounding is tolerated and effective confidence never exceeds either confidence', async () => {
  for (const confidence of [0.81, 0.83]) {
    const body = response();
    Object.assign(body.answers.route, { probabilities: { speaker_a: 0.88, keep_listening: 0.12, interrupt: 0 }, confidence });
    const result = await fixture(body).route(request());
    assert.equal(result.ok, true);
    const formula = (0.88 - 1 / 3) / (1 - 1 / 3);
    assert.ok(Math.abs(result.effectiveConfidence - Math.min(confidence, formula)) < 1e-12);
  }
});

test('ties accept either actual maximum and a flat distribution has zero confidence', async () => {
  const body = response();
  Object.assign(body.answers.route, { choice: 'interrupt', probabilities: { speaker_a: 1 / 3, keep_listening: 1 / 3, interrupt: 1 / 3 }, confidence: 0 });
  const result = await fixture(body).route(request());
  assert.equal(result.ok, true);
  assert.equal(result.choice, 'interrupt');
  assert.equal(result.effectiveConfidence, 0);
});

test('wrong model, question ID, type, choice, and unknown or missing probability keys fail closed', async () => {
  const mutations = [
    body => { body.model = 'jev-1.14.0'; },
    body => { body.answers.other = body.answers.route; },
    body => { body.answers.other = body.answers.route; delete body.answers.route; },
    body => { body.answers.route.type = 'boolean'; },
    body => { body.answers.route.choice = 'unlisted-agent'; },
    body => { body.answers.route.choice = '__proto__'; },
    body => { body.answers.route.probabilities.other = 0; },
    body => { delete body.answers.route.probabilities.interrupt; },
    body => { body.answers.route.probabilities.other = 0.05; delete body.answers.route.probabilities.interrupt; },
    body => { delete body.answers.route; },
  ];
  for (const mutate of mutations) {
    const body = response();
    mutate(body);
    const { route, calls } = fixture(body);
    const result = await route(request());
    assert.equal(result.ok, false);
    assert.equal(result.errorCode, 'invalid_response');
    assert.equal(Object.hasOwn(result, 'choice'), false);
    assert.equal(calls.length, 1);
  }
});

test('nonmaximum choice, bad sums, nonnumeric or nonfinite probabilities and inconsistent confidence fail', async () => {
  const mutations = [
    body => { body.answers.route.choice = 'keep_listening'; },
    body => { body.answers.route.probabilities.interrupt = 0.3; },
    body => { body.answers.route.probabilities.speaker_a = -0.1; },
    body => { body.answers.route.probabilities.speaker_a = 1.1; },
    body => { body.answers.route.probabilities.speaker_a = true; },
    body => { body.answers.route.probabilities.speaker_a = null; },
    body => { body.answers.route.probabilities.speaker_a = '0.8'; },
    body => { body.answers.route.confidence = 0.8; },
    body => { body.answers.route.confidence = -0.1; },
    body => { body.answers.route.confidence = 1.1; },
    body => { body.answers.route.confidence = false; },
    body => { delete body.answers.route.confidence; },
  ];
  for (const mutate of mutations) {
    const body = response();
    mutate(body);
    const result = await fixture(body).route(request());
    assert.equal(result.ok, false);
    assert.equal(result.errorCode, 'invalid_response');
  }
  for (const raw of [JSON.stringify(response()).replace('0.8', '1e400'),
    JSON.stringify(response()).replace('"confidence":0.7', '"confidence":1e400')]) {
    assert.equal((await fixture(raw).route(request())).errorCode, 'invalid_response');
  }
});

test('sum and confidence tolerance boundaries are explicit rather than silently normalized', async () => {
  const body = response();
  body.answers.route.probabilities.interrupt = 0.06;
  body.answers.route.confidence = 0.725;
  const accepted = await fixture(body).route(request());
  assert.equal(accepted.ok, true);
  assert.equal(accepted.probabilities.interrupt, 0.06);
  assert.ok(Math.abs(accepted.effectiveConfidence - 0.7) < 1e-12);
  body.answers.route.probabilities.interrupt = 0.0601;
  assert.equal((await fixture(body).route(request())).errorCode, 'invalid_response');
  body.answers.route.probabilities.interrupt = 0.05;
  body.answers.route.confidence = 0.7251;
  assert.equal((await fixture(body).route(request())).errorCode, 'invalid_response');
});

test('missing or malformed usage is unknown, valid zero usage is preserved, and invalid answers retain known usage', async () => {
  for (const usage of [undefined, null, {}, { input_tokens: 1 }, { input_tokens: -1, output_tokens: 0 },
    { input_tokens: true, output_tokens: 0 }, { input_tokens: 1.5, output_tokens: 0 },
    { input_tokens: Number.MAX_SAFE_INTEGER + 1, output_tokens: 0 }]) {
    const body = response();
    body.usage = usage;
    const result = await fixture(body).route(request());
    assert.equal(result.ok, true);
    assert.equal(result.usage, null);
  }
  const body = response();
  body.usage = { input_tokens: 0, output_tokens: 0 };
  assert.deepEqual((await fixture(body).route(request())).usage, body.usage);
  body.answers.route.choice = 'unknown';
  assert.deepEqual((await fixture(body).route(request())).usage, body.usage);
});

test('invalid requests, unknown top-level keys and poison IDs never dispatch or invoke getters', async () => {
  const cycle = {};
  cycle.self = cycle;
  let getterCalls = 0;
  const getterState = {};
  Object.defineProperty(getterState, 'secret', { enumerable: true, get() { getterCalls += 1; return KEY; } });
  const getterCriteria = { ...request().criteria };
  Object.defineProperty(getterCriteria, 'speaker_a', { enumerable: true, get() { getterCalls += 1; return KEY; } });
  const invalid = [null, [], {}, { ...request(), extra: true }, { state: null, criteria: request().criteria },
    { state: true, criteria: request().criteria }, { state: cycle, criteria: request().criteria },
    { state: getterState, criteria: request().criteria }, { ...request(), criteria: getterCriteria },
    { state: new Date(), criteria: request().criteria }, { state: [undefined], criteria: request().criteria },
    { state: new Array(2), criteria: request().criteria }, { state: { n: Infinity }, criteria: request().criteria },
    { state: { toJSON() { throw new Error(KEY); } }, criteria: request().criteria },
    { state: 'text', criteria: { one: 'only one' } },
    { state: 'text', criteria: JSON.parse('{"__proto__":"poison","okay":"description"}') },
    { state: 'text', criteria: { constructor: 'poison', okay: 'description' } },
    { state: 'text', criteria: { 'bad id': 'space', okay: 'description' } },
    { state: 'text', criteria: { one: 42, two: 'description' } },
  ];
  const { route, calls } = fixture();
  for (const input of invalid) {
    const result = await route(input);
    assert.equal(result.ok, false);
    assert.equal(result.errorCode, 'invalid_request');
    assert.equal(result.requestHash, sha(''));
    assert.equal(result.dispatched, false);
    assert.equal(JSON.stringify(result).includes(KEY), false);
  }
  assert.equal(calls.length, 0);
  assert.equal(getterCalls, 0);
});

test('choice option limit and wire nesting limit are checked before dispatch', async () => {
  const { route, calls } = fixture();
  const criteria = Object.fromEntries(Array.from({ length: 256 }, (_, i) => [`id${i}`, 'description']));
  assert.equal((await route({ state: 'text', criteria })).errorCode, 'invalid_request');
  let state = 'text';
  for (let i = 0; i < 65; i += 1) state = { child: state };
  assert.equal((await route({ state, criteria: request().criteria })).errorCode, 'invalid_request');
  assert.equal(calls.length, 0);
});

test('request size includes the entire encoded body and UTF-8 bytes', async () => {
  const first = fixture();
  await first.route(request());
  const bytes = Buffer.byteLength(first.calls[0].init.body);
  const exact = fixture(response(), { maxRequestBytes: bytes });
  assert.equal((await exact.route(request())).ok, true);
  const short = fixture(response(), { maxRequestBytes: bytes - 1 });
  assert.equal((await short.route(request())).errorCode, 'request_too_large');
  assert.equal(short.calls.length, 0);
  const unicode = fixture(response(), { maxRequestBytes: 1000 });
  assert.equal((await unicode.route({ ...request(), state: '🎤'.repeat(300) })).errorCode, 'request_too_large');
  assert.equal(unicode.calls.length, 0);
});

test('response streaming is byte bounded and cancelled without hashing a truncated body', async () => {
  let cancelled = false;
  let calls = 0;
  const stream = new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(100)); controller.enqueue(new Uint8Array(101)); },
    cancel() { cancelled = true; },
  });
  const route = createTypeSafeRouter({ apiKey: KEY, maxResponseBytes: 200, fetchImpl: async () => {
    calls += 1;
    return new Response(stream);
  } });
  const result = await route(request());
  assert.equal(result.errorCode, 'response_too_large');
  assert.equal(Object.hasOwn(result, 'responseHash'), false);
  assert.equal(cancelled, true);
  assert.equal(calls, 1);
});

test('response content length can reject an oversized body before reading it', async () => {
  let cancelled = false;
  const route = createTypeSafeRouter({ apiKey: KEY, maxResponseBytes: 10, fetchImpl: async () => new Response(
    new ReadableStream({ cancel() { cancelled = true; } }), { headers: { 'Content-Length': '11' } },
  ) });
  assert.equal((await route(request())).errorCode, 'response_too_large');
  assert.equal(cancelled, true);
});

test('complete response bytes at the exact limit are accepted and produce an exact response hash', async () => {
  const raw = JSON.stringify(response());
  const result = await fixture(raw, { maxResponseBytes: Buffer.byteLength(raw) }).route(request());
  assert.equal(result.ok, true);
  assert.equal(result.responseHash, sha(raw));
});

test('HTTP errors do not read or disclose their bodies and never retry', async () => {
  for (const status of [400, 401, 429, 500, 529]) {
    let reads = 0;
    let calls = 0;
    let cancelled = false;
    const route = createTypeSafeRouter({ apiKey: KEY, fetchImpl: async () => {
      calls += 1;
      return { ok: false, status, body: { getReader() { reads += 1; throw new Error(KEY); }, cancel() { cancelled = true; } } };
    } });
    const result = await route(request());
    assert.equal(result.errorCode, 'http_error');
    assert.equal(result.dispatched, true);
    assert.equal(result.usage, null);
    assert.equal(reads, 0);
    assert.equal(calls, 1);
    assert.equal(cancelled, true);
    assert.equal(JSON.stringify(result).includes(KEY), false);
  }
});

test('fetch errors, malformed JSON, invalid UTF-8 and invalid envelopes use generic failures', async () => {
  const route = createTypeSafeRouter({ apiKey: KEY, fetchImpl: async () => { throw new Error(`Authorization: Bearer ${KEY}`); } });
  const network = await route(request());
  assert.equal(network.errorCode, 'network_error');
  assert.equal(network.dispatched, true);
  assert.equal(JSON.stringify(network).includes(KEY), false);
  for (const raw of [`{"secret":"${KEY}",`, 'null', '[]', '{}', '\ufeff' + JSON.stringify(response())]) {
    const result = await fixture(raw).route(request());
    assert.equal(result.errorCode, 'invalid_response');
    assert.equal(result.responseHash, sha(raw));
    assert.equal(JSON.stringify(result).includes(KEY), false);
  }
  const badUtf8 = createTypeSafeRouter({ apiKey: KEY, fetchImpl: async () => new Response(new Uint8Array([0xff])) });
  assert.equal((await badUtf8(request())).errorCode, 'invalid_response');
});

test('a fetch that ignores abort still times out, aborts, and makes only one attempt', { timeout: 2000 }, async () => {
  let signal;
  let calls = 0;
  const route = createTypeSafeRouter({ apiKey: KEY, timeoutMs: 15, fetchImpl: (_url, init) => {
    calls += 1;
    signal = init.signal;
    return new Promise(() => {});
  } });
  const started = performance.now();
  const result = await route(request());
  assert.equal(result.errorCode, 'timeout');
  assert.equal(result.dispatched, true);
  assert.equal(signal.aborted, true);
  assert.equal(calls, 1);
  assert.equal(route.getDispatchCount(), 1);
  assert.ok(performance.now() - started < 1000);
  assert.equal(Object.hasOwn(result, 'responseHash'), false);
});

test('a stalled response body times out and cancels its reader', { timeout: 2000 }, async () => {
  let cancelled = false;
  let signal;
  const route = createTypeSafeRouter({ apiKey: KEY, timeoutMs: 15, fetchImpl: async (_url, init) => {
    signal = init.signal;
    return new Response(new ReadableStream({ cancel() { cancelled = true; } }));
  } });
  const result = await route(request());
  assert.equal(result.errorCode, 'timeout');
  assert.equal(signal.aborted, true);
  assert.equal(cancelled, true);
});

test('late fetch completion after the deadline is cancelled without changing the timeout result', { timeout: 2000 }, async () => {
  let complete;
  let cancelled = false;
  const route = createTypeSafeRouter({ apiKey: KEY, timeoutMs: 10, fetchImpl: () => new Promise(resolve => { complete = resolve; }) });
  const result = await route(request());
  complete(new Response(new ReadableStream({ cancel() { cancelled = true; } })));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(result.errorCode, 'timeout');
  assert.equal(cancelled, true);
  assert.equal(Object.hasOwn(result, 'responseHash'), false);
});

test('invalid or missing credentials and unpinned models do not dispatch or echo configuration', async () => {
  let calls = 0;
  for (const options of [{}, { apiKey: '' }, { apiKey: `${KEY}\r\nHeader: leaked` },
    { apiKey: KEY, model: 'jev-latest' }, { apiKey: KEY, model: KEY },
    { apiKey: KEY, timeoutMs: 0 }, { apiKey: KEY, maxResponseBytes: 0 }]) {
    const route = createTypeSafeRouter({ ...options, fetchImpl: async () => { calls += 1; throw new Error(KEY); } });
    const result = await route(request());
    assert.equal(result.errorCode, 'invalid_configuration');
    assert.equal(result.requestHash, sha(''));
    assert.equal(result.dispatched, false);
    assert.equal(JSON.stringify(result).includes(KEY), false);
  }
  assert.equal(calls, 0);
});
