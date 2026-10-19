import test from 'node:test';
import assert from 'node:assert/strict';
import {
  MAX_MESSAGE_BYTES, decodePacket, encodePacket, createDownsampler48kStereoTo16kMono, createUpsamplerMonoTo48kStereo,
  createPacketizer, createAdapterToken, verifyAdapterToken,
} from './media-adapter.mjs';

// Hand-assembled from the protobuf wire format: field 1 varint 300 (08 AC 02), field 2 varint 1 (10 01),
// field 5 length-delimited [1, 2] (2A 02 01 02). Pins the codec to the spec, not to itself.
const VECTOR = Uint8Array.from([0x08, 0xac, 0x02, 0x10, 0x01, 0x2a, 0x02, 0x01, 0x02]);

test('Packet matches the protobuf wire format in both directions', () => {
  const p = decodePacket(VECTOR);
  assert.equal(p.sequenceNumber, 300);
  assert.equal(p.timestamp, 1);
  assert.deepEqual([...p.payload], [1, 2]);
  assert.deepEqual([...encodePacket({ sequenceNumber: 300, timestamp: 1, payload: Uint8Array.from([1, 2]) })], [...VECTOR]);
  assert.deepEqual([...encodePacket({ payload: Uint8Array.from([7]) })], [0x2a, 0x01, 0x07]); // ingest: payload only
  const max = decodePacket(encodePacket({ sequenceNumber: 0xffffffff, timestamp: 0xffffffff }));
  assert.equal(max.sequenceNumber, 0xffffffff);
  assert.equal(max.timestamp, 0xffffffff);
});

test('unknown fields are skipped without disturbing known ones', () => {
  const withUnknown = Uint8Array.from([
    0x18, 0x05, // field 3 varint
    0x22, 0x01, 0xff, // field 4 length-delimited
    0x35, 0, 0, 0, 0, // field 6 fixed32
    0x39, 0, 0, 0, 0, 0, 0, 0, 0, // field 7 fixed64
    ...VECTOR,
  ]);
  const p = decodePacket(withUnknown);
  assert.equal(p.sequenceNumber, 300);
  assert.deepEqual([...p.payload], [1, 2]);
});

test('malformed or oversized messages throw instead of yielding a partial packet', () => {
  for (const bad of [
    [0x08], // key then nothing
    [0x08, 0xac], // truncated varint
    [0x2a, 0x05, 0x01], // length past end
    [0x0b], // group (wire type 3)
    [0x02, 0x00], // field number 0
    [0x2d, 0, 0, 0, 0], // payload as fixed32
    [0x08, 0x80, 0x80, 0x80, 0x80, 0x10], // 2^32: uint32 out of range
    [0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01], // varint over 10 bytes
  ]) assert.throws(() => decodePacket(Uint8Array.from(bad)), /media-adapter/, JSON.stringify(bad));
  assert.throws(() => decodePacket(new Uint8Array(MAX_MESSAGE_BYTES + 1)), /32 KB/);
  assert.throws(() => encodePacket({ payload: new Uint8Array(MAX_MESSAGE_BYTES) }), /32 KB/);
  assert.throws(() => decodePacket([0x08, 0x01]), /bytes/);
});

function stereoTone(hz, seconds, amplitude, { antiphase = false } = {}) {
  const frames = Math.round(48000 * seconds);
  const out = new Uint8Array(frames * 4);
  const view = new DataView(out.buffer);
  for (let i = 0; i < frames; i += 1) {
    const v = Math.round(amplitude * Math.sin((2 * Math.PI * hz * i) / 48000));
    view.setInt16(i * 4, v, true);
    view.setInt16(i * 4 + 2, antiphase ? -v : v, true);
  }
  return out;
}
const rms = (samples, skip = 0) => Math.sqrt(samples.slice(skip).reduce((a, s) => a + s * s, 0) / (samples.length - skip));

