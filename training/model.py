"""Pieni dekooderi-transformer jatkuvalla ehdollistuksella.

2026-pikkumalliresepti: RMSNorm (pre-norm), RoPE, SwiGLU, ei biaseja,
sidotut embeddingit. Ehdollistus: per-token cond-vektori -> FiLM
(scale + shift) embeddingeihin. Condition dropout treenissä mahdollistaa
classifier-free guidancen ja vipujen terävöityksen inferenssissä.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import torch
import torch.nn as nn
import torch.nn.functional as F


@dataclass
class ModelCfg:
    vocab_size: int
    cond_dim: int
    n_layer: int = 4
    n_head: int = 4
    dim: int = 256
    max_seq: int = 1024
    cond_dropout: float = 0.15


class RMSNorm(nn.Module):
    def __init__(self, dim: int):
        super().__init__()
        self.w = nn.Parameter(torch.ones(dim))

    def forward(self, x):
        return self.w * x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + 1e-6)


def rope(q, k, pos0: int = 0):
    """Rotary-positiot q:lle ja k:lle. Muoto (B, H, T, Dh).

    pos0 = ensimmäisen tokenin absoluuttinen positio (KV-cachea varten).
    """
    dh = q.shape[-1]
    t = torch.arange(pos0, pos0 + q.shape[-2], device=q.device,
                     dtype=torch.float32)
    freqs = 1.0 / (10000 ** (torch.arange(0, dh, 2, device=q.device).float() / dh))
    ang = torch.outer(t, freqs)
    cos, sin = ang.cos()[None, None], ang.sin()[None, None]

    def rot(x):
        x1, x2 = x[..., 0::2], x[..., 1::2]
        return torch.stack((x1 * cos - x2 * sin, x1 * sin + x2 * cos), -1).flatten(-2)

    return rot(q.float()).type_as(q), rot(k.float()).type_as(k)


class KVCache:
    """Esiallokoitu K/V-välimuisti inkrementaaliseen dekoodaukseen.

    Ilman cachea joka uusi token maksaa koko kontekstin uudelleenlaskennan
    (O(n²) per biisi) — Pi:llä mahdotonta, Macillakin minuutteja per demo.
    Cachen kanssa token maksaa vain itsensä. `rewind` tukee looppivahdin
    tahtihylkäyksiä: pituus palautetaan, puskuria ei tarvitse siivota.
    """

    def __init__(self, cfg: "ModelCfg", batch: int, device="cpu",
                 max_len: int | None = None):
        dh = cfg.dim // cfg.n_head
        self.max_len = max_len or cfg.max_seq
        self.buf = torch.zeros(
            cfg.n_layer, 2, batch, cfg.n_head, self.max_len, dh, device=device
        )
        self.len = 0

    def extend(self, layer: int, k: torch.Tensor, v: torch.Tensor):
        """Kirjoita kerroksen uudet k/v puskuriin; palauta koko historia."""
        t = k.shape[2]
        self.buf[layer, 0, :, :, self.len:self.len + t] = k
        self.buf[layer, 1, :, :, self.len:self.len + t] = v
        return (self.buf[layer, 0, :, :, :self.len + t],
                self.buf[layer, 1, :, :, :self.len + t])

    def advance(self, t: int) -> None:
        self.len += t

    def rewind(self, n: int) -> None:
        self.len = n


class Block(nn.Module):
    def __init__(self, cfg: ModelCfg):
        super().__init__()
        self.n_head = cfg.n_head
        self.norm1 = RMSNorm(cfg.dim)
        self.qkv = nn.Linear(cfg.dim, 3 * cfg.dim, bias=False)
        self.proj = nn.Linear(cfg.dim, cfg.dim, bias=False)
        self.norm2 = RMSNorm(cfg.dim)
        hidden = int(cfg.dim * 8 / 3 / 64) * 64 or cfg.dim * 2
        self.w1 = nn.Linear(cfg.dim, hidden, bias=False)  # SwiGLU
        self.w2 = nn.Linear(cfg.dim, hidden, bias=False)
        self.w3 = nn.Linear(hidden, cfg.dim, bias=False)

    def forward(self, x, cache: "KVCache | None" = None, layer: int = 0):
        b, t, d = x.shape
        q, k, v = self.qkv(self.norm1(x)).chunk(3, dim=-1)
        q = q.view(b, t, self.n_head, -1).transpose(1, 2)
        k = k.view(b, t, self.n_head, -1).transpose(1, 2)
        v = v.view(b, t, self.n_head, -1).transpose(1, 2)
        q, k = rope(q, k, pos0=cache.len if cache is not None else 0)
        if cache is not None:
            # Monitokenisyöttö vain tyhjään cacheen (prime); jatko token
            # kerrallaan — SDPA:n is_causal ei tue epäsymmetristä maskia.
            assert t == 1 or cache.len == 0
            k, v = cache.extend(layer, k, v)
        y = F.scaled_dot_product_attention(q, k, v, is_causal=(t > 1))
        x = x + self.proj(y.transpose(1, 2).reshape(b, t, d))
        h = self.norm2(x)
        return x + self.w3(F.silu(self.w1(h)) * self.w2(h))


class PosetiiviLM(nn.Module):
    def __init__(self, cfg: ModelCfg):
        super().__init__()
        self.cfg = cfg
        self.emb = nn.Embedding(cfg.vocab_size, cfg.dim)
        self.cond_film = nn.Sequential(
            nn.Linear(cfg.cond_dim, cfg.dim, bias=False),
            nn.SiLU(),
            nn.Linear(cfg.dim, 2 * cfg.dim, bias=False),
        )
        self.blocks = nn.ModuleList(Block(cfg) for _ in range(cfg.n_layer))
        self.norm = RMSNorm(cfg.dim)
        self.head = nn.Linear(cfg.dim, cfg.vocab_size, bias=False)
        self.head.weight = self.emb.weight  # sidotut embeddingit
        self.apply(self._init)

    @staticmethod
    def _init(m):
        if isinstance(m, (nn.Linear, nn.Embedding)):
            nn.init.normal_(m.weight, std=0.02)

    def forward(self, tokens, cond, targets=None, cache: KVCache | None = None):
        """tokens (B,T) int; cond (B,T,cond_dim) float; targets (B,T) tai None.

        cache: KV-välimuisti inkrementaaliseen dekoodaukseen — täytetään
        paikallaan (prime koko sekvenssillä, jatko token kerrallaan).
        """
        x = self.emb(tokens)
        if self.training and self.cfg.cond_dropout > 0:
            keep = (torch.rand(tokens.shape[0], 1, 1, device=tokens.device)
                    > self.cfg.cond_dropout)
            cond = cond * keep
        scale, shift = self.cond_film(cond).chunk(2, dim=-1)
        x = x * (1 + scale) + shift
        for i, block in enumerate(self.blocks):
            x = block(x, cache=cache, layer=i)
        if cache is not None:
            cache.advance(tokens.shape[1])
        logits = self.head(self.norm(x))
        if targets is None:
            return logits, None
        loss = F.cross_entropy(
            logits.view(-1, logits.size(-1)), targets.reshape(-1), ignore_index=0
        )
        return logits, loss

    def num_params(self) -> int:
        return sum(p.numel() for p in self.parameters())
