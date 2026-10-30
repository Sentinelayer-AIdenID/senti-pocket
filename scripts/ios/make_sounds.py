"""Renders Senti Pocket's notification and in-app sounds as 16-bit mono WAV (converted to CAF with afconvert).

chime:   the web's ticket chime (sentinelayer-web src/lib/noticeChime.ts): sine 880 Hz then 1174.66 Hz, each starting
         0.14 s apart, gain 0.0001 -> peak over 0.02 s, then -> 0.0001 at 0.13 s (exponential ramps).
silence: half a second of nothing, so a push with sound off still vibrates.
receive: a soft "pop" for a message arriving in the room on screen.
send:    a soft rising "swish" for a message you sent.
ring:    the ringtone for an agent's call: a bright four-note marimba-like rise (E5, G#5, B5, E6), twice, then a
         breath of silence, so CallKit's loop of it sounds like a phone ringing rather than one long tone.
"""
import math
import struct
import sys
import wave

RATE = 44100


def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in samples))


def exp_ramp(v0, v1, t0, t1, t):
    """Web Audio exponentialRampToValueAtTime between (t0, v0) and (t1, v1)."""
    if t <= t0:
        return v0
    if t >= t1:
        return v1
    return v0 * (v1 / v0) ** ((t - t0) / (t1 - t0))


def chime(peak):
    length = 0.36
    out = []
    for n in range(int(length * RATE)):
        t = n / RATE
        value = 0.0
        for index, hz in ((0, 880.0), (1, 1174.66)):
            at = 0.01 + index * 0.14
            if at <= t < at + 0.14:
                if t < at + 0.02:
                    gain = exp_ramp(0.0001, peak, at, at + 0.02, t)
                else:
                    gain = exp_ramp(peak, 0.0001, at + 0.02, at + 0.13, t)
                value += gain * math.sin(2 * math.pi * hz * (t - at))
        out.append(value)
    return out


def glide(f0, f1, length, peak, attack, decay):
    """A sine sweeping f0 -> f1 with a short attack and an exponential decay."""
    out = []
    phase = 0.0
    for n in range(int(length * RATE)):
        t = n / RATE
        hz = f0 + (f1 - f0) * min(1.0, t / (length * 0.6))
        phase += 2 * math.pi * hz / RATE
        env = (t / attack) if t < attack else math.exp(-(t - attack) / decay)
        out.append(peak * env * math.sin(phase))
    return out


def ring(peak):
    """Two rises of four struck notes; each note a sine with a quick attack, its octave and double octave fading
    faster, like a mallet on wood."""
    notes = (659.25, 830.61, 987.77, 1318.51)
    starts = [rise + index * 0.16 for rise in (0.0, 1.2) for index in range(len(notes))]
    pitches = [notes[index] for _ in range(2) for index in range(len(notes))]
    length = 3.4
    out = [0.0] * int(length * RATE)
    for at, hz in zip(starts, pitches):
        begin = int(at * RATE)
        for n in range(int(0.7 * RATE)):
            if begin + n >= len(out):
                break
            t = n / RATE
            attack = min(1.0, t / 0.004)
            body = math.exp(-t / 0.16) * math.sin(2 * math.pi * hz * t)
            octave = 0.30 * math.exp(-t / 0.07) * math.sin(2 * math.pi * 2 * hz * t)
            double = 0.10 * math.exp(-t / 0.03) * math.sin(2 * math.pi * 4 * hz * t)
            out[begin + n] += attack * (body + octave + double)
    loudest = max(abs(v) for v in out)
    return [peak * v / loudest for v in out]


if __name__ == "__main__":
    folder = sys.argv[1]
    write(f"{folder}/chime.wav", chime(peak=0.45))
    write(f"{folder}/silence.wav", [0.0] * int(0.5 * RATE))
    write(f"{folder}/receive.wav", glide(1046.5, 783.99, 0.14, 0.30, 0.004, 0.035))
    write(f"{folder}/send.wav", glide(620.0, 1240.0, 0.12, 0.20, 0.006, 0.03))
    write(f"{folder}/ring.wav", ring(peak=0.6))
    print("written")
