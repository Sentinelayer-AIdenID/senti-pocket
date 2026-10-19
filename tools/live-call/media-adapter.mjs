// tools/live-call/media-adapter.mjs
//
// Wire + audio helpers for the CF Realtime WebSocket adapters: VOICE-02 (a member's track streamed to speech-to-text)
// and VOICE-07 (synthesized speech ingested as a call track). The SFU dials an endpoint WE host, with no custom headers;
// every binary message is a protobuf `Packet { uint32 sequenceNumber = 1; uint32 timestamp = 2; bytes payload = 5; }`
// whose audio payload is PCM s16le, 48 kHz, stereo interleaved, each serialized message at most 32 KB.
// Pure (no network, no provider) and Workers-compatible: WebCrypto only, no Node built-ins.

export const MAX_MESSAGE_BYTES = 32 * 1024;
export const SFU_RATE = 48000;
const SFU_BYTES_PER_FRAME = 4; // 2 channels x 16-bit

// ---- protobuf Packet -------------------------------------------------------------------------------------------------

const fail = (reason) => { throw new Error(`media-adapter: ${reason}`); };

function readVarint(bytes, pos, maxBytes) {
  let value = 0;
  for (let i = 0; i < maxBytes; i += 1) {
    if (pos + i >= bytes.length) fail('truncated varint');
    const b = bytes[pos + i];
    value += (b & 0x7f) * 2 ** (7 * i); // arithmetic, not bit ops: no 32-bit sign wrap
    if (b < 0x80) return { value, next: pos + i + 1 };
  }
  return fail('varint too long');
}

const MAX_FIELD = 2 ** 29 - 1; // protobuf's largest field number
const EXPECTED_WIRE = { 1: 0, 2: 0, 5: 2 }; // sequenceNumber, timestamp: varint; payload: length-delimited

function readKey(bytes, pos) {
  const key = readVarint(bytes, pos, 5);
  const field = Math.floor(key.value / 8);
  if (field === 0 || field > MAX_FIELD) fail('field number out of range');
  return { field, wire: key.value % 8, next: key.next };
}

// Skip one value of an UNKNOWN field. Groups (deprecated wire types 3/4) are skipped to their matching end tag.
function skipValue(bytes, pos, field, wire, depth = 0) {
  if (wire === 0) return readVarint(bytes, pos, 10).next;
  if (wire === 1 || wire === 5) {
    const next = pos + (wire === 1 ? 8 : 4);
    if (next > bytes.length) fail('truncated fixed field');
    return next;
  }
  if (wire === 2) {
    const len = readVarint(bytes, pos, 5);
    if (len.next + len.value > bytes.length) fail('truncated length-delimited field');
    return len.next + len.value;
  }
  if (wire === 3) {
    if (depth >= 32) fail('groups nested too deeply');
    let at = pos;
    for (;;) {
      if (at >= bytes.length) fail('unterminated group');
      const inner = readKey(bytes, at);
      if (inner.wire === 4) {
        if (inner.field !== field) fail('mismatched group end');
        return inner.next;
      }
      at = skipValue(bytes, inner.next, inner.field, inner.wire, depth + 1);
    }
  }
  return fail('unsupported wire type');
}

/**
 * Decode one adapter message. The returned `payload` is a VIEW into `bytes` (no copy): copy it if `bytes` is reused.
 * Unknown fields of every wire type (groups included) are skipped, forward compatibly. A
 * known field with the wrong wire type, a truncation, an out-of-range uint32, or a non-canonical varint wider than
 * protobuf allows for its role (tags and lengths: 5 bytes) throws; a canonical encoder never produces those.
 */
export function decodePacket(bytes) {
  if (!(bytes instanceof Uint8Array)) fail('packet must be bytes');
  if (bytes.length > MAX_MESSAGE_BYTES) fail('packet exceeds 32 KB');
  const packet = { sequenceNumber: 0, timestamp: 0, payload: new Uint8Array(0) };
  let pos = 0;
  while (pos < bytes.length) {
    const { field, wire, next } = readKey(bytes, pos);
    pos = next;
    if (!Object.hasOwn(EXPECTED_WIRE, field)) {
      if (wire === 4) fail('unexpected group end');
      pos = skipValue(bytes, pos, field, wire);
      continue;
    }
    if (wire !== EXPECTED_WIRE[field]) fail('wrong wire type for a known field');
    if (wire === 0) {
      const v = readVarint(bytes, pos, 10);
      pos = v.next;
      if (v.value > 0xffffffff) fail('uint32 out of range');
      packet[field === 1 ? 'sequenceNumber' : 'timestamp'] = v.value;
    } else {
      const len = readVarint(bytes, pos, 5);
      pos = len.next;
      if (pos + len.value > bytes.length) fail('truncated length-delimited field');
      packet.payload = bytes.subarray(pos, pos + len.value);
      pos += len.value;
    }
  }
  return packet;
}

