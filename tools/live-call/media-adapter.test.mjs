import test from 'node:test';
import assert from 'node:assert/strict';
import {
  MAX_MESSAGE_BYTES, decodePacket, encodePacket, createDownsampler48kStereoTo16kMono, createUpsamplerMonoTo48kStereo,
  createPacketizer, createPcm16Reader, createAdapterToken, verifyAdapterToken,
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

test('unknown groups are skipped to their matching end tag, and fields inside them are not read as top-level fields', () => {
  const group = [0x1b, 0x08, 0x05, 0x23, 0x10, 0x07, 0x24, 0x1c]; // field 3 group { field 1 = 5, field 4 group { field 2 = 7 } }
  const p = decodePacket(Uint8Array.from([...VECTOR, ...group]));
  assert.equal(p.sequenceNumber, 300);
  assert.equal(p.timestamp, 1);
  for (const bad of [
    [0x1b, 0x08, 0x01], // unterminated group
    [0x1b, 0x24], // group 3 closed by field 4's end tag
    [0x1c], // end tag with no start
  ]) assert.throws(() => decodePacket(Uint8Array.from(bad)), /group/, JSON.stringify(bad));
});

test('a known field with the wrong wire type, or a field number past protobuf\'s maximum, throws', () => {
  for (const bad of [
    [0x0a, 0x01, 0x00], // sequenceNumber as length-delimited
    [0x12, 0x00], // timestamp as length-delimited
    [0x28, 0x01], // payload as varint
    [0x80, 0x80, 0x80, 0x80, 0x10, 0x07], // field 2^29: one past the maximum
  ]) assert.throws(() => decodePacket(Uint8Array.from(bad)), /media-adapter/, JSON.stringify(bad));
  assert.equal(decodePacket(Uint8Array.from([0xf8, 0xff, 0xff, 0xff, 0x0f, 0x01])).sequenceNumber, 0); // max field: skipped
});

test('filter options that cannot anti-alias are refused instead of silently producing silence', () => {
  for (const opts of [{ taps: 1 }, { taps: 64 }, { taps: 301 }, { cutoffHz: 0 }, { cutoffHz: 8000 }, { cutoffHz: 24000 }, { cutoffHz: NaN }]) {
    assert.throws(() => createDownsampler48kStereoTo16kMono(opts), /taps|cutoffHz/, JSON.stringify(opts));
  }
});

test('the packetizer only cuts whole stereo frames and handles tiny pushes in linear time', () => {
  assert.throws(() => createPacketizer({ frameMs: 0.015625 }), /frame size/);
  const input = stereoTone(500, 1, 9000);
  const oneShot = createPacketizer();
  const expected = [...oneShot.push(input), ...oneShot.flush()].map((x) => [...x].join(','));
  const tiny = createPacketizer();
  const got = [];
  for (let i = 0; i < input.length; i += 4) got.push(...tiny.push(input.subarray(i, i + 4)));
  got.push(...tiny.flush());
  assert.deepEqual(got.map((x) => [...x].join(',')), expected);
});

test('the PCM reader carries a sample split across chunks and reads views at odd offsets', () => {
  const samples = Int16Array.from([1, -2, 32767, -32768, 300]);
  const bytes = new Uint8Array(samples.buffer.slice(0));
  const backing = new Uint8Array(bytes.length + 3);
  backing.set(bytes, 3);
  const view = backing.subarray(3); // odd byteOffset
  const reader = createPcm16Reader();
  const out = [...reader.push(view.subarray(0, 3)), ...reader.push(view.subarray(3, 3)), ...reader.push(view.subarray(3, 7))];
  assert.equal(reader.pending(), true, '7 of 10 bytes in: one byte of the 4th sample is held');
  out.push(...reader.push(view.subarray(7)));
  assert.equal(reader.pending(), false);
  assert.deepEqual(out, [...samples]);
  reader.push(Uint8Array.of(0x01));
  assert.equal(reader.pending(), true);
});

// Assertions that kill mutants the independent review (opus-proof, #169) found surviving.
test('truncated UNKNOWN fixed and length-delimited fields throw (never a silently accepted short packet)', () => {
  for (const bad of [
    [0x35, 0x00, 0x00], // field 6 fixed32 with 2 of 4 bytes
    [0x31, 0x00, 0x00, 0x00], // field 6 fixed64 with 3 of 8 bytes
    [0x32, 0x05, 0x01], // field 6 length 5 with 1 byte
  ]) assert.throws(() => decodePacket(Uint8Array.from([...VECTOR, ...bad])), /truncated/, JSON.stringify(bad));
});

test('groups nested past the depth cap throw', () => {
  const nest = (n) => Uint8Array.from([...Array(n).fill(0x33), ...Array(n).fill(0x34)]); // field 6 groups
  assert.equal(decodePacket(nest(30)).sequenceNumber, 0);
  assert.throws(() => decodePacket(nest(40)), /nested too deeply/);
});

const leftChannel = (bytes) => { const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); return Array.from({ length: bytes.length / 4 }, (_, i) => v.getInt16(i * 4, true)); };
function goertzelDb(samples, hz, rate) {
  const w = (2 * Math.PI * hz) / rate;
  let s1 = 0; let s2 = 0;
  for (const x of samples) { const s0 = x + 2 * Math.cos(w) * s1 - s2; s2 = s1; s1 = s0; }
  return 10 * Math.log10(Math.max(1e-12, s1 * s1 + s2 * s2 - 2 * Math.cos(w) * s1 * s2));
}
const monoTone = (hz, rate, n, amp) => Int16Array.from({ length: n }, (_, i) => Math.round(amp * Math.sin((2 * Math.PI * hz * i) / rate)));

