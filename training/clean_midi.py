"""Siivoa sotkuinen (moniraita) MIDI posetiiviputkeen sopivaksi.

Ottaa mielivaltaisia MIDIä (tango-arkistot, Lakh, MetaMIDI ym.), poimii
melodiaraidan, suodattaa tahtilajin ja pituuden, kvantisoi 1/16-gridiin
ja kirjoittaa yksiäänisen melodia-MIDIn. prepare_data lisää säestyksen
(--no-auto-accomp jos ei haluta).

    python clean_midi.py --in data/tango_raw --out data/tango_clean \
        --genre tango

Tuloksena data/tango_clean/tango/*.mid + genres.csv — sama muoto kuin
fetch_thesession.py tuottaa, eli suoraan prepare_data.py:lle.

Melodianpoiminta on heuristiikka (ei täydellinen): valitse ei-rumpuraita
joka on korkein ja yksiäänisin, sitten "skyline"-monofonisointi (ylin
sävel kullakin hetkellä). Sotkuisimmat sovitukset menevät väärin — siksi
kesto- ja tahtilajisuodatus + prepare_datan jälkitarkistus.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

# Tuetut tahtilajit (sama kuin tokenizer/prepare_data): 2/4, 3/4, 4/4.
SUPPORTED_METERS = {2, 3, 4}
GRID = 4  # 1/16-osia per neljäsosa


def _beats_per_bar(num: int, den: int) -> int | None:
    """Vain aidot yksinkertaiset tahtilajit 2/4, 3/4, 4/4. Yhdistelmä- ja
    parittomat (6/8, 9/8, 2/2 ...) HYLÄTÄÄN — ei mankeloida 3/4:ksi, koska
    se saastuttaisi treenidatan väärämetrisillä sävelmillä. clean_midi on
    tarkoituksella tiukempi kuin prepare_data (se nielee sotkuista dataa)."""
    if den == 4 and num in SUPPORTED_METERS:
        return num
    return None


def _monophonicity(notes) -> float:
    """Osuus nuoteista joilla ei ole päällekkäisyyttä edellisen kanssa."""
    if len(notes) < 2:
        return 1.0
    ns = sorted(notes, key=lambda n: n.time)
    overlaps = 0
    for prev, cur in zip(ns, ns[1:]):
        if cur.time < prev.time + prev.duration:
            overlaps += 1
    return 1.0 - overlaps / len(ns)


def _pick_melody_track(score):
    """Valitse todennäköisin melodiaraita (ei-rumpu, korkea, yksiääninen)."""
    best, best_score = None, -1e9
    for t in score.tracks:
        if getattr(t, "is_drum", False) or len(t.notes) < 8:
            continue
        mean_pitch = sum(n.pitch for n in t.notes) / len(t.notes)
        mono = _monophonicity(t.notes)
        norm_pitch = max(0.0, min((mean_pitch - 40) / 40, 1.0))
        s = 0.6 * norm_pitch + 0.4 * mono
        if s > best_score:
            best, best_score = t, s
    return best


def _skyline(notes):
    """Monofonisoi: pidä kullakin alkuhetkellä vain ylin sävel; typistä
    kesto seuraavan sävelen alkuun (ei päällekkäisyyttä)."""
    if not notes:
        return []
    ns = sorted(notes, key=lambda n: (n.time, -n.pitch))
    top = []
    for n in ns:
        if top and n.time == top[-1].time:
            continue  # sama alkuhetki -> ylin jo otettu
        top.append(n)
    for cur, nxt in zip(top, top[1:]):
        if cur.time + cur.duration > nxt.time:
            cur = cur  # kesto typistetään alla kirjoitusvaiheessa
    return top


def clean_one(path: Path, out: Path) -> str | None:
    """Palauta 'ok' / syy hylkäykselle (str). Kirjoittaa out:iin jos ok."""
    import symusic

    try:
        score = symusic.Score(str(path))
    except Exception as e:  # rikkinäinen MIDI
        return f"lukuvirhe:{type(e).__name__}"
    if not score.time_signatures:
        beats = 4  # oletus jos ei merkitty
    else:
        ts = score.time_signatures[0]
        beats = _beats_per_bar(ts.numerator, ts.denominator)
        if beats is None:
            return f"tahtilaji:{ts.numerator}/{ts.denominator}"

    mel = _pick_melody_track(score)
    if mel is None:
        return "ei-melodiaraitaa"
    top = _skyline(mel.notes)
    if len(top) < 16:
        return f"liian-vähän-nuotteja:{len(top)}"

    tpq = score.ticks_per_quarter or 480
    step = max(tpq // GRID, 1)          # 1/16-osan pituus tikeissä
    bar_ticks = beats * tpq

    # Kvantisoi 1/16-gridiin ja typistä kestot seuraavaan säveleen.
    q = []
    for n in top:
        start = round(n.time / step) * step
        dur = max(round(n.duration / step) * step, step)
        q.append((start, dur, n.pitch, n.velocity))
    q.sort()
    for i in range(len(q) - 1):
        s, d, p, v = q[i]
        d = min(d, q[i + 1][0] - s) or step
        q[i] = (s, max(d, step), p, v)

    total_ticks = q[-1][0] + q[-1][1]
    n_bars = total_ticks / bar_ticks
    if not (8 <= n_bars <= 256):
        return f"kesto:{n_bars:.0f}tahtia"

    from symusic import Note, Score, Tempo, TimeSignature, Track

    bpm = score.tempos[0].qpm if score.tempos else 120.0
    new = Score()
    new.ticks_per_quarter = tpq
    new.tempos.append(Tempo(0, bpm))
    new.time_signatures.append(TimeSignature(0, beats, 4))
    tr = Track(program=0)
    for s, d, p, v in q:
        tr.notes.append(Note(s, d, int(p), int(v) or 80))
    new.tracks.append(tr)
    out.parent.mkdir(parents=True, exist_ok=True)
    new.dump_midi(str(out))
    return "ok"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--genre", required=True, help="genrelabel siivotulle datalle")
    ap.add_argument("--limit", type=int, default=0, help="0 = kaikki")
    args = ap.parse_args()

    dst = args.out / args.genre
    files = sorted(p for p in args.inp.rglob("*")
                   if p.suffix.lower() in (".mid", ".midi"))
    if args.limit:
        files = files[: args.limit]

    stats: dict[str, int] = {}
    kept = 0
    for i, f in enumerate(files):
        res = clean_one(f, dst / f"{args.genre}_{i:05d}.mid")
        key = "ok" if res == "ok" else res.split(":")[0]
        stats[key] = stats.get(key, 0) + 1
        kept += res == "ok"

    with (args.out / "genres.csv").open("w", newline="") as fh:
        csv.writer(fh).writerow([f"/{args.genre}/", args.genre])
    print(f"Siivottu {kept}/{len(files)} -> {dst}")
    print("Erittely:", dict(sorted(stats.items(), key=lambda x: -x[1])))


if __name__ == "__main__":
    main()
