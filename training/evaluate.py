"""Rakennemittarit: generoitu vs. aito data. (V5 M1 -työkalu.)

    python evaluate.py --ckpt models/valssi/best.pt --genre valssi \
        --data data/prepared_valssi --n 16

Mittarit (docs/V5.md portit):
- lag8: fraasitoisto — muistuttaako tahti 8 tahdin takaista (aito ~0.47)
- lag1: naapuritahtitoisto — peräkkäiset lähes identtiset tahdit (aito ~1-2 %)
- ab:   A/B-kontrasti — peräkkäisten 8 tahdin fraasien erilaisuus
- len:  sävelmäpituus (tahtia)
- empty: tyhjien tahtien osuus generoinnissa (romahdusvahti)

Portti (V5): lag8 ±0.10 aidosta, lag1 < 5 %, empty < 1 %.
"""

from __future__ import annotations

import argparse
import random
from pathlib import Path

import numpy as np
import torch

from model import ModelCfg, PosetiiviLM
from tokenizer import TOK, VOCAB
import generate as g

BAR, EOS = TOK["BAR"], TOK["EOS"]


def bars_from_tokens(toks):
    """Tahdit melodian (pos,pitch)-joukkoina; tyhjät mukana erikseen."""
    names = [VOCAB[t] if 0 <= t < len(VOCAB) else "?" for t in toks]
    bars, cur = [], set()
    i = 0
    while i < len(toks):
        if toks[i] == BAR:
            bars.append(frozenset(cur))
            cur = set()
        elif names[i].startswith("POS_") and i + 4 < len(toks):
            p, c, note, dur, vel = names[i:i + 5]
            if c == "CH_MEL" and note.startswith("NOTE_"):
                cur.add((int(p.split("_")[1]), int(note.split("_")[1])))
                i += 5
                continue
        i += 1
    bars.append(frozenset(cur))
    return bars


def jac(a, b):
    if not a and not b:
        return 1.0
    return len(a & b) / max(len(a | b), 1)


def metrics(all_bars, thr=0.5):
    """Mittarit yhdelle sävelmälle (tahtilista, tyhjät mukana)."""
    bars = [b for b in all_bars if b]
    n = len(bars)
    if n < 12:
        return None
    empty = 1.0 - n / max(len(all_bars), 1)
    lag8 = float(np.mean([jac(bars[i], bars[i - 8]) > thr
                          for i in range(8, n)]))
    lag1 = float(np.mean([jac(bars[i], bars[i - 1]) > 0.8
                          for i in range(1, n)]))
    phr = [bars[i:i + 8] for i in range(0, n - n % 8, 8)]
    ab = None
    if len(phr) >= 2:
        sims = []
        for a, b in zip(phr, phr[1:]):
            m = min(len(a), len(b))
            sims.append(1 - np.mean([jac(a[k], b[k]) for k in range(m)]))
        ab = float(np.mean(sims))
    return {"lag8": lag8, "lag1": lag1, "ab": ab, "len": n, "empty": empty}


def eval_real(prepared: Path, limit: int = 400):
    z = np.load(prepared / "dataset.npz")
    tokens, doc_ends = z["tokens"], z["doc_ends"]
    out, start = [], 0
    for end in doc_ends[:limit]:
        m = metrics(bars_from_tokens(tokens[start:end].tolist()))
        start = end
        if m:
            out.append(m)
    return out


def eval_generated(ckpt: Path, genre: str, n: int, beats: int,
                   guidance: float = 2.0):
    d = torch.load(ckpt, map_location="cpu")
    model = PosetiiviLM(ModelCfg(**d["cfg"]))
    model.load_state_dict(d["model"])
    model.eval()
    cond = g.parse_genre(f"{genre}=1.0") + [0.6, 0.6, 0.5, 0.6]
    out = []
    for seed in range(n):
        rng = random.Random(seed)
        torch.manual_seed(seed)
        toks = g.sample(model, cond, beats, 120, 0.95, 24, guidance, "cpu",
                        rng=rng)
        first = toks[:toks.index(EOS)] if EOS in toks else toks
        m = metrics(bars_from_tokens(first))
        if m:
            out.append(m)
    return out


def summarize(name, stats):
    def agg(key):
        vals = [s[key] for s in stats if s[key] is not None]
        return (np.mean(vals), np.std(vals)) if vals else (float("nan"), 0)
    l8, l8s = agg("lag8")
    l1, _ = agg("lag1")
    ab, _ = agg("ab")
    ln, lns = agg("len")
    em, _ = agg("empty")
    print(f"{name:20s} lag8 {l8:.2f}±{l8s:.2f}  lag1 {100*l1:4.1f}%  "
          f"ab {ab:.2f}  len {ln:4.0f}±{lns:.0f}  tyhjiä {100*em:4.1f}%  "
          f"(n={len(stats)})")
    return {"lag8": l8, "lag1": l1, "ab": ab, "len": ln, "empty": em}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True, type=Path)
    ap.add_argument("--genre", required=True)
    ap.add_argument("--data", required=True, type=Path,
                    help="prepared-hakemisto aidon vertailun pohjaksi")
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--beats", type=int, default=None)
    ap.add_argument("--guidance", type=float, default=2.0)
    args = ap.parse_args()

    beats = args.beats
    if beats is None:
        from features import GENRE_METER
        beats = GENRE_METER.get(args.genre, 3)

    real = summarize("aito", eval_real(args.data))
    gen = summarize(f"gen ({args.ckpt})",
                    eval_generated(args.ckpt, args.genre, args.n, beats,
                                   args.guidance))

    # Portit suhteessa aitoon (absoluuttiset kynnykset olivat harhaanjohtavia:
    # esim. aito masurkka on itse 3.2 % tyhjää -> <1 % oli mahdoton).
    ok_lag8 = abs(gen["lag8"] - real["lag8"]) <= 0.10
    ok_lag1 = gen["lag1"] <= max(real["lag1"] + 0.03, 0.05)   # ~aito + marginaali
    ok_empty = gen["empty"] <= real["empty"] + 0.02
    verdict = "LÄPI" if (ok_lag8 and ok_lag1 and ok_empty) else "EI LÄPI"
    print(f"Portti: lag8 {'ok' if ok_lag8 else 'EI'} | "
          f"lag1 {'ok' if ok_lag1 else 'EI'}(aito {100*real['lag1']:.0f}%) | "
          f"tyhjät {'ok' if ok_empty else 'EI'}(aito {100*real['empty']:.0f}%)"
          f"  -> {verdict}")


if __name__ == "__main__":
    main()
