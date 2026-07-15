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


def rope(q, k):
    """Rotary-positiot q:lle ja k:lle. Muoto (B, H, T, Dh)."""
    dh = q.shape[-1]
    t = torch.arange(q.shape[-2], device=q.device, dtype=torch.float32)
    freqs = 1.0 / (10000 ** (torch.arange(0, dh, 2, device=q.device).float() / dh))
    ang = torch.outer(t, freqs)
    cos, sin = ang.cos()[None, None], ang.sin()[None, None]

    def rot(x):
        x1, x2 = x[..., 0::2], x[..., 1::2]
        return torch.stack((x1 * cos - x2 * sin, x1 * sin + x2 * cos), -1).flatten(-2)

    return rot(q.float()).type_as(q), rot(k.float()).type_as(k)


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

    def forward(self, x):
        b, t, d = x.shape
        q, k, v = self.qkv(self.norm1(x)).chunk(3, dim=-1)
        q = q.view(b, t, self.n_head, -1).transpose(1, 2)
        k = k.view(b, t, self.n_head, -1).transpose(1, 2)
        v = v.view(b, t, self.n_head, -1).transpose(1, 2)
        q, k = rope(q, k)
        y = F.scaled_dot_product_attention(q, k, v, is_causal=True)
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

    def forward(self, tokens, cond, targets=None):
        """tokens (B,T) int; cond (B,T,cond_dim) float; targets (B,T) tai None."""
        x = self.emb(tokens)
        if self.training and self.cfg.cond_dropout > 0:
            keep = (torch.rand(tokens.shape[0], 1, 1, device=tokens.device)
                    > self.cfg.cond_dropout)
            cond = cond * keep
        scale, shift = self.cond_film(cond).chunk(2, dim=-1)
        x = x * (1 + scale) + shift
        for block in self.blocks:
            x = block(x)
        logits = self.head(self.norm(x))
        if targets is None:
            return logits, None
        loss = F.cross_entropy(
            logits.view(-1, logits.size(-1)), targets.reshape(-1), ignore_index=0
        )
        return logits, loss

    def num_params(self) -> int:
        return sum(p.numel() for p in self.parameters())
