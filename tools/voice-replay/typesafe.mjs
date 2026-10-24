import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';

const ENDPOINT = 'https://api.typesafe.ai/v1/systemone';
const DEFAULT_MODEL = 'jev-1.13.0';
const EMPTY_HASH = createHash('sha256').update('').digest('hex');
const SUM_TOLERANCE = 0.01;
const CONFIDENCE_TOLERANCE = 0.025;
const EPSILON = 1e-12;
const POISON_IDS = new Set([...Object.getOwnPropertyNames(Object.prototype), 'prototype']);
const INSTRUCTIONS = 'Select the next floor option using the partial transcript and context in state and the supplied criteria. Choose the listening or deferral option when the partial does not support a speaker. Apply any interruption criterion exactly as supplied. This is an advisory text-replay judgment, not permission to act or factual certification.';

class RouterFailure extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

const fail = code => { throw new RouterFailure(code); };
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const plain = value => value !== null && typeof value === 'object'
  && (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
const unit = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;
const size = value => Number.isSafeInteger(value) && value > 0;

// Serialize data only: no getters, toJSON hooks, cycles, holes, or lossy JSON coercions.
// Sorting keys also makes the request hash independent of object insertion order.
function boundedJson(value, limit) {
  const chunks = [];
  const ancestors = new Set();
  let bytes = 0;
  const append = text => {
    bytes += Buffer.byteLength(text, 'utf8');
    if (bytes > limit) fail('request_too_large');
    chunks.push(text);
  };
  const string = text => {
    if (Buffer.byteLength(text, 'utf8') > limit - bytes) fail('request_too_large');
    append(JSON.stringify(text));
  };
  const visit = (item, depth) => {
    if (depth > 64) fail('invalid_request');
    if (item === null) { append('null'); return; }
    if (typeof item === 'string') { string(item); return; }
    if (typeof item === 'boolean') { append(String(item)); return; }
    if (typeof item === 'number') {
      if (!Number.isFinite(item)) fail('invalid_request');
      append(JSON.stringify(item));
      return;
    }
    if (typeof item !== 'object' || ancestors.has(item)) fail('invalid_request');
    const array = Array.isArray(item);
    if (!array && !plain(item)) fail('invalid_request');
    const descriptors = Object.getOwnPropertyDescriptors(item);
    const keys = Reflect.ownKeys(descriptors);
    if (keys.some(key => typeof key !== 'string'
      || !Object.hasOwn(descriptors[key], 'value')
      || (!descriptors[key].enumerable && !(array && key === 'length')))) fail('invalid_request');
    ancestors.add(item);
    if (array) {
      if (item.length > limit) fail('request_too_large');
      if (keys.length !== item.length + 1) fail('invalid_request');
      append('[');
      for (let i = 0; i < item.length; i += 1) {
        if (!Object.hasOwn(descriptors, String(i))) fail('invalid_request');
        if (i) append(',');
        visit(descriptors[i].value, depth + 1);
      }
      append(']');
    } else {
      append('{');
      keys.sort().forEach((key, index) => {
        if (index) append(',');
        string(key);
        append(':');
        visit(descriptors[key].value, depth + 1);
      });
      append('}');
    }
    ancestors.delete(item);
  };
  visit(value, 0);
  return chunks.join('');
}

function prepareRequest(input, model, limit) {
  if (!plain(input)) fail('invalid_request');
  const fields = Object.getOwnPropertyDescriptors(input);
  if (Reflect.ownKeys(fields).length !== 2 || !Object.hasOwn(fields, 'state')
    || !Object.hasOwn(fields, 'criteria') || !Object.hasOwn(fields.state, 'value')
    || !Object.hasOwn(fields.criteria, 'value')) fail('invalid_request');
  const state = fields.state.value;
  const criteria = fields.criteria.value;
  if (!(typeof state === 'string' || (state !== null && typeof state === 'object'))
    || !plain(criteria)) fail('invalid_request');
  const options = Reflect.ownKeys(criteria);
  if (options.length < 2 || options.length > 255 || options.some(id => typeof id !== 'string'
    || !/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/.test(id) || POISON_IDS.has(id))) fail('invalid_request');
  const descriptions = Object.getOwnPropertyDescriptors(criteria);
  for (const id of options) {
    const description = descriptions[id];
    if (!Object.hasOwn(description, 'value') || !description.enumerable
      || !(description.value === null || typeof description.value === 'string'
        || typeof description.value === 'object')) fail('invalid_request');
  }
  const body = boundedJson({ model, state, questions: { route: {
    type: 'choice', instructions: INSTRUCTIONS, criteria,
  } } }, limit);
  return { body, options };
}

function readUsage(value) {
  if (!plain(value) || !Number.isSafeInteger(value.input_tokens) || value.input_tokens < 0
    || !Number.isSafeInteger(value.output_tokens) || value.output_tokens < 0) return null;
  return { input_tokens: value.input_tokens, output_tokens: value.output_tokens };
}

function validateAnswer(value, model, options) {
  if (!plain(value) || value.model !== model || !plain(value.answers)
    || Object.keys(value.answers).length !== 1 || !Object.hasOwn(value.answers, 'route')) fail('invalid_response');
  const answer = value.answers.route;
  if (!plain(answer) || answer.type !== 'choice' || !options.includes(answer.choice)
    || !plain(answer.probabilities) || !unit(answer.confidence)) fail('invalid_response');
  const keys = Object.keys(answer.probabilities);
  if (keys.length !== options.length || keys.some(key => !options.includes(key))) fail('invalid_response');
  const probabilities = Object.fromEntries(options.map(id => {
    const probability = answer.probabilities[id];
    if (!Object.hasOwn(answer.probabilities, id) || !unit(probability)) fail('invalid_response');
    return [id, probability];
  }));
  const values = Object.values(probabilities);
  const maximum = Math.max(...values);
  if (Math.abs(values.reduce((total, number) => total + number, 0) - 1) > SUM_TOLERANCE + EPSILON
    || probabilities[answer.choice] + EPSILON < maximum) fail('invalid_response');
  // Choice confidence is the normalized maximum probability, not raw p_max.
  const formula = (maximum - 1 / options.length) / (1 - 1 / options.length);
  if (formula < 0 || formula > 1
    || Math.abs(answer.confidence - formula) > CONFIDENCE_TOLERANCE + EPSILON) fail('invalid_response');
  return {
    choice: answer.choice, probabilities, confidence: answer.confidence,
    effectiveConfidence: Math.min(answer.confidence, formula),
  };
}

function cancelQuietly(target) {
  try { Promise.resolve(target?.cancel()).catch(() => {}); } catch { /* Best effort only. */ }
}

/** One bounded HTTP attempt; ok:false is the caller's deterministic-fallback signal.
 * requestHash is SHA256 of the exact wire body, or SHA256(empty) before dispatch.
 * responseHash exists only for a complete bounded body. No credential is returned.
 * dispatched and read-only getDispatchCount() count fetch invocations, not receipts.
 */
export function createTypeSafeRouter({
  apiKey, model = DEFAULT_MODEL, timeoutMs = 250, maxResponseBytes = 65536,
  maxRequestBytes = 32768, fetchImpl = globalThis.fetch, clock = () => performance.now(),
} = {}) {
  const pinnedModel = typeof model === 'string' && /^jev-\d+\.\d+\.\d+$/.test(model) ? model : DEFAULT_MODEL;
  const configured = typeof apiKey === 'string' && apiKey.length > 0 && apiKey.length <= 8192
    && /^[\x21-\x7e]+$/.test(apiKey) && pinnedModel === model && size(timeoutMs)
    && timeoutMs <= 2147483647 && size(maxResponseBytes) && size(maxRequestBytes)
    && typeof fetchImpl === 'function' && typeof clock === 'function';
  let dispatchCount = 0;
  const route = async input => {
    let started;
    try { started = clock(); } catch { started = 0; }
    let requestHash = EMPTY_HASH;
    let responseHash;
    let usage = null;
    let timer;
    let reader;
    let response;
    let timedOut = false;
    let dispatched = false;
    const controller = new AbortController();
    const finish = fields => {
      let elapsed;
      try { elapsed = clock() - started; } catch { elapsed = 0; }
      return {
        ok: false, model: pinnedModel, usage, dispatched,
        latencyMs: Number.isFinite(elapsed) ? Math.max(0, Math.round(elapsed)) : 0,
        requestHash, ...(responseHash ? { responseHash } : {}), ...fields,
      };
    };
    try {
      if (!configured) fail('invalid_configuration');
      const { body, options } = prepareRequest(input, pinnedModel, maxRequestBytes);
      requestHash = hash(body);
      const deadline = new Promise((_, reject) => {
        timer = setTimeout(() => {
          timedOut = true;
          controller.abort();
          cancelQuietly(reader);
          reject(new RouterFailure('timeout'));
        }, timeoutMs);
      });
      const attempt = async () => {
        dispatched = true;
        dispatchCount += 1;
        response = await fetchImpl(ENDPOINT, {
          method: 'POST', redirect: 'error', signal: controller.signal,
          headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' }, body,
        });
        if (timedOut) { cancelQuietly(response?.body); fail('timeout'); }
        if (!response || typeof response.ok !== 'boolean') fail('invalid_response');
        if (!response.ok) { cancelQuietly(response.body); fail('http_error'); }
        const contentLength = response.headers?.get('content-length');
        if (contentLength && /^\d+$/.test(contentLength) && Number(contentLength) > maxResponseBytes) {
          cancelQuietly(response.body);
          fail('response_too_large');
        }
        if (typeof response.body?.getReader !== 'function') fail('invalid_response');
        reader = response.body.getReader();
        const chunks = [];
        let total = 0;
        while (true) {
          const { done, value } = await reader.read();
          if (timedOut) fail('timeout');
          if (done) break;
          if (!(value instanceof Uint8Array)) fail('invalid_response');
          total += value.byteLength;
          if (total > maxResponseBytes) fail('response_too_large');
          chunks.push(Buffer.from(value));
        }
        const bytes = Buffer.concat(chunks, total);
        responseHash = hash(bytes);
        let value;
        if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) fail('invalid_response');
        try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
        catch { fail('invalid_response'); }
        if (plain(value) && value.model === pinnedModel) usage = readUsage(value.usage);
        return validateAnswer(value, pinnedModel, options);
      };
      const answer = await Promise.race([attempt(), deadline]);
      return finish({ ok: true, ...answer });
    } catch (error) {
      return finish({ errorCode: timedOut ? 'timeout'
        : error instanceof RouterFailure ? error.code : 'network_error' });
    } finally {
      clearTimeout(timer);
      controller.abort();
      cancelQuietly(reader);
      if (!reader) cancelQuietly(response?.body);
    }
  };
  Object.defineProperty(route, 'getDispatchCount', { value: () => dispatchCount });
  return route;
}
