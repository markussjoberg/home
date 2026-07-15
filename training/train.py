"""Treenaus: AdamW + warmup/cosine, bf16 autocast (MPS/CUDA), val-split.

Käyttö M4 Maxilla:
    python train.py --data data/prepared --out ckpt --layers 4 --dim 256
Hienosäätö (esim. valssit + omat nauhat):
    python train.py --data data/valssit --out ckpt2 --init ckpt/best.pt --lr 3e-5
"""

from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

import numpy as np
import torch

from features import COND_DIM
from model import ModelCfg, PosetiiviLM
from tokenizer import VOCAB_SIZE


def pick_device() -> str:
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


class Data:
    def __init__(self, path: Path, seq_len: int, val_frac: float = 0.02):
        z = np.load(path / "dataset.npz")
        self.tokens = torch.from_numpy(z["tokens"].astype(np.int64))
        self.conds = torch.from_numpy(
            z["conds"].astype(np.float32)[z["bars"]]
        )  # per-token cond
        self.seq_len = seq_len
        n_val = max(int(len(self.tokens) * val_frac), seq_len + 1)
        self.val_start = len(self.tokens) - n_val

    def batch(self, bs: int, split: str, device: str):
        lo, hi = (0, self.val_start) if split == "train" else (
            self.val_start, len(self.tokens))
        ix = torch.randint(lo, hi - self.seq_len - 1, (bs,))
        x = torch.stack([self.tokens[i : i + self.seq_len] for i in ix])
        y = torch.stack([self.tokens[i + 1 : i + self.seq_len + 1] for i in ix])
        c = torch.stack([self.conds[i : i + self.seq_len] for i in ix])
        return x.to(device), y.to(device), c.to(device)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--init", type=Path, help="jatka/hienosäädä checkpointista")
    ap.add_argument("--layers", type=int, default=4)
    ap.add_argument("--dim", type=int, default=256)
    ap.add_argument("--heads", type=int, default=4)
    ap.add_argument("--seq-len", type=int, default=1024)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--steps", type=int, default=20000)
    ap.add_argument("--lr", type=float, default=6e-4)
    ap.add_argument("--no-amp", action="store_true")
    args = ap.parse_args()

    device = pick_device()
    data = Data(args.data, args.seq_len)
    cfg = ModelCfg(vocab_size=VOCAB_SIZE, cond_dim=COND_DIM,
                   n_layer=args.layers, n_head=args.heads, dim=args.dim,
                   max_seq=args.seq_len)
    model = PosetiiviLM(cfg).to(device)
    if args.init:
        model.load_state_dict(torch.load(args.init, map_location=device)["model"])
    print(f"device={device} params={model.num_params()/1e6:.1f}M "
          f"tokens={len(data.tokens)/1e6:.1f}M")

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr,
                            betas=(0.9, 0.95), weight_decay=0.1)
    warmup = max(args.steps // 10, 1)

    def lr_at(step: int) -> float:
        if step < warmup:
            return args.lr * step / warmup
        t = (step - warmup) / max(args.steps - warmup, 1)
        return 1e-5 + 0.5 * (args.lr - 1e-5) * (1 + math.cos(math.pi * t))

    amp = (not args.no_amp) and device in ("cuda", "mps")
    autocast = torch.autocast(device_type=device, dtype=torch.bfloat16,
                              enabled=amp)
    args.out.mkdir(parents=True, exist_ok=True)
    best_val, t0 = float("inf"), time.time()

    model.train()
    for step in range(1, args.steps + 1):
        for g in opt.param_groups:
            g["lr"] = lr_at(step)
        x, y, c = data.batch(args.batch, "train", device)
        with autocast:
            _, loss = model(x, c, y)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()

        if step % 250 == 0 or step == args.steps:
            model.eval()
            with torch.no_grad(), autocast:
                vx, vy, vc = data.batch(args.batch, "val", device)
                _, vloss = model(vx, vc, vy)
            model.train()
            tok_s = step * args.batch * args.seq_len / (time.time() - t0)
            print(f"step {step:6d}  train {loss.item():.3f}  "
                  f"val {vloss.item():.3f}  lr {lr_at(step):.1e}  {tok_s/1e3:.0f}k tok/s")
            if vloss.item() < best_val:
                best_val = vloss.item()
                torch.save({"model": model.state_dict(), "cfg": vars(cfg)},
                           args.out / "best.pt")
    torch.save({"model": model.state_dict(), "cfg": vars(cfg)},
               args.out / "last.pt")
    (args.out / "train_meta.json").write_text(json.dumps(
        {"best_val": best_val, "steps": args.steps, "args": vars(args)},
        default=str, indent=2))
    print(f"valmis: paras val {best_val:.3f} -> {args.out}/best.pt")


if __name__ == "__main__":
    main()
