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
from model import ModelCfg, PosetiiviLM
from tokenizer import GRID, TOK, VOCAB_SIZE, decode


def parse_genre(spec: str) -> list[float]:
    probs = [0.0] * len(GENRES)
    for part in spec.split(","):
        name, _, w = part.partition("=")
        probs[GENRES.index(name.strip())] = float(w or 1.0)
    total = sum(probs) or 1.0
    return [p / total for p in probs]


@torch.no_grad()
def sample(model, cond_vec, beats, max_bars, temperature, top_k, guidance, device):
    meter_tok = TOK[f"METER_{beats}"]
    seq = torch.tensor([[TOK["BOS"], meter_tok, TOK["BAR"]]], device=device)
    cond = torch.tensor(cond_vec, device=device).view(1, 1, -1)
    zero = torch.zeros_like(cond)
    bars = 0
    while bars < max_bars and seq.shape[1] < 4096:
        window = seq[:, -1024:]
        c = cond.expand(1, window.shape[1], -1)
        logits, _ = model(window, c)
        logits = logits[:, -1]
        if guidance != 1.0:
            uncond_logits, _ = model(window, zero.expand_as(c))
            logits = uncond_logits[:, -1] + guidance * (logits - uncond_logits[:, -1])
        logits = logits / temperature
        logits[:, TOK["PAD"]] = -float("inf")
        if top_k:
            kth = torch.topk(logits, top_k).values[:, -1, None]
            logits[logits < kth] = -float("inf")
        nxt = torch.multinomial(torch.softmax(logits, -1), 1)
        if nxt.item() == TOK["EOS"]:
            break
        if nxt.item() == TOK["BAR"]:
            bars += 1
        seq = torch.cat([seq, nxt], dim=1)
    return seq[0].tolist()


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
    ap.add_argument("--out", type=Path, default=Path("demo.mid"))
    args = ap.parse_args()

    ckpt = torch.load(args.ckpt, map_location="cpu")
    model = PosetiiviLM(ModelCfg(**ckpt["cfg"]))
    model.load_state_dict(ckpt["model"])
    model.eval()

    cond = parse_genre(args.genre) + [args.valence, args.energy,
                                      args.density, args.register]
    assert len(cond) == COND_DIM
    tokens = sample(model, cond, args.beats, args.bars, args.temperature,
                    args.top_k, args.guidance, "cpu")
    write_midi(tokens, args.out, args.bpm)
    print(f"{args.out}: {len(tokens)} tokenia, genre={args.genre}")


if __name__ == "__main__":
    main()
