"""Generointi genre-vivuilla + classifier-free guidance.

    python generate.py --ckpt ckpt/best.pt \
        --genre "valssi=0.6,tango=0.4" --energy 0.7 --valence 0.3 \
        --bars 32 --guidance 2.0 --out demo.mid

--guidance > 1 terävöittää vipujen vaikutusta (CFG: ehdollinen vs. ehdoton).
"""

from __future__ import annotations

import argparse
from pathlib import Path

import torch

from features import COND_DIM, GENRES
from model import KVCache, ModelCfg, PosetiiviLM
from tokenizer import GRID, NOTE_HI, NOTE_LO, TOK, VOCAB_SIZE, decode

# Skaalamaski: pakota generointi mihin tahansa asteikkoon (vrt. Ian Ringin
# A Study of Scales -katalogi — mikä tahansa sävelluokkajoukko käy tähän).
# Malli fraseeraa kuten on oppinut, mutta sävelvaranto vaihtuu.
SCALES = {
    "major": [0, 2, 4, 5, 7, 9, 11],
    "minor": [0, 2, 3, 5, 7, 8, 10],
    "harmonic_minor": [0, 2, 3, 5, 7, 8, 11],
    "dorian": [0, 2, 3, 5, 7, 9, 10],
    "mixolydian": [0, 2, 4, 5, 7, 9, 10],
    "freygish": [0, 1, 4, 5, 7, 8, 10],  # klezmer/ahava rabbah
    "hicaz": [0, 1, 4, 5, 7, 8, 10],  # = freygish-perhe, turkkilainen nimi
    "nikriz": [0, 2, 3, 6, 7, 9, 10],  # turkkilainen, "mustalaismolli"-sukua
    "hungarian_minor": [0, 2, 3, 6, 7, 8, 11],
    "pentatonic": [0, 2, 4, 7, 9],
    "pentatonic_minor": [0, 3, 5, 7, 10],  # itäaasialainen väri
    "whole_tone": [0, 2, 4, 6, 8, 10],
}


def scale_mask(scale: str, key: int, device) -> torch.Tensor | None:
    """Bool-maski kielletyille NOTE-tokeneille, tai None jos ei rajata."""
    if not scale:
        return None
    pcs = {(key + x) % 12 for x in SCALES[scale]}
    banned = [TOK[f"NOTE_{p}"] for p in range(NOTE_LO, NOTE_HI + 1)
              if p % 12 not in pcs]
    mask = torch.zeros(VOCAB_SIZE, dtype=torch.bool, device=device)
    mask[banned] = True
    return mask


def parse_genre(spec: str) -> list[float]:
    probs = [0.0] * len(GENRES)
    for part in spec.split(","):
        name, _, w = part.partition("=")
        probs[GENRES.index(name.strip())] = float(w or 1.0)
    total = sum(probs) or 1.0
    return [p / total for p in probs]


def fit_cond(cond: list[float], model) -> list[float]:
    """Sovita ehdollistusvektori mallin cond_dimiin (vanha ckpt: 14, uusi 16)."""
    cd = model.cfg.cond_dim
    return cond[:cd] + [0.0] * (cd - len(cond))


def is_loop(prev: list[tuple], sig: tuple) -> bool:
    """Kolmas identtinen tahti peräkkäin tai ABAB kolmatta kierrosta."""
    if len(prev) >= 2 and sig == prev[-1] == prev[-2]:
        return True
    return len(prev) >= 3 and sig == prev[-2] and prev[-1] == prev[-3]


