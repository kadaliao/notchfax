#!/usr/bin/env python3
"""宣传片配乐：毛毡钢琴 + 暖垫 + 轻拨弦，全部合成，不用任何素材。
D 大调，80 BPM，一小节 3 秒，和镜头切换对齐。→ out/music.wav（48 kHz 立体声）"""
import numpy as np
from scipy.signal import fftconvolve, butter, sosfilt
from scipy.io import wavfile

SR = 48000
BEAT = 0.75
BAR = 3.0
LENGTH = 75.0
FINAL = 62.25  # 图标出现的那一下
N = int(LENGTH * SR)
rng = np.random.default_rng(7)

NOTES = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}


def hz(name):
    pitch, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((NOTES[pitch] + 12 * (octave + 1) - 69) / 12)


class Bus:
    def __init__(self):
        self.l = np.zeros(N)
        self.r = np.zeros(N)

    def add(self, sig, t, pan=0.0, gain=1.0):
        i = int(t * SR)
        if i >= N or i < 0:
            return
        sig = sig[: N - i]
        a = (pan + 1) * np.pi / 4
        self.l[i : i + len(sig)] += sig * np.cos(a) * gain
        self.r[i : i + len(sig)] += sig * np.sin(a) * gain


def piano(f, vel=0.6, ring=4.5):
    """毛毡钢琴：谐波很快衰减，略带失谐的双弦，音头是一小团闷住的噪声。"""
    n = int(ring * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    tau0 = min(3.2, 2.4 * (261.6 / f) ** 0.55)
    for k in range(1, 11):
        fk = k * f * np.sqrt(1 + 0.00035 * k * k)
        if fk > 7000:
            break
        amp = k ** -(2.1 - 0.7 * vel)
        tau = tau0 / (1 + 0.42 * (k - 1))
        for cents in (-1.3, 1.1):
            decay = 0.62 * np.exp(-t / (tau * 0.16)) + 0.38 * np.exp(-t / tau)
            out += amp * 0.5 * np.sin(2 * np.pi * fk * 2 ** (cents / 1200) * t + rng.uniform(0, 6.28)) * decay
    attack = np.minimum(1, t / 0.004)
    thump = rng.standard_normal(n) * np.exp(-t / 0.012)
    thump = sosfilt(butter(2, 900, "low", fs=SR, output="sos"), thump)
    out = out * attack + thump * 0.4 * vel
    out *= np.minimum(1, (ring - t) / 0.4)
    return out * vel


def pad(f, dur, bright=0.5):
    n = int((dur + 3.0) * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for cents in (-7, 0, 6):
        for k, amp in ((1, 1.0), (2, 0.35 * bright + 0.1), (3, 0.16 * bright), (4, 0.07 * bright)):
            out += amp * np.sin(2 * np.pi * f * k * 2 ** (cents / 1200) * t + rng.uniform(0, 6.28))
    env = np.minimum(1, t / 1.6) * np.minimum(1, np.maximum(0, (dur + 3.0 - t) / 3.0))
    return out * env * (1 + 0.08 * np.sin(2 * np.pi * 0.23 * t)) / 4


def bass(f, dur):
    n = int((dur + 0.6) * SR)
    t = np.arange(n) / SR
    env = np.minimum(1, t / 0.05) * np.minimum(1, np.maximum(0, (dur + 0.6 - t) / 0.6)) * (0.6 + 0.4 * np.exp(-t / 1.2))
    return (np.sin(2 * np.pi * f * t) + 0.22 * np.sin(4 * np.pi * f * t)) * env


def pluck(f, vel=0.5):
    n = int(0.9 * SR)
    t = np.arange(n) / SR
    s = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) * np.exp(-t / 0.05) + 0.12 * np.sin(6 * np.pi * f * t) * np.exp(-t / 0.03)
    return s * np.exp(-t / 0.16) * np.minimum(1, t / 0.003) * vel


def kick():
    n = int(0.4 * SR)
    t = np.arange(n) / SR
    f = 42 + 70 * np.exp(-t / 0.035)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.13)


def shaker(vel=1.0):
    n = int(0.09 * SR)
    t = np.arange(n) / SR
    s = sosfilt(butter(2, 6000, "high", fs=SR, output="sos"), rng.standard_normal(n))
    return s * np.exp(-t / 0.018) * np.minimum(1, t / 0.004) * vel