function writeVarint(out, value) {
  let v = value;
  while (v >= 0x80) { out.push((v % 0x80) | 0x80); v = Math.floor(v / 0x80); }
  out.push(v);
}

/** Encode one adapter message. Ingest needs only `payload`; zero/absent numeric fields are omitted (proto3 default). */
export function encodePacket({ sequenceNumber, timestamp, payload = new Uint8Array(0) } = {}) {
  if (!(payload instanceof Uint8Array)) fail('payload must be bytes');
  const head = [];
  for (const [field, value] of [[1, sequenceNumber], [2, timestamp]]) {
    if (value === undefined || value === 0) continue;
    if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) fail('uint32 out of range');
    writeVarint(head, field * 8);
    writeVarint(head, value);
  }
  writeVarint(head, 5 * 8 + 2);
  writeVarint(head, payload.length);
  if (head.length + payload.length > MAX_MESSAGE_BYTES) fail('packet exceeds 32 KB');
  const out = new Uint8Array(head.length + payload.length);
  out.set(head, 0);
  out.set(payload, head.length);
  return out;
}

// ---- audio -----------------------------------------------------------------------------------------------------------

const clamp16 = (x) => Math.max(-32768, Math.min(32767, Math.round(x)));

function stereoFrames(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length % SFU_BYTES_PER_FRAME !== 0) fail('PCM must be whole s16le stereo frames');
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

const MIN_TAPS = 47;

// Stateful FIR over one channel: each call takes the next input sample and returns the filtered output sample.
function createFir(h) {
  const n = h.length;
  const history = new Float64Array(n);
  let head = 0;
  return (x) => {
    history[head] = x;
    head = (head + 1) % n;
    let acc = 0;
    for (let k = 0; k < n; k += 1) acc += h[k] * history[(head - 1 - k + 2 * n) % n];
    return acc;
  };
}

// Windowed-sinc low-pass (Hamming), unity DC gain. 7 kHz cutoff at 48 kHz keeps the speech band and stops content above
// the 8 kHz Nyquist of the 16 kHz output from folding back into it.
function lowPassTaps(count, cutoffHz, rateHz) {
  const fc = cutoffHz / rateHz;
  const mid = (count - 1) / 2;
  const taps = Array.from({ length: count }, (_, n) => {
    const x = n - mid;
    const sinc = x === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * x) / (Math.PI * x);
    return sinc * (0.54 - 0.46 * Math.cos((2 * Math.PI * n) / (count - 1)));
  });
  const sum = taps.reduce((a, b) => a + b, 0);
  return taps.map((t) => t / sum);
}

/**
 * Streaming 48 kHz stereo -> 16 kHz mono (what speech-to-text providers take). Stateful: the filter history and the
 * decimation phase carry across calls, so the output does not depend on how the stream was chunked.
 */
export function createDownsampler48kStereoTo16kMono({ taps = 63, cutoffHz = 7000 } = {}) {
  // Odd length keeps the filter linear-phase; below ~47 taps the stopband is too shallow to anti-alias (15 taps leaves
  // 9 kHz only -13.5 dB down); the cutoff must sit below the 8 kHz output Nyquist.
  if (!Number.isInteger(taps) || taps < MIN_TAPS || taps > 255 || taps % 2 === 0) fail(`taps must be an odd integer in ${MIN_TAPS}..255`);
  if (!Number.isFinite(cutoffHz) || cutoffHz <= 0 || cutoffHz >= 8000) fail('cutoffHz must be in (0, 8000)');
  const h = lowPassTaps(taps, cutoffHz, SFU_RATE);
  const history = new Float64Array(taps); // ring of the last `taps` mono samples
  let head = 0;
  let phase = 0; // input samples since the last emitted one
  return function push(bytes) {
    const view = stereoFrames(bytes);
    const frames = bytes.length / SFU_BYTES_PER_FRAME;
    const out = [];
    for (let i = 0; i < frames; i += 1) {
      history[head] = (view.getInt16(i * 4, true) + view.getInt16(i * 4 + 2, true)) / 2;
      head = (head + 1) % taps;
      phase += 1;
      if (phase === 3) {
        phase = 0;
        let acc = 0;
        for (let k = 0; k < taps; k += 1) acc += h[k] * history[(head - 1 - k + 2 * taps) % taps];
        out.push(clamp16(acc));
      }
    }
    return Int16Array.from(out);
  };
}

