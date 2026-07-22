"""Ydinkorrektiuden minimitestit (V5 M1). Aja: .venv/bin/pytest -q"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "training"))
sys.path.insert(0, str(ROOT))

import torch  # noqa: E402

from tokenizer import NoteEv, encode, decode, VOCAB_SIZE  # noqa: E402
from model import ModelCfg, PosetiiviLM, KVCache  # noqa: E402
from features import COND_DIM  # noqa: E402
import generate as g  # noqa: E402


def test_tokenizer_roundtrip():
    """encode -> decode palauttaa nuotit (velocity binataan, ei tarkisteta)."""
    notes = [
        NoteEv(bar=0, pos=0, channel=0, pitch=60, dur=4, velocity=88),
        NoteEv(bar=0, pos=4, channel=0, pitch=64, dur=2, velocity=64),
        NoteEv(bar=1, pos=0, channel=1, pitch=48, dur=8, velocity=100),
    ]
    toks = encode(notes, 3)
    dec, beats = decode(toks)
    assert beats == 3
    got = {(n.bar, n.pos, n.channel, n.pitch, n.dur) for n in dec}
    want = {(n.bar, n.pos, n.channel, n.pitch, n.dur) for n in notes}
    assert got == want


def test_kvcache_equivalence():
    """Inkrementaalinen cache-dekoodaus == täysi forward (KV-cachen ydin)."""
    torch.manual_seed(0)
    cfg = ModelCfg(vocab_size=VOCAB_SIZE, cond_dim=COND_DIM, n_layer=2,
                   n_head=2, dim=64, max_seq=64)
    model = PosetiiviLM(cfg).eval()
    T = 20
    x = torch.randint(1, VOCAB_SIZE, (1, T))
    c = torch.randn(1, T, COND_DIM)
    with torch.no_grad():
        full, _ = model(x, c)
        cache = KVCache(cfg, 1)
        inc = torch.stack(
            [model(x[:, i:i + 1], c[:, i:i + 1], cache=cache)[0][:, -1]
             for i in range(T)],
            dim=1,
        )
    assert torch.allclose(full, inc, atol=1e-4)


def _note(pos, pitch, dur, vel):
    from tokenizer import TOK
    return (TOK[f"POS_{pos}"], TOK["CH_MEL"], TOK[f"NOTE_{pitch}"],
            TOK[f"DUR_{dur}"], TOK[f"VEL_{vel}"])


def test_is_loop_neighbor_rejection():
    """Looppivahti hylkää >80 % samanlaisen naapuritahdin — ja DUR/VEL
    -erot eivät pelasta (vertailu vain POS+NOTE-sisältöön)."""
    barA = _note(0, 60, 4, 2) + _note(4, 64, 2, 3)
    barA2 = _note(0, 60, 8, 1) + _note(4, 64, 4, 4)   # sama melodia, eri DUR/VEL
    barB = _note(0, 67, 4, 2) + _note(8, 72, 2, 3)    # eri sävelet
    assert g.is_loop([barA], barA)      # identtinen
    assert g.is_loop([barA], barA2)     # DUR/VEL-erot eivät pelasta
    assert not g.is_loop([barA], barB)  # riittävän erilainen


def test_is_loop_abab():
    """Vanhat jumit yhä kiinni: kolme identtistä ja ABAB."""
    a = _note(0, 60, 4, 2) + _note(4, 62, 2, 3)
    b = _note(0, 67, 4, 2) + _note(8, 71, 2, 3)
    assert g.is_loop([a, a], a)        # kolme peräkkäin
    assert g.is_loop([a, b, a], b)     # ABAB


def test_waltz_composer_returns_beats():
    """Säveltäjärajapinta: next_bar -> (nuotit, iskua/tahti)."""
    from posetiivi.midigen import LiveParams, WaltzComposer
    notes, beats = WaltzComposer(LiveParams()).next_bar(0.5)
    assert beats == 3
    assert isinstance(notes, list) and notes


def test_clean_midi_meter_filter():
    """Vain 2/4, 3/4, 4/4 hyväksytään; 6/8 hylätään."""
    from clean_midi import _beats_per_bar
    assert _beats_per_bar(3, 4) == 3
    assert _beats_per_bar(2, 4) == 2
    assert _beats_per_bar(4, 4) == 4
    assert _beats_per_bar(6, 8) is None      # ei tuettu (tarantella-velka)
    assert _beats_per_bar(7, 8) is None
