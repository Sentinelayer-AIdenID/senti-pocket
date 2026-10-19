// tools/live-call/tts-ingest.mjs
//
// VOICE-07: synthesized speech -> the message stream a CF Realtime ingest adapter reads. The SFU dials our endpoint and
// takes protobuf Packets whose payload is 48 kHz stereo s16le (media-adapter.mjs). Its audio backlog is short and drops
// the OLDEST frames when full, so a whole utterance sent at once would be clipped: frames go out paced at real time,
// slightly ahead (leadMs) to absorb jitter. Provider-agnostic: any TTS that streams mono s16le at 16/24/48 kHz bytes
// (e.g. the gateway's ElevenLabs backend with output_format pcm_24000). Pure apart from the injected clock/sleep/send.

import { createPcm16Reader, createUpsamplerMonoTo48kStereo, createPacketizer, encodePacket } from './media-adapter.mjs';

/** Encoded adapter messages (20 ms each) for a stream of TTS byte chunks; the final partial frame is flushed at the end. */
export async function* ingestPackets(chunks, { inputRate = 24000, frameMs = 20 } = {}) {
  const reader = createPcm16Reader();
  const upsample = createUpsamplerMonoTo48kStereo(inputRate);
  const packetizer = createPacketizer({ frameMs });
  for await (const chunk of chunks) {
    for (const payload of packetizer.push(upsample(reader.push(chunk)))) yield encodePacket({ payload });
  }
  if (reader.pending()) throw new Error('tts-ingest: stream ended mid-sample');
  for (const payload of packetizer.flush()) yield encodePacket({ payload });
}

/**
 * Send TTS audio to an ingest adapter connection at real time. Frame i is sent no earlier than its play time minus
 * leadMs. If the TTS stream stalls so far that a frame would play more than one frame late, the schedule is re-anchored
 * at that frame: the listener hears the stall as a gap, instead of the backlog going out in one burst that the SFU's
 * short buffer would answer by dropping the OLDEST speech. Returns measured stats: frames sent, time from the call to
 * the first frame (the ticket's "first sentence to first audio frame" when `startedAt` is when the sentence was handed
 * to TTS), and the stalls (re-anchors) with their total gap.
 */
export async function streamToIngest(chunks, send, {
  inputRate = 24000, frameMs = 20, leadMs = 60, now = () => performance.now(), sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  startedAt = now(),
} = {}) {
  if (typeof send !== 'function') throw new Error('tts-ingest: send required');
  let frames = 0;
  let stalls = 0;
  let stallMs = 0;
  let firstFrameMs = null;
  let schedule = null;
  for await (const packet of ingestPackets(chunks, { inputRate, frameMs })) {
    if (schedule === null) schedule = now(); // pace from the first frame: TTS time-to-first-byte is not audio time
    let playsAt = schedule + frames * frameMs; // when this frame is heard on a real-time schedule
    const behind = now() - playsAt;
    if (behind > frameMs) { // stalled: re-pace from now rather than burst the backlog
      stalls += 1;
      stallMs += behind;
      schedule += behind;
      playsAt += behind;
    }
    const wait = playsAt - leadMs - now();
    if (wait > 0) await sleep(wait);
    await send(packet);
    if (firstFrameMs === null) firstFrameMs = now() - startedAt;
    frames += 1;
  }
  return { frames, firstFrameMs, stalls, stallMs: Math.round(stallMs), audioMs: frames * frameMs };
}