/**
 * Streaming mono (16, 24 or 48 kHz, what TTS providers emit) -> 48 kHz stereo s16le bytes for an ingest adapter.
 * Linear interpolation from the previous sample, then a low-pass just under the input Nyquist: interpolation alone leaves
 * images of the input spectrum around multiples of the input rate (audible, and they survive Opus). Stateful across
 * calls, so chunk boundaries are seamless. A 48 kHz input passes through unfiltered.
 */
export function createUpsamplerMonoTo48kStereo(inputRate) {
  const factor = SFU_RATE / inputRate;
  if (![1, 2, 3].includes(factor)) fail('input rate must be 16000, 24000 or 48000');
  const filter = factor === 1 ? (x) => x : createFir(lowPassTaps(63, inputRate * 0.45, SFU_RATE));
  let previous = null;
  return function push(samples) {
    if (!(samples instanceof Int16Array)) fail('samples must be Int16Array');
    const out = new Uint8Array(samples.length * factor * SFU_BYTES_PER_FRAME);
    const view = new DataView(out.buffer);
    let o = 0;
    for (const s of samples) {
      const from = previous === null ? s : previous;
      for (let j = 1; j <= factor; j += 1) {
        const v = clamp16(filter(from + ((s - from) * j) / factor));
        view.setInt16(o, v, true);
        view.setInt16(o + 2, v, true);
        o += SFU_BYTES_PER_FRAME;
      }
      previous = s;
    }
    return out;
  };
}

/**
 * Cut 48 kHz stereo PCM into adapter payloads of `frameMs` (default 20 ms = 3840 bytes, far under 32 KB). Partial frames
 * are held until complete; `flush()` returns the remainder (possibly empty) at end of speech.
 */
export function createPacketizer({ frameMs = 20 } = {}) {
  const frameBytes = (SFU_RATE / 1000) * frameMs * SFU_BYTES_PER_FRAME;
  if (!Number.isInteger(frameBytes) || frameBytes <= 0 || frameBytes % SFU_BYTES_PER_FRAME !== 0 ||
      frameBytes + 16 > MAX_MESSAGE_BYTES) fail('invalid frame size');
  let chunks = [];
  let held = 0;
  const join = () => {
    const all = new Uint8Array(held);
    let at = 0;
    for (const c of chunks) { all.set(c, at); at += c.length; }
    return all;
  };
  return {
    push(bytes) {
      stereoFrames(bytes);
      chunks.push(bytes.slice());
      held += bytes.length;
      if (held < frameBytes) return []; // nothing complete yet: no copy of what is held
      const all = join();
      const whole = all.length - (all.length % frameBytes);
      const payloads = [];
      for (let i = 0; i < whole; i += frameBytes) payloads.push(all.slice(i, i + frameBytes));
      chunks = whole < all.length ? [all.slice(whole)] : [];
      held = all.length - whole;
      return payloads;
    },
    flush() {
      const rest = held ? join() : null;
      chunks = [];
      held = 0;
      return rest ? [rest] : [];
    },
  };
}

/**
 * Streaming bytes -> Int16Array for PCM s16le arriving in arbitrary chunks (a TTS response body can split a sample
 * across chunks). An odd trailing byte is carried to the next push; `pending()` reports whether one is held.
 */
export function createPcm16Reader() {
  let carry = null;
  return {
    push(bytes) {
      if (!(bytes instanceof Uint8Array)) fail('PCM must be bytes');
      let all = bytes;
      if (carry !== null) { all = new Uint8Array(bytes.length + 1); all[0] = carry; all.set(bytes, 1); }
      const even = all.length - (all.length % 2);
      carry = even < all.length ? all[all.length - 1] : null;
      const view = new DataView(all.buffer, all.byteOffset, even);
      const out = new Int16Array(even / 2);
      for (let i = 0; i < out.length; i += 1) out[i] = view.getInt16(i * 2, true);
      return out;
    },
    pending: () => carry !== null,
  };
}

// ---- endpoint tokens -------------------------------------------------------------------------------------------------
// The SFU cannot send headers, so each adapter endpoint carries a scoped token in its URL. Only the SHA-256 digest is
// stored; the token stays valid across the SFU's own reconnects and dies when the adapter is closed.

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
const base64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const TOKEN = /^[A-Za-z0-9_-]{43}$/;

export async function createAdapterToken() {
  const token = base64url(crypto.getRandomValues(new Uint8Array(32)));
  return { token, digest: hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token))) };
}

/** Constant-time over the digest; a malformed token is rejected before hashing. */
export async function verifyAdapterToken(presented, digest) {
  if (typeof presented !== 'string' || !TOKEN.test(presented) || typeof digest !== 'string' || !/^[0-9a-f]{64}$/.test(digest)) return false;
  const got = hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(presented)));
  let diff = 0;
  for (let i = 0; i < 64; i += 1) diff |= got.charCodeAt(i) ^ digest.charCodeAt(i);
  return diff === 0;
}