test('48 kHz stereo -> 16 kHz mono keeps speech-band tones and stops aliasing tones', () => {
  const speech = createDownsampler48kStereoTo16kMono()(stereoTone(1000, 0.2, 10000));
  assert.equal(speech.length, 3200);
  assert.ok(Math.abs(rms(speech, 100) - 10000 / Math.SQRT2) < 0.03 * (10000 / Math.SQRT2), `1 kHz rms ${rms(speech, 100)}`);
  // 12 kHz would fold to 4 kHz without the low-pass; it must be at least 40 dB down.
  const alias = createDownsampler48kStereoTo16kMono()(stereoTone(12000, 0.2, 10000));
  assert.ok(rms(alias, 100) < 0.01 * (10000 / Math.SQRT2), `12 kHz leaked rms ${rms(alias, 100)}`);
  const cancelled = createDownsampler48kStereoTo16kMono()(stereoTone(1000, 0.1, 10000, { antiphase: true }));
  assert.ok(rms(cancelled) < 1, 'L and R are averaged into mono');
});

test('the downsampler output does not depend on how the stream was chunked', () => {
  const input = stereoTone(440, 0.3, 12000);
  const whole = createDownsampler48kStereoTo16kMono()(input);
  const push = createDownsampler48kStereoTo16kMono();
  const parts = [];
  let seed = 7;
  for (let pos = 0; pos < input.length;) {
    seed = (seed * 1103515245 + 12345) % 2 ** 31;
    const n = Math.min(input.length - pos, 4 * (1 + (seed % 700)));
    parts.push(...push(input.subarray(pos, pos + n)));
    pos += n;
  }
  assert.deepEqual(parts, [...whole]);
  assert.throws(() => push(new Uint8Array(6)), /whole s16le stereo frames/);
});

test('mono TTS audio -> 48 kHz stereo: right length, both channels, seamless across chunks', () => {
  const mono = Int16Array.from({ length: 2400 }, (_, i) => Math.round(8000 * Math.sin((2 * Math.PI * 300 * i) / 24000)));
  const whole = createUpsamplerMonoTo48kStereo(24000)(mono);
  assert.equal(whole.length, 2400 * 2 * 4);
  const view = new DataView(whole.buffer);
  for (let f = 0; f < whole.length / 4; f += 97) assert.equal(view.getInt16(f * 4, true), view.getInt16(f * 4 + 2, true));
  const push = createUpsamplerMonoTo48kStereo(24000);
  const chunked = [...push(mono.subarray(0, 1000)), ...push(mono.subarray(1000, 1001)), ...push(mono.subarray(1001))];
  assert.deepEqual(chunked, [...whole]);
  assert.equal(createUpsamplerMonoTo48kStereo(16000)(Int16Array.from([0, 300])).length, 2 * 3 * 4);
  assert.throws(() => createUpsamplerMonoTo48kStereo(44100), /input rate/);
});

test('the packetizer emits whole 20 ms frames that each fit one adapter message, and flushes the remainder', () => {
  const p = createPacketizer();
  const out = p.push(new Uint8Array(10000));
  assert.deepEqual(out.map((x) => x.length), [3840, 3840]);
  assert.deepEqual(p.push(new Uint8Array(4)).map((x) => x.length), []);
  assert.deepEqual(p.flush().map((x) => x.length), [2324]);
  assert.deepEqual(p.flush(), []);
  for (const payload of out) assert.ok(encodePacket({ payload }).length <= MAX_MESSAGE_BYTES);
});

test('adapter endpoint tokens: only the digest is stored, and only the exact token verifies', async () => {
  const a = await createAdapterToken();
  const b = await createAdapterToken();
  assert.match(a.token, /^[A-Za-z0-9_-]{43}$/);
  assert.match(a.digest, /^[0-9a-f]{64}$/);
  assert.equal(a.digest.includes(a.token), false);
  assert.notEqual(a.token, b.token);
  assert.equal(await verifyAdapterToken(a.token, a.digest), true);
  assert.equal(await verifyAdapterToken(b.token, a.digest), false);
  assert.equal(await verifyAdapterToken(a.token.slice(0, -1) + (a.token.at(-1) === 'A' ? 'B' : 'A'), a.digest), false);
  for (const bad of [undefined, '', 'short', a.token + '=', a.digest]) assert.equal(await verifyAdapterToken(bad, a.digest), false);
  assert.equal(await verifyAdapterToken(a.token, 'not-a-digest'), false);
});
