import test from 'node:test';
import assert from 'node:assert/strict';
import { ingestPackets, streamToIngest } from './tts-ingest.mjs';
import { decodePacket } from './media-adapter.mjs';

const tone = (samples, rate = 24000) => {
  const pcm = Int16Array.from({ length: samples }, (_, i) => Math.round(6000 * Math.sin((2 * Math.PI * 220 * i) / rate)));
  return new Uint8Array(pcm.buffer);
};
async function* chunksOf(bytes, sizes) {
  let at = 0;
  for (let i = 0; at < bytes.length; i += 1) {
    const n = sizes[i % sizes.length];
    yield bytes.subarray(at, at + n);
    at += n;
  }
}
const collect = async (iter) => { const out = []; for await (const x of iter) out.push(x); return out; };

test('TTS bytes become 20 ms adapter messages of 48 kHz stereo, independent of how the body was chunked', async () => {
  const bytes = tone(24000); // 1 s at 24 kHz
  const whole = await collect(ingestPackets(chunksOf(bytes, [bytes.length])));
  const ragged = await collect(ingestPackets(chunksOf(bytes, [1, 999, 3, 4096, 7])));
  assert.equal(whole.length, 50);
  assert.deepEqual(ragged.map((p) => [...p].join(',')), whole.map((p) => [...p].join(',')));
  for (const packet of whole) assert.equal(decodePacket(packet).payload.length, 3840);
});

test('a stream that ends mid-sample is an error, and a short tail is flushed as a final partial frame', async () => {
  await assert.rejects(collect(ingestPackets(chunksOf(tone(100).subarray(0, 199), [199]))), /mid-sample/);
  const tail = await collect(ingestPackets(chunksOf(tone(300), [600])));
  assert.deepEqual(tail.map((p) => decodePacket(p).payload.length), [2400]); // 300 samples x2 rate x4 bytes, < one frame
});

function fakeClock() {
  let t = 1000;
  return { now: () => t, sleep: async (ms) => { t += ms; }, advance: (ms) => { t += ms; } };
}

test('frames are paced at real time with a small lead, and first-frame latency is measured from the hand-off', async () => {
  const clock = fakeClock();
  const sentAt = [];
  const startedAt = clock.now();
  clock.advance(150); // TTS time-to-first-byte before any audio exists
  const stats = await streamToIngest(chunksOf(tone(24000), [4800]), async () => { sentAt.push(clock.now()); },
    { now: clock.now, sleep: clock.sleep, startedAt });
  assert.equal(stats.frames, 50);
  assert.equal(stats.audioMs, 1000);
  assert.equal(stats.firstFrameMs, 150);
  assert.equal(stats.stalls, 0);
  const first = sentAt[0];
  // Lead 60 ms: frames 0-3 go immediately, then one every 20 ms, ending 60 ms before the audio would finish playing.
  assert.deepEqual(sentAt.slice(0, 5).map((t) => t - first), [0, 0, 0, 0, 20]);
  assert.equal(sentAt.at(-1) - first, 49 * 20 - 60);
});

test('a slow sender is reported as stalls instead of silently piling frames up', async () => {
  const clock = fakeClock();
  const stats = await streamToIngest(chunksOf(tone(24000), [48000]), async () => { clock.advance(45); }, { now: clock.now, sleep: clock.sleep });
  assert.ok(stats.stalls > 0 && stats.stallMs > 0);
  await assert.rejects(streamToIngest(chunksOf(tone(10), [20]), null), /send required/);
});

test('a mid-stream TTS stall is re-paced as a gap, never sent as a burst the SFU would clip', async () => {
  const clock = fakeClock();
  async function* stalling() {
    yield tone(4800); // 200 ms of audio
    clock.advance(600); // the provider stalls
    yield tone(24000); // then 1 s more
  }
  const sentAt = [];
  const stats = await streamToIngest(stalling(), async () => { sentAt.push(clock.now()); }, { now: clock.now, sleep: clock.sleep });
  const perInstant = sentAt.reduce((m, t) => m.set(t, (m.get(t) || 0) + 1), new Map());
  const maxBurst = Math.max(...perInstant.values());
  assert.ok(maxBurst <= Math.ceil(60 / 20) + 1, `burst of ${maxBurst} frames at one instant`);
  assert.equal(stats.frames, 60);
  assert.equal(stats.stalls, 1);
  assert.ok(stats.stallMs >= 400, `stall ${stats.stallMs} ms`);
  // After the stall the frames are paced again: consecutive sends at most a lead apart, then every 20 ms.
  const gaps = sentAt.slice(1).map((t, i) => t - sentAt[i]);
  assert.ok(gaps.slice(-20).every((g) => g === 20));
});
