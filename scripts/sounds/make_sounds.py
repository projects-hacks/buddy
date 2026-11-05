"""Synthesises Buddy's interface sounds into leanring-buddy/VoiceOut/Sounds.

Made here rather than taken from anywhere, so they are ours to ship, and so
each can be tuned by changing a number. Every sound is short (under a fifth
of a second), soft at both ends so it never clicks, and peaks well below
full scale: the player sets the final volume, and these are meant to be
felt more than heard.

usage: python3 -I make_sounds.py
"""

import math
import pathlib
import random
import struct
import wave

RATE = 44100
OUT = pathlib.Path(__file__).resolve().parents[2] / "leanring-buddy/VoiceOut/Sounds"


def envelope(index, total, attack, release):
    """Linear attack, exponential-looking release, both in samples."""
    if index < attack:
        return index / attack
    remaining = total - index
    return min(1.0, remaining / release) ** 2 if remaining < release else 1.0


def tone(seconds, frequency_at, decay, attack=0.003, release=0.02, harmonic=0.0):
    """A sine whose pitch follows frequency_at(t), fading exponentially."""
    total = int(seconds * RATE)
    phase = 0.0
    samples = []
    for index in range(total):
        t = index / RATE
        phase += 2 * math.pi * frequency_at(t) / RATE
        value = math.sin(phase) + harmonic * math.sin(2 * phase)
        value *= math.exp(-t / decay) * envelope(index, total, attack * RATE, release * RATE)
        samples.append(value)
    return samples


def mix(*layers):
    length = max(len(samples) for offset, samples in layers) + max(offset for offset, _ in layers)
    out = [0.0] * length
    for offset, samples in layers:
        for index, value in enumerate(samples):
            out[offset + index] += value
    return out


def write(name, samples, peak=0.5):
    loudest = max(abs(value) for value in samples) or 1
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(b"".join(
            struct.pack("<h", int(value / loudest * peak * 32767)) for value in samples))
    print(f"{name}.wav  {len(samples) / RATE * 1000:.0f} ms")


# A water drop: a bubble's pitch rises as it closes, so the "bloop" is a fast
# upward sweep, with a smaller, later bubble for the second plip.
def rising(start, end, over):
    return lambda t: start + (end - start) * min(1.0, t / over) ** 0.6


drop = mix(
    (0, tone(0.14, rising(520, 1500, 0.05), decay=0.035, attack=0.002)),
    (int(0.045 * RATE), [0.35 * v for v in tone(0.09, rising(900, 2100, 0.035), decay=0.022, attack=0.002)]),
)
write("sound-drop", drop, peak=0.55)

# Listening: a soft rising pair of notes, the "go ahead" of a walkie-talkie
# without its harshness. Sent: the same idea falling, quieter.
listen = mix(
    (0, tone(0.09, lambda t: 660, decay=0.05, harmonic=0.15)),
    (int(0.055 * RATE), tone(0.12, lambda t: 990, decay=0.06, harmonic=0.15)),
)
write("sound-listen", listen, peak=0.45)

sent = mix(
    (0, tone(0.08, lambda t: 880, decay=0.045, harmonic=0.1)),
    (int(0.05 * RATE), tone(0.11, lambda t: 587, decay=0.055, harmonic=0.1)),
)
write("sound-sent", sent, peak=0.38)

# A tick for copy and follow-ups: tiny and high, like a light switch far away.
write("sound-tick", tone(0.035, lambda t: 2400, decay=0.008, attack=0.0008, release=0.01), peak=0.35)

# Clearing the drawing: a short breath of filtered noise whose brightness
# falls, like a cloth wiping a whiteboard.
random.seed(7)
total = int(0.16 * RATE)
wipe, smoothed = [], 0.0
for index in range(total):
    t = index / RATE
    cutoff = 0.25 * math.exp(-t / 0.06) + 0.02
    smoothed += cutoff * (random.uniform(-1, 1) - smoothed)
    wipe.append(smoothed * envelope(index, total, 0.02 * RATE, 0.08 * RATE))
write("sound-wipe", wipe, peak=0.3)

# Something failed: two low, rounded notes, falling a minor third. Noticeable,
# not alarming.
error = mix(
    (0, tone(0.12, lambda t: 392, decay=0.08, harmonic=0.3)),
    (int(0.09 * RATE), tone(0.18, lambda t: 330, decay=0.1, harmonic=0.3)),
)
write("sound-error", error, peak=0.42)

# Typing: three quick, slightly uneven key taps, for the chat box opening on
# Control + Option + T. Taps of noise with no note in them, so typing is told
# apart from talking (the rising pair) by ear, not only by what appears.
taps = random.Random(11)


def tap(brightness, seconds=0.028):
    total = int(seconds * RATE)
    samples, smoothed = [], 0.0
    for index in range(total):
        t = index / RATE
        smoothed += brightness * (taps.uniform(-1, 1) - smoothed)
        samples.append(smoothed * math.exp(-t / 0.006) * envelope(index, total, 0.0008 * RATE, 0.01 * RATE))
    return samples


typing = mix(
    (0, tap(0.35)),
    (int(0.06 * RATE), [0.8 * v for v in tap(0.45)]),
    (int(0.105 * RATE), [0.65 * v for v in tap(0.3)]),
)
write("sound-type", typing, peak=0.42)