def swell(dur):
    n = int(dur * SR)
    t = np.arange(n) / SR
    s = sosfilt(butter(2, [400, 5000], "band", fs=SR, output="sos"), rng.standard_normal(n))
    return s * (t / dur) ** 3 * np.minimum(1, (dur - t) / 0.08)


# 和声：每小节 (低音, 垫, 琶音)
CHORDS = {
    "D": ("D2", ["D3", "A3", "F#4", "E4"], ["D3", "A3", "E4", "F#4", "A4", "F#4", "E4", "A3"]),
    "Bm": ("B1", ["B2", "F#3", "D4", "A4"], ["B2", "F#3", "D4", "F#4", "A4", "F#4", "D4", "F#3"]),
    "G": ("G1", ["G2", "D3", "B3", "F#4"], ["G2", "D3", "B3", "D4", "F#4", "D4", "B3", "D3"]),
    "A": ("A1", ["A2", "E3", "C#4", "E4"], ["A2", "E3", "B3", "C#4", "E4", "C#4", "B3", "E3"]),
    "D/F#": ("F#2", ["F#2", "D3", "A3", "E4"], ["F#2", "D3", "A3", "D4", "E4", "D4", "A3", "D3"]),
    "Em": ("E2", ["E2", "B2", "G3", "D4"], ["E2", "B2", "G3", "B3", "D4", "B3", "G3", "B2"]),
}
# 旋律：一轮四小节，(拍, 音)
MELODY = [
    [(0, "F#5"), (2, "E5"), (3, "D5")],
    [(0, "D5"), (3, "B4")],
    [(0, "B4"), (2, "D5")],
    [(0, "E5"), (3, "C#5")],
]
MELODY_B = [
    [(0, "A5"), (2, "F#5"), (3, "E5")],
    [(0, "F#5"), (3, "D5")],
    [(0, "D5"), (1.5, "E5"), (2, "G5")],
    [(0, "E5"), (2, "C#5"), (3, "E5")],
]

#        1    2    3    4    5    6     7    8    9    10    11   12   13    14   15      16
PROG = ["D", "D", "G", "A", "D", "Bm", "G", "A", "D", "Bm", "G", "A", "Bm", "G", "D/F#", "A",
        # 17  18   19   20   21   22   23   24   25
        "Em", "G", "A", "D", "G", "D", "D", "D", "D"]

