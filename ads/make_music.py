"""Generate an original, royalty-free 120 BPM ad track (with whooshes on scene cuts).

Usage: python3 make_music.py out.wav [seconds] [cut,cut,...]
"""
import sys
import wave

import numpy as np

SR = 44100
BPM = 120
BEAT = 60 / BPM

out = sys.argv[1]
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
CUTS = [float(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 else [2.5, 5, 9, 13, 16.5]

n = int(SR * DUR)
L = np.zeros(n)
R = np.zeros(n)
rng = np.random.default_rng(7)


def add(sig, t, gain=1.0, pan=0.0):
    i = int(t * SR)
    if i >= n:
        return
    sig = sig[: n - i]
    L[i:i + len(sig)] += sig * gain * (1 - max(0, pan))
    R[i:i + len(sig)] += sig * gain * (1 + min(0, pan))


def env(length, attack=0.002, decay=0.2):
    t = np.arange(int(length * SR)) / SR
    a = np.clip(t / attack, 0, 1)
    return a * np.exp(-t / decay)


def kick():
    t = np.arange(int(0.35 * SR)) / SR
    f = 45 + 110 * np.exp(-t * 28)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t * 9) * 1.0


def clap():
    t = np.arange(int(0.22 * SR)) / SR
    nz = rng.standard_normal(len(t))
    nz = np.diff(np.concatenate([[0], nz]))  # brighter
    e = np.exp(-t * 22) + 0.6 * np.exp(-((t - 0.012) % 0.011) * 300) * (t < 0.035)
    return nz * e * 0.35


def hat(open_=False):
    t = np.arange(int((0.18 if open_ else 0.05) * SR)) / SR
    nz = np.diff(np.concatenate([[0], rng.standard_normal(len(t))]))
    return nz * np.exp(-t * (18 if open_ else 70)) * 0.18


def tone(freq, length, decay, harmonics=(1, .5, .25), detune=0.0):
    t = np.arange(int(length * SR)) / SR
    s = sum(a * np.sin(2 * np.pi * freq * (k + 1) * t * (1 + detune)) for k, a in enumerate(harmonics))
    return s * env(length, 0.004, decay)


def whoosh(length=0.45, up=True):
    t = np.arange(int(length * SR)) / SR
    nz = rng.standard_normal(len(t))
    # moving one-pole low-pass gives a sweep
    cutoff = np.linspace(0.02, 0.35, len(t)) if up else np.linspace(0.35, 0.02, len(t))
    y = np.zeros_like(nz)
    acc = 0.0
    for i in range(len(nz)):
        acc += cutoff[i] * (nz[i] - acc)
        y[i] = acc
    shape = np.sin(np.pi * np.clip(t / length, 0, 1)) ** 2
    return y * shape * 0.9


# chord progression (one bar = 4 beats): C  G  Am  F
NOTE = {"C": 261.63, "D": 293.66, "E": 329.63, "F": 349.23, "G": 392.00, "A": 440.00, "B": 493.88}
CHORDS = [("C", ["C", "E", "G"]), ("G", ["G", "B", "D"]), ("A", ["A", "C", "E"]), ("F", ["F", "A", "C"])]
BASS = {"C": 65.41, "G": 49.00, "A": 55.00, "F": 43.65}

beats = int(DUR / BEAT)
for b in range(beats):
    t = b * BEAT
    bar = b // 4
    root, triad = CHORDS[bar % 4]
    intro = t < 2.5  # lighter first scene
    add(kick(), t, 0.9)
    if b % 4 in (1, 3) and not intro:
        add(clap(), t, 1.0)
    add(hat(), t + BEAT / 2, 1.0, pan=0.3)
    if not intro:
        add(hat(), t + BEAT / 4, 0.5, pan=-0.3)
    # bass on 8ths (octave bounce)
    for k, mult in enumerate((1, 2)):
        add(tone(BASS[root] * mult, BEAT / 2, 0.12, (1, .6, .3, .15)), t + k * BEAT / 2, 0.55)
    # offbeat chord stabs
    stab = sum(tone(NOTE[nn] * (0.5 if nn in "AB" and root != "A" else 1), 0.3, 0.09, (1, .3), detune=0.002) for nn in triad)
    add(stab, t + BEAT / 2, 0.16, pan=-0.2)
    add(stab, t + BEAT / 2 + 0.012, 0.12, pan=0.25)

# simple pluck melody on the last part (call-to-action energy)
melody = ["E", "G", "A", "G", "E", "D", "C", "D"]
for i, m in enumerate(melody * 4):
    t = 16.5 + i * BEAT / 2
    if t < DUR - 0.25:
        add(tone(NOTE[m] * 2, 0.25, 0.08, (1, .2)), t, 0.12, pan=0.15)

for c in CUTS:
    add(whoosh(0.4, True), max(0, c - 0.35), 0.5)
add(whoosh(1.0, True), CUTS[-1] - 1.0, 0.35)  # riser into the call to action

mix = np.stack([L, R], axis=1)
# soft clip + master fade in/out
mix = np.tanh(mix * 1.2)
fade = np.ones(n)
fi, fo = int(0.03 * SR), int(0.6 * SR)
fade[:fi] = np.linspace(0, 1, fi)
fade[-fo:] = np.linspace(1, 0, fo)
mix *= fade[:, None]
mix = mix / np.max(np.abs(mix)) * 0.89
pcm = (mix * 32767).astype(np.int16)
with wave.open(out, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print("wrote", out, DUR, "s")
