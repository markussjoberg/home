"""MIDI-hakemisto -> tokenoidut shardit + per-tahti ehdollistukset.

Käyttö:
    python prepare_data.py --midi-dir data/midi --genre-map data/genres.csv \
        --out data/prepared

genres.csv: rivit "polunosa,genre" — ensimmäinen osuma tiedostopolkuun
voittaa (esim. "folkwiki/vals,valssi" tai "lakh/tango,tango").
ABC-korpukset muunnetaan ensin MIDIksi: abc2midi tune.abc -o tune.mid
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from symusic import Score

from features import GENRES, bar_conds, smooth_genre
from tokenizer import GRID, METERS, NoteEv, bar_ids, encode

MIN_BARS, MAX_BARS = 8, 256


def load_notes(path: Path) -> tuple[list[NoteEv], int, float] | None:
    """MIDI -> (nuotit, iskua/tahti, bpm). None jos ei kelpaa."""
    try:
        score = Score(str(path))
    except Exception:
        return None
    return _extract(score)


def _extract(score) -> tuple[list[NoteEv], int, float] | None:
    tpq = score.ticks_per_quarter
    step = tpq / GRID  # tikkejä per 1/16
    ts = score.time_signatures
    num, den = (ts[0].numerator, ts[0].denominator) if ts else (4, 4)
    beats = num * 4 // den if den in (4, 8) else num
    if beats not in METERS:
        return None
    bar_ticks = beats * tpq
    bpm = score.tempos[0].qpm if score.tempos else 120.0

    # Karkea kanavajako: korkein raita melodiaksi, loput säestykseksi.
    tracks = [t for t in score.tracks if not t.is_drum and len(t.notes)]
    if not tracks:
        return None
    mel_track = max(tracks, key=lambda t: sum(n.pitch for n in t.notes) / len(t.notes))

    notes: list[NoteEv] = []
    for track in tracks:
        ch = 0 if track is mel_track else 1
        for n in track.notes:
            bar, off = divmod(n.time, bar_ticks)
            notes.append(NoteEv(
                bar=int(bar),
                pos=int(round(off / step)),
                channel=ch,
                pitch=n.pitch,
                dur=max(int(round(n.duration / step)), 1),
                velocity=n.velocity,
            ))
    n_bars = max((n.bar for n in notes), default=0) + 1
    if not MIN_BARS <= n_bars <= MAX_BARS:
        return None
    return notes, beats, bpm


def auto_accompany(notes: list[NoteEv], beats: int) -> list[NoteEv]:
    """Lisää basso + soinnut melodiadataan (esim. The Session on yksiäänistä).

    Tahdin sointu = parhaiten tahdin sävelhistogrammiin sopiva duuri/molli-
    kolmisointu. Ilman tätä malli ei koskaan näe CH_ACC-kanavaa eikä opi
    säestämään.
    """
    if any(n.channel == 1 for n in notes):
        return notes  # säestys on jo
    n_bars = max(n.bar for n in notes) + 1
    hist = [[0.0] * 12 for _ in range(n_bars)]
    for n in notes:
        hist[n.bar][n.pitch % 12] += n.dur
    prev_root = None
    out = list(notes)
    for bar in range(n_bars):
        h = hist[bar]
        if not any(h):
            continue
        best, best_score = (0, False), -1.0
        for root in range(12):
            for minor in (False, True):
                triad = (root, (root + (3 if minor else 4)) % 12, (root + 7) % 12)
                score = sum(h[pc] for pc in triad) + (0.5 if root == prev_root else 0)
                if score > best_score:
                    best, best_score = (root, minor), score
        root, minor = best
        prev_root = root
        bass = 36 + root if root >= 5 else 48 + root  # A2-tienoo
        triad = [48 + root + iv for iv in (0, 3 if minor else 4, 7)]
        out.append(NoteEv(bar, 0, 1, bass, GRID - 1, 88))
        for beat in range(1, beats):
            for p in triad:
                out.append(NoteEv(bar, beat * GRID, 1, p, GRID - 1, 64))
    return out


def genre_for(path: Path, mapping: list[tuple[str, str]]) -> str | None:
    s = str(path).lower()
    for pattern, genre in mapping:
        if pattern in s:
            return genre
    return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--midi-dir", required=True, type=Path)
    ap.add_argument("--genre-map", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--no-auto-accomp", action="store_true",
                    help="älä lisää bassoa+sointuja yksiäänisiin tiedostoihin")
    args = ap.parse_args()

    mapping = [(r[0].lower(), r[1].strip()) for r in csv.reader(args.genre_map.open())
               if len(r) >= 2 and r[1].strip() in GENRES]
    args.out.mkdir(parents=True, exist_ok=True)

    all_tokens, all_bars, all_conds, skipped = [], [], [], 0
    cond_offset = 0
    files = sorted(args.midi_dir.rglob("*.mid")) + sorted(args.midi_dir.rglob("*.midi"))
    for path in files:
        genre = genre_for(path, mapping)
        loaded = load_notes(path) if genre else None
        if not loaded:
            skipped += 1
            continue
        notes, beats, bpm = loaded
        if not args.no_auto_accomp:
            notes = auto_accompany(notes, beats)
        tokens = encode(notes, beats)
        conds = bar_conds(notes, beats, smooth_genre(genre), bpm)
        bars = [b + cond_offset for b in bar_ids(tokens)]
        all_tokens.append(np.array(tokens, dtype=np.int16))
        all_bars.append(np.array(bars, dtype=np.int64))
        all_conds.append(np.array(conds, dtype=np.float16))
        cond_offset += len(conds)

    if not all_tokens:
        raise SystemExit("Yhtään kelvollista MIDIä ei löytynyt — tarkista genre-map.")
    np.savez_compressed(
        args.out / "dataset.npz",
        tokens=np.concatenate(all_tokens),
        bars=np.concatenate(all_bars),
        conds=np.concatenate(all_conds),
        doc_ends=np.cumsum([len(t) for t in all_tokens]),
    )
    stats = {
        "files_ok": len(all_tokens), "files_skipped": skipped,
        "tokens": int(sum(len(t) for t in all_tokens)),
        "bars": int(cond_offset), "genres": GENRES,
    }
    (args.out / "stats.json").write_text(json.dumps(stats, indent=2))
    print(stats)


if __name__ == "__main__":
    main()