dry, wet = Bus(), Bus()
for i, name in enumerate(PROG):
    bar = i + 1
    t0 = i * BAR
    root, voicing, arp = CHORDS[name]
    intro = bar <= 2
    opening = bar in (3, 4)
    memories = 5 <= bar <= 8
    booth = 9 <= bar <= 11
    fax = 12 <= bar <= 16
    cli = 17 <= bar <= 19
    finale = bar >= 20
    last = bar >= 22
    # 力度的起伏：开场轻，回忆起来，传真收住，结尾最满
    dyn = 0.8 if opening else 1.0
    if booth or cli:
        dyn = 1.08
    if fax:
        dyn = 0.8 if bar <= 14 else 0.95
    if finale:
        dyn = 1.22

    # 垫
    level = 0.20 if intro else 0.16
    if finale:
        level = 0.22
    for j, note in enumerate(voicing):
        wet.add(pad(hz(note), BAR, bright=0.3 if (intro or fax) else 0.6), t0, pan=(-0.6, 0.5, -0.3, 0.6)[j], gain=level)

    # 低音
    if bar >= 5 and not last:
        dry.add(bass(hz(root), BAR * 0.95), t0, gain=0.34 if not fax else 0.26)
    if bar == 22:
        dry.add(bass(hz("D2"), 8.0), FINAL, gain=0.34)

    # 钢琴
    if intro:
        wet.add(piano(hz(("A5", "F#5")[bar - 1]), 0.32), t0 + 0.75, pan=0.2, gain=0.8)
    elif last:
        if bar == 22:
            for j, note in enumerate(["D3", "A3", "D4", "F#4", "A4", "D5"]):
                wet.add(piano(hz(note), 0.6, ring=8), FINAL + j * 0.045, pan=-0.4 + j * 0.16, gain=0.9)
            wet.add(piano(hz("F#5"), 0.42, ring=8), FINAL + 1.5, pan=0.3, gain=0.8)
            wet.add(piano(hz("A5"), 0.34, ring=8), FINAL + 3.0, pan=0.3, gain=0.8)
            wet.add(piano(hz("D6"), 0.28, ring=8), FINAL + 4.6, pan=0.3, gain=0.8)
    else:
        vel = 0.34 if opening else (0.36 if fax else 0.46)
        vel = min(0.62, vel * dyn)
        steps = arp if not (opening or (fax and bar <= 13)) else arp[:1] + [None, arp[2], None, arp[4], None, arp[2], None]
        for s, note in enumerate(steps):
            if note is None or (bar == 21 and s >= 6):
                continue
            human = rng.uniform(-0.012, 0.016)
            accent = 1.18 if s % 4 == 0 else (0.74 + 0.2 * rng.random())
            wet.add(piano(hz(note), vel * accent), t0 + s * BEAT / 2 + human, pan=-0.35 + 0.1 * (s % 4), gain=0.62)
        # 旋律
        if bar >= 5:
            phrase = (MELODY_B if (booth or finale) else MELODY)[(bar - 5) % 4]
            for beat, note in phrase:
                if bar == 21 and beat >= 3:
                    continue
                wet.add(piano(hz(note), min(0.66, 0.5 * dyn * rng.uniform(0.9, 1.08))), t0 + beat * BEAT + rng.uniform(0.004, 0.022), pan=0.28, gain=0.95)

    # 拨弦与节奏：大头贴、命令行两段更轻快
    if booth or cli or (finale and not last):
        tones = [n for n in voicing[1:]]
        for s in range(8):
            note = tones[(s * 2 + (s // 3)) % len(tones)]
            f = hz(note) * 2
            g = 0.085 if not finale else 0.06
            dry.add(pluck(f, 0.9), t0 + s * BEAT / 2, pan=0.5 if s % 2 else -0.5, gain=g)
            wet.add(pluck(f, 0.9), t0 + s * BEAT / 2 + BEAT * 0.75, pan=-0.5 if s % 2 else 0.5, gain=g * 0.5)
        if not finale:
            for beat in (0, 2):
                dry.add(kick(), t0 + beat * BEAT, gain=0.30)
            for s in range(8):
                if s % 2 == 1:
                    dry.add(shaker(0.6 + 0.4 * rng.random()), t0 + s * BEAT / 2, pan=0.3, gain=0.035)

# 段落前的气息
for at, dur, gain in ((12.0, 2.0, 0.05), (24.0, 1.5, 0.04), (49.5, 1.5, 0.04), (57.0, 2.5, 0.07)):
    wet.add(swell(dur), at - dur, gain=gain)

# 混响
ir_n = int(2.6 * SR)
tt = np.arange(ir_n) / SR
lp = butter(2, 4200, "low", fs=SR, output="sos")
ir_l = sosfilt(lp, rng.standard_normal(ir_n)) * np.exp(-tt / 0.55) * np.minimum(1, tt / 0.012)
ir_r = sosfilt(lp, rng.standard_normal(ir_n)) * np.exp(-tt / 0.55) * np.minimum(1, tt / 0.012)
ir_l /= np.sqrt(np.sum(ir_l**2))
ir_r /= np.sqrt(np.sum(ir_r**2))
rev_l = fftconvolve(wet.l, ir_l)[:N]
rev_r = fftconvolve(wet.r, ir_r)[:N]
L = dry.l + wet.l * 0.85 + rev_l * 0.42
R = dry.r + wet.r * 0.85 + rev_r * 0.42

# 收尾：淡入一点，结尾长淡出，轻微软削
t = np.arange(N) / SR
env = np.minimum(1, t / 1.5) * np.clip((LENGTH - 0.3 - t) / 5.0, 0, 1)
mix = np.stack([L, R], axis=1) * env[:, None]
mix = sosfilt(butter(2, 28, "high", fs=SR, output="sos"), mix, axis=0)
mix /= np.max(np.abs(mix)) / 0.98
mix = np.tanh(mix * 1.25) / np.tanh(1.25) * 0.89
wavfile.write("out/music.wav", SR, (mix * 32767).astype(np.int16))
rms = 20 * np.log10(np.sqrt(np.mean(mix**2)))
print("out/music.wav  peak %.2f  rms %.1f dB" % (np.max(np.abs(mix)), rms))
