import { createHash, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';

const ZERO_HASH = '0'.repeat(64);
const HEX = /^[0-9a-f]{64}$/;
const ENTRY_KEYS = ['event', 'hash', 'payload', 'previous_hash', 'sequence', 'signature', 'timestamp'];
const DOCUMENT_KEYS = ['events', 'lane_id', 'record_public_key', 'run_id'];
const IDENTITY_KEYS = ['agent_id', 'lane_id', 'manifest', 'manifest_hash', 'run_id'];
const TRUST = Object.freeze({ identityVerified: false, keyTrust: 'self-supplied-integrity-only' });
const plain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v) &&
  [Object.prototype, null].includes(Object.getPrototypeOf(v));
const exactKeys = (v, keys) => {
  if (!plain(v)) return false;
  const actual = Object.keys(v).sort();
  return actual.length === keys.length && actual.every((key, i) => key === keys[i]);
};
const identifier = (v) => typeof v === 'string' && /^[A-Za-z0-9_.:-]{1,160}$/.test(v);

// Python ensure_ascii=True string escaping, including UTF16 surrogate pairs.
function quote(value) {
  return JSON.stringify(value).replace(/[\u007f-\uffff]/g, (ch) =>
    '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'));
}
function compareKeys(a, b) {
  const left = [...a].map((v) => v.codePointAt(0)), right = [...b].map((v) => v.codePointAt(0));
  for (let i = 0; i < Math.min(left.length, right.length); i += 1) {
    if (left[i] !== right[i]) return left[i] - right[i];
  }
  return left.length - right.length;
}

/** Python sorted/minified/ensure_ascii JSON for finite safe integers, never arbitrary floats. */
export function canonical(value) {
  const seen = new Set();
  function encode(v, depth) {
    if (depth > 64) throw new TypeError('invalid integer JSON');
    if (v === null || typeof v === 'boolean') return String(v);
    if (typeof v === 'number') {
      if (!Number.isSafeInteger(v)) throw new TypeError('invalid integer JSON');
      return String(v === 0 ? 0 : v);
    }
    if (typeof v === 'string') return quote(v);
    if (!Array.isArray(v) && !plain(v)) throw new TypeError('invalid integer JSON');
    if (seen.has(v)) throw new TypeError('invalid integer JSON');
    seen.add(v);
    const descriptors = Object.getOwnPropertyDescriptors(v);
    let encoded;
    if (Array.isArray(v)) {
      if (Reflect.ownKeys(v).length !== v.length + 1 ||
          !Array.from({ length: v.length }, (_, i) => descriptors[i]).every((d) => d && 'value' in d && d.enumerable)) {
        throw new TypeError('invalid integer JSON');
      }
      encoded = '[' + Array.from({ length: v.length }, (_, i) => encode(descriptors[i].value, depth + 1)).join(',') + ']';
    } else {
      const keys = Reflect.ownKeys(v);
      if (!keys.every((k) => typeof k === 'string' && descriptors[k].enumerable && 'value' in descriptors[k])) {
        throw new TypeError('invalid integer JSON');
      }
      encoded = '{' + keys.sort(compareKeys).map((k) => quote(k) + ':' + encode(descriptors[k].value, depth + 1)).join(',') + '}';
    }
    seen.delete(v);
    return encoded;
  }
  return encode(value, 0);
}
export const hash = (value) => createHash('sha256').update(canonical(value), 'utf8').digest('hex');
const copy = (value) => JSON.parse(canonical(value));
function freeze(value) {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}

// Defense in depth, not a secret detector: callers must supply hashes/config, never raw prompts or credentials.
function safePayload(value) {
  canonical(value); // Reject accessors/opaque values/cycles before traversing.
  if (!plain(value)) throw new TypeError('invalid record payload');
  function visit(v) {
    if (typeof v === 'string' && /\bbearer\s+\S+|\bsk-[A-Za-z0-9_-]+/i.test(v)) throw new TypeError('forbidden record payload');
    if (Array.isArray(v)) return v.forEach(visit);
    if (!plain(v)) return;
    for (const [key, item] of Object.entries(v)) {
      // Thermal's browser verifier sorts UTF16 keys; ASCII field names also match Python's scalar ordering.
      if (/[^\x00-\x7f]/.test(key)) throw new TypeError('invalid record field');
      if (key === 'usage' && (!plain(item) || Object.keys(item).some((name) => !['input_tokens', 'output_tokens'].includes(name)))) {
        throw new TypeError('invalid usage fields');
      }
      if (key === 'input_tokens' || key === 'output_tokens') {
        if (item !== null && (!Number.isSafeInteger(item) || item < 0)) throw new TypeError('invalid usage count');
        continue;
      }
      const name = key.replace(/[^a-z]/gi, '').toLowerCase();
      if (/password|secret|token|authorization|apikey|privatekey|prompt|transcript/.test(name) ||
          /^(auth|authheader|authentication|key)$/.test(name)) throw new TypeError('forbidden record payload');
      visit(item);
    }
  }
  visit(value);
  return copy(value);
}