@torch.no_grad()
def sample(model, cond_base, beats, max_bars, temperature, top_k, guidance, device,
           rng=None, banned_notes=None):
    """Generoi biisejä peräkkäin ("biisi, jonka jälkeen toinen").

    - EOS ei lopeta vaan aloittaa uuden sävelmän tuoreella kontekstilla.
    - Looppivahti: identtisen tahdin kolmas toisto (tai ABAB-jumi) hylätään
      ja tahti generoidaan uudelleen kuumemmalla lämpötilalla.
    - Fraasipositio ja biisin etenemä syötetään ehdollistukseen (mallit
      jotka on treenattu niitä näkemään; vanhalle ckpt:lle nollataan pois).
    """
    import random as _random
    rng = rng or _random
    t = TOK
    meter_tok = t[f"METER_{beats}"]
    prefix = [t["BOS"], meter_tok, t["BAR"]]
    seq: list[int] = list(prefix)
    bars_total, bar_in_tune = 0, 0
    tune_len = rng.randint(16, 32)
    prev_bars: list[tuple] = []
    cur: list[int] = []
    attempts = 0

    # KV-cache: rivit [ehdollinen, ehdoton] samassa batchissa -> CFG:n
    # molemmat haarat yhdellä forwardilla, ja jokainen token maksaa vain
    # itsensä (ilman cachea koko konteksti laskettiin uudelleen per token).
    nrow = 2 if guidance != 1.0 else 1
    cache = KVCache(model.cfg, nrow, device=device)
    TAIL = 256  # edellisen biisin häntä uuden kontekstiin (settisiirtymät)

    def cond_t(vec: list[float], length: int) -> torch.Tensor:
        c = torch.tensor(vec, device=device).view(1, 1, -1)
        c = c.expand(nrow, length, -1).clone()
        if nrow == 2:
            c[1] = 0.0  # ehdoton rivi
        return c

    def run(tokens: list[int], vec: list[float]) -> torch.Tensor:
        x = torch.tensor([tokens], device=device).expand(nrow, -1)
        logits, _ = model(x, cond_t(vec, len(tokens)), cache=cache)
        return logits[:, -1]

    def prime(ctx: list[int], vec: list[float]) -> torch.Tensor:
        cache.rewind(0)
        return run(ctx, vec)

    cond_vec = fit_cond(
        list(cond_base)
        + [(bar_in_tune % 8) / 8.0, min(bar_in_tune / max(tune_len - 1, 1), 1.0)],
        model,
    )
    last = prime(seq, cond_vec)  # invariantti: cache kattaa seq:n,
    while bars_total < max_bars and len(seq) < 16384:  # `last` ennustaa seuraavan
        cond_vec = fit_cond(
            list(cond_base)
            + [(bar_in_tune % 8) / 8.0, min(bar_in_tune / max(tune_len - 1, 1), 1.0)],
            model,
        )
        logits = last[:1]
        if nrow == 2:
            logits = last[1:2] + guidance * (last[:1] - last[1:2])
        logits = logits / (temperature * 1.25**attempts)
        logits[:, t["PAD"]] = -float("inf")
        if banned_notes is not None:
            # Pehmeä maski: vahva painotus asteikkoon, mutta ei muuri —
            # kova -inf ajaa mallin ulos jakaumastaan (tyhjiä tahteja).
            logits[:, banned_notes] -= 6.0
        if top_k:
            kth = torch.topk(logits, top_k).values[:, -1, None]
            logits[logits < kth] = -float("inf")
        nxt = int(torch.multinomial(torch.softmax(logits, -1), 1))
        if nxt == t["EOS"]:
            # Biisi päättyi: uusi sävelmä, kontekstiin edellisen häntä.
            seq.append(t["EOS"])
            ctx = seq[-TAIL:] + prefix
            seq += prefix
            bar_in_tune, prev_bars, cur, attempts = 0, [], [], 0
            tune_len = rng.randint(16, 32)
            last = prime(ctx, cond_vec)
            continue
        if nxt == t["BAR"]:
            sig = tuple(cur)
            if attempts < 3 and cur and is_loop(prev_bars, sig):
                del seq[len(seq) - len(cur):]  # hylkää tahti, yritä kuumemmin
                cur = []
                attempts += 1
                cache.rewind(len(seq) - 1)
                last = run([seq[-1]], cond_vec)
                continue
            prev_bars.append(sig)
            cur, attempts = [], 0
            bars_total += 1
            bar_in_tune += 1
        else:
            cur.append(nxt)
        seq.append(nxt)
        if cache.len + 1 >= cache.max_len:  # hätävara: ikkuna täynnä
            last = prime(seq[-TAIL:], cond_vec)
        else:
            last = run([nxt], cond_vec)
    return seq


def write_midi(tokens: list[int], out: Path, bpm: float) -> None:
    from symusic import Note, Score, Tempo, TimeSignature, Track

    notes, beats = decode(tokens)
    tpq = 480
    step = tpq // GRID
    score = Score()
    score.ticks_per_quarter = tpq
    score.tempos.append(Tempo(0, bpm))
    score.time_signatures.append(TimeSignature(0, beats, 4))
    mel, acc = Track(program=21), Track(program=21)
    for n in notes:
        start = (n.bar * beats * GRID + n.pos) * step
        track = mel if n.channel == 0 else acc
        track.notes.append(Note(start, n.dur * step, n.pitch, n.velocity))
    score.tracks.extend([mel, acc])
    score.dump_midi(str(out))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True, type=Path)
    ap.add_argument("--genre", default="valssi", help='esim. "valssi=0.6,tango=0.4"')
    ap.add_argument("--valence", type=float, default=0.6)
    ap.add_argument("--energy", type=float, default=0.6)
    ap.add_argument("--density", type=float, default=0.5)
    ap.add_argument("--register", type=float, default=0.6)
    ap.add_argument("--beats", type=int, default=3, choices=(2, 3, 4))
    ap.add_argument("--bars", type=int, default=32)
    ap.add_argument("--bpm", type=float, default=120.0)
    ap.add_argument("--temperature", type=float, default=0.95)
    ap.add_argument("--top-k", type=int, default=24)
    ap.add_argument("--guidance", type=float, default=2.0)
    ap.add_argument("--scale", default="", choices=[""] + sorted(SCALES),
                    help="pakota asteikkoon, esim. freygish")
    ap.add_argument("--key", type=int, default=0, help="skaalan perussävel 0-11")
    ap.add_argument("--out", type=Path, default=Path("demo.mid"))
    args = ap.parse_args()

    ckpt = torch.load(args.ckpt, map_location="cpu")
    model = PosetiiviLM(ModelCfg(**ckpt["cfg"]))
    model.load_state_dict(ckpt["model"])
    model.eval()

    cond = parse_genre(args.genre) + [args.valence, args.energy,
                                      args.density, args.register]
    tokens = sample(model, cond, args.beats, args.bars, args.temperature,
                    args.top_k, args.guidance, "cpu",
                    banned_notes=scale_mask(args.scale, args.key, "cpu"))
    write_midi(tokens, args.out, args.bpm)
    print(f"{args.out}: {len(tokens)} tokenia, genre={args.genre}")


if __name__ == "__main__":
    main()
