"""Analyyttinen labelointi: per-tahti ehdollistusvektori.

cond = [genre-jakauma (len(GENRES))] + [valence, energia, density, rekisteri]

Genre tulee metadatasta (prepare_data.py --genre-map), muut lasketaan
suoraan nuoteista — ei labeleita, ei LLM:ää, deterministinen.
"""

from __future__ import annotations

import math

from tokenizer import NoteEv

GENRES = ["valssi", "masurkka", "polska", "menuetti",
          "polkka", "jenkka", "humppa", "marssi", "ragtime", "tango"]
COND_DIM = len(GENRES) + 4

# Krumhansl-Kessler-profiilit sävellajin ja moodin tunnistukseen.
KK_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
KK_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]


def _corr(x: list[float], y: list[float]) -> float:
    mx, my = sum(x) / 12, sum(y) / 12
    num = sum((a - mx) * (b - my) for a, b in zip(x, y))
    den = math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))
    return num / den if den else 0.0


def key_mode(notes: list[NoteEv]) -> tuple[int, bool, float]:
    """(sävellaji 0-11, molli?, varmuus). Painotus nuottien kestoilla."""
    hist = [0.0] * 12
    for n in notes:
        hist[n.pitch % 12] += n.dur
    if not any(hist):
        return 0, False, 0.0
    best = (0, False, -2.0)
    for root in range(12):
        rot = hist[root:] + hist[:root]
        for minor, prof in ((False, KK_MAJOR), (True, KK_MINOR)):
            c = _corr(rot, prof)
            if c > best[2]:
                best = (root, minor, c)
    return best


def bar_conds(notes: list[NoteEv], beats_per_bar: int,
              genre_probs: list[float], bpm: float) -> list[list[float]]:
    """Ehdollistusvektori jokaiselle tahdille (0 .. max bar)."""
    n_bars = max((n.bar for n in notes), default=0) + 1
    _, minor, conf = key_mode(notes)
    # Valence: duuri korkealle, molli matalalle; epävarma sävellaji keskelle.
    valence = 0.5 + (0.35 if not minor else -0.35) * max(conf, 0.0)

    by_bar: list[list[NoteEv]] = [[] for _ in range(n_bars)]
    for n in notes:
        by_bar[n.bar].append(n)

    conds = []
    for bar_notes in by_bar:
        mel = [n for n in bar_notes if n.channel == 0] or bar_notes
        density = min(len(mel) / (beats_per_bar * 2.5), 1.0)
        register = 0.0
        if mel:
            register = min(max((sum(n.pitch for n in mel) / len(mel) - 48) / 36, 0.0), 1.0)
        energy = min(max((bpm - 50) / 130, 0.0), 1.0) * 0.6 + density * 0.4
        conds.append(list(genre_probs) + [valence, energy, density, register])
    return conds


def smooth_genre(genre: str, eps: float = 0.15) -> list[float]:
    """Kova metadata-label -> pehmennetty jakauma (vaihe 1)."""
    probs = [eps / (len(GENRES) - 1)] * len(GENRES)
    probs[GENRES.index(genre)] = 1.0 - eps
    return probs