/** Self-contained integrity record. Its generated key is NOT an authenticated agent identity. */
export class DecisionLog {
  #privateKey;
  #publicHex;
  #events = [];
  #closed = null;
  #clock;
  #runId;
  #laneId;
  constructor({ runId, laneId, manifest, clock = Date.now } = {}) {
    if (!identifier(runId) || !identifier(laneId) || typeof clock !== 'function') throw new TypeError('invalid record identity');
    const safeManifest = safePayload(manifest);
    const keys = generateKeyPairSync('ed25519');
    this.#privateKey = keys.privateKey;
    this.#publicHex = Buffer.from(keys.publicKey.export({ format: 'jwk' }).x, 'base64url').toString('hex');
    this.#clock = clock;
    this.#runId = runId;
    this.#laneId = laneId;
    this.#append('lane_identity_bound', {
      run_id: runId, lane_id: laneId, agent_id: `${runId}:${laneId}`,
      manifest: safeManifest, manifest_hash: hash(safeManifest),
    });
  }
  #append(event, payload) {
    const safe = safePayload(payload);
    const now = this.#clock();
    if (typeof now !== 'number' || !Number.isFinite(now)) throw new TypeError('invalid record clock');
    const timestamp = Math.floor(now / 1000);
    if (!Number.isSafeInteger(timestamp)) throw new TypeError('invalid record clock');
    const body = { sequence: this.#events.length, previous_hash: this.#events.at(-1)?.hash || ZERO_HASH,
      timestamp, event, payload: safe };
    const digest = hash(body);
    const entry = freeze({ ...body, hash: digest, signature: sign(null, Buffer.from(digest, 'hex'), this.#privateKey).toString('base64') });
    this.#events.push(entry);
    return digest;
  }
  append(event, payload) {
    if (this.#closed) throw new Error('record is closed');
    if (typeof event !== 'string' || !/^[a-z][a-z0-9_]{0,127}$/.test(event) || ['run_closed', 'lane_identity_bound'].includes(event)) {
      throw new TypeError('invalid record event');
    }
    return this.#append(event, payload);
  }
  close() {
    if (this.#closed) return this.#closed;
    this.#append('run_closed', { event_count: this.#events.length + 1, final_hash: this.#events.at(-1).hash });
    this.#closed = freeze({ lane_id: this.#laneId, run_id: this.#runId, record_public_key: this.#publicHex, events: [...this.#events] });
    this.#privateKey = null;
    return this.#closed;
  }
}

/** Checks integrity and signed labels against optional external expectations; never establishes key ownership. */
export function verifyDecisionDocument(document, { expectedRunId, expectedLaneId, expectedManifestHash } = {}) {
  const bad = (reason) => ({ ok: false, reason, ...TRUST });
  try {
    const doc = copy(document);
    if (!exactKeys(doc, DOCUMENT_KEYS) || !identifier(doc.run_id) || !identifier(doc.lane_id)) return bad('invalid_document');
    if (typeof doc.record_public_key !== 'string' || !HEX.test(doc.record_public_key)) return bad('invalid_key');
    if (!Array.isArray(doc.events) || doc.events.length < 2) return bad('invalid_record');
    const key = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(doc.record_public_key, 'hex').toString('base64url') }, format: 'jwk' });
    let previous = ZERO_HASH;
    for (let i = 0; i < doc.events.length; i += 1) {
      const entry = doc.events[i];
      if (!exactKeys(entry, ENTRY_KEYS)) return bad('invalid_entry');
      if (!Number.isSafeInteger(entry.sequence) || entry.sequence !== i || entry.previous_hash !== previous) return bad('invalid_chain');
      if (!Number.isSafeInteger(entry.timestamp) || typeof entry.event !== 'string' || !/^[a-z][a-z0-9_]{0,127}$/.test(entry.event)) return bad('invalid_entry');
      safePayload(entry.payload);
      if (typeof entry.hash !== 'string' || !HEX.test(entry.hash)) return bad('invalid_hash');
      const body = { sequence: entry.sequence, previous_hash: entry.previous_hash, timestamp: entry.timestamp, event: entry.event, payload: entry.payload };
      if (hash(body) !== entry.hash) return bad('invalid_hash');
      if (typeof entry.signature !== 'string' || !/^[A-Za-z0-9+/]{86}==$/.test(entry.signature)) return bad('invalid_signature');
      const signature = Buffer.from(entry.signature, 'base64');
      if (signature.length !== 64 || signature.toString('base64') !== entry.signature || !verify(null, Buffer.from(entry.hash, 'hex'), key, signature)) return bad('invalid_signature');
      if ((i > 0 && entry.event === 'lane_identity_bound') || (i < doc.events.length - 1 && entry.event === 'run_closed')) return bad('invalid_record');
      previous = entry.hash;
    }
    const first = doc.events[0], identity = first.payload;
    if (first.event !== 'lane_identity_bound' || !exactKeys(identity, IDENTITY_KEYS) ||
        identity.run_id !== doc.run_id || identity.lane_id !== doc.lane_id || identity.agent_id !== `${doc.run_id}:${doc.lane_id}`) return bad('invalid_identity');
    if (!plain(identity.manifest) || typeof identity.manifest_hash !== 'string' || !HEX.test(identity.manifest_hash) || hash(identity.manifest) !== identity.manifest_hash) return bad('invalid_manifest');
    if ((expectedRunId !== undefined && doc.run_id !== expectedRunId) ||
        (expectedLaneId !== undefined && doc.lane_id !== expectedLaneId) ||
        (expectedManifestHash !== undefined && identity.manifest_hash !== expectedManifestHash)) return bad('expectation_mismatch');
    const last = doc.events.at(-1);
    if (last.event !== 'run_closed' || !exactKeys(last.payload, ['event_count', 'final_hash']) ||
        last.payload.event_count !== doc.events.length || last.payload.final_hash !== last.previous_hash) return bad('invalid_closure');
    return { ok: true, ...TRUST };
  } catch {
    return bad('invalid_document'); // Never echo untrusted payloads, exceptions or credential values.
  }
}