test('filter overshoot is clamped, never wrapped to the opposite sign', () => {
  const step = new Uint8Array(4 * 4800);
  const v = new DataView(step.buffer);
  for (let i = 2400; i < 4800; i += 1) { v.setInt16(i * 4, 32767, true); v.setInt16(i * 4 + 2, 32767, true); }
  const down = createDownsampler48kStereoTo16kMono()(step);
  assert.ok(down.slice(820).every((x) => x >= 0), 'a full-scale step wrapped negative in the downsampler');
  const up = leftChannel(createUpsamplerMonoTo48kStereo(16000)(Int16Array.from({ length: 1600 }, (_, i) => (i < 800 ? 0 : 32767))));
  assert.ok(up.slice(2460).every((x) => x >= 0), 'a full-scale step wrapped negative in the upsampler');
});

test('a digest that differs only in its last character is rejected', async () => {
  const a = await createAdapterToken();
  const flipped = a.digest.slice(0, 63) + (a.digest[63] === '0' ? '1' : '0');
  assert.equal(await verifyAdapterToken(a.token, flipped), false);
});

test('the default anti-alias response: flat to 6 kHz, -6 dB at the 7 kHz cutoff, >= 40 dB down above 8.5 kHz', () => {
  const at = (hz) => { const out = createDownsampler48kStereoTo16kMono()(stereoTone(hz, 0.2, 10000)); return 20 * Math.log10(rms(out, 100) / (10000 / Math.SQRT2)); };
  assert.ok(at(6000) > -0.5, `6 kHz ${at(6000)}`);
  assert.ok(Math.abs(at(7000) + 6) < 1, `7 kHz ${at(7000)}`);
  assert.ok(at(8500) < -40, `8.5 kHz ${at(8500)}`);
});

test('fewer than 47 taps is refused; the minimum still anti-aliases', () => {
  assert.throws(() => createDownsampler48kStereoTo16kMono({ taps: 45 }), /47/);
  assert.throws(() => createDownsampler48kStereoTo16kMono({ taps: 3 }), /47/);
  const out = createDownsampler48kStereoTo16kMono({ taps: 47 })(stereoTone(12000, 0.2, 10000));
  assert.ok(rms(out, 100) < 0.01 * (10000 / Math.SQRT2));
});

test('the TTS upsampler keeps DC and the speech band, and suppresses interpolation images by >= 40 dB', () => {
  const dc = leftChannel(createUpsamplerMonoTo48kStereo(16000)(new Int16Array(400).fill(1000)));
  assert.ok(dc.slice(100).every((x) => x === 1000), 'unity DC gain');
  // A 4 kHz tone: interpolation images sit at rate +/- 4 kHz and are strongest for high in-band tones (a 1 kHz tone's
  // images are already ~44 dB down from linear interpolation alone, so it could not show a missing filter).
  for (const [rate, images] of [[16000, [12000, 20000]], [24000, [20000]]]) {
    const up = leftChannel(createUpsamplerMonoTo48kStereo(rate)(monoTone(4000, rate, rate / 2, 8000))).slice(200);
    const tone = goertzelDb(up, 4000, 48000);
    for (const hz of images) assert.ok(goertzelDb(up, hz, 48000) - tone < -40, `${rate}: image ${hz} only ${goertzelDb(up, hz, 48000) - tone} dBc`);
    const band = leftChannel(createUpsamplerMonoTo48kStereo(rate)(monoTone(3000, rate, rate / 2, 8000))).slice(200);
    assert.ok(Math.abs(rms(band) - 8000 / Math.SQRT2) < 0.12 * (8000 / Math.SQRT2), `${rate}: 3 kHz level ${rms(band)}`);
  }
});
