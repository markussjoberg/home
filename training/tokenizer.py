"""REMI-tyylinen tokenisointi posetiivi-LLM:lle.

Nuotti = POS CH NOTE DUR VEL (5 tokenia). Gridi on 1/16-osa, tahdissa
enintään 16 positiota (4/4). Ehdollistus EI ole tokeneita — se kulkee
rinnalla per-tahti float-vektorina (ks. prepare_data.py).
"""

from __future__ import annotations

from dataclasses import dataclass

GRID = 4  # 1/16-osia per isku
MAX_DUR = 24  # 1/16-osina
NOTE_LO, NOTE_HI = 21, 108
VEL_BINS = (48, 72, 96, 128)  # ylärajat -> VEL_1..4
VEL_CENTERS = (40, 64, 88, 110)

METERS = {2: "METER_2", 3: "METER_3", 4: "METER_4"}


def _build_vocab() -> list[str]:
    vocab = ["PAD", "BOS", "EOS", "BAR", "METER_2", "METER_3", "METER_4",
             "CH_MEL", "CH_ACC"]
    vocab += [f"POS_{i}" for i in range(16)]
    vocab += [f"NOTE_{p}" for p in range(NOTE_LO, NOTE_HI + 1)]
    vocab += [f"DUR_{d}" for d in range(1, MAX_DUR + 1)]
    vocab += [f"VEL_{v}" for v in range(1, len(VEL_BINS) + 1)]
    return vocab


VOCAB = _build_vocab()
TOK = {name: i for i, name in enumerate(VOCAB)}
VOCAB_SIZE = len(VOCAB)


@dataclass
class NoteEv:
    bar: int
    pos: int  # 1/16-osina tahdin alusta
    channel: int  # 0 = melodia, 1 = säestys
    pitch: int
    dur: int  # 1/16-osina, >= 1
    velocity: int


def vel_bin(v: int) -> int:
    for i, hi in enumerate(VEL_BINS, start=1):
        if v < hi:
            return i
    return len(VEL_BINS)


def encode(notes: list[NoteEv], beats_per_bar: int) -> list[int]:
    """Nuottilista (järjestetty) -> token-idit. Palauttaa myös BAR-rajat
    implisiittisesti: bar_ids saa laskettua BAR-tokenien kohdista."""
    out = [TOK["BOS"], TOK[METERS[beats_per_bar]]]
    bar = -1
    for n in sorted(notes, key=lambda n: (n.bar, n.pos, n.channel, n.pitch)):
        while bar < n.bar:
            out.append(TOK["BAR"])
            bar += 1
        out += [
            TOK[f"POS_{min(n.pos, 15)}"],
            TOK["CH_MEL"] if n.channel == 0 else TOK["CH_ACC"],
            TOK[f"NOTE_{min(max(n.pitch, NOTE_LO), NOTE_HI)}"],
            TOK[f"DUR_{min(max(n.dur, 1), MAX_DUR)}"],
            TOK[f"VEL_{vel_bin(n.velocity)}"],
        ]
    out.append(TOK["EOS"])
    return out


def bar_ids(tokens: list[int]) -> list[int]:
    """Jokaiselle tokenille tahti-indeksi (BAR-tokenia edeltävät = -1 -> 0)."""
    ids, bar = [], 0
    for t in tokens:
        if t == TOK["BAR"]:
            bar += 1
        ids.append(max(bar - 1, 0))
    return ids


def decode(tokens: list[int]) -> tuple[list[NoteEv], int]:
    """Token-idit -> nuotit + iskua/tahti. Sietää keskeneräisiä sekvenssejä."""
    names = [VOCAB[t] for t in tokens if 0 <= t < VOCAB_SIZE]
    beats = 3
    notes: list[NoteEv] = []
    bar = -1
    i = 0
    while i < len(names):
        n = names[i]
        if n.startswith("METER_"):
            beats = int(n.split("_")[1])
        elif n == "BAR":
            bar += 1
        elif n.startswith("POS_") and i + 4 < len(names):
            pos, ch, note, dur, vel = names[i : i + 5]
            if (ch.startswith("CH_") and note.startswith("NOTE_")
                    and dur.startswith("DUR_") and vel.startswith("VEL_")):
                notes.append(NoteEv(
                    bar=max(bar, 0),
                    pos=int(pos.split("_")[1]),
                    channel=0 if ch == "CH_MEL" else 1,
                    pitch=int(note.split("_")[1]),
                    dur=int(dur.split("_")[1]),
                    velocity=VEL_CENTERS[int(vel.split("_")[1]) - 1],
                ))
                i += 5
                continue
        i += 1
    return notes, beats
