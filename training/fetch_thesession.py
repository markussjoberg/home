"""Nouda The Session -datadumppi ja suodata posetiivigenret ABC-tiedostoiksi.

    python fetch_thesession.py --out data/abc
    # sitten (brew install abcmidi / apt install abcmidi):
    python fetch_thesession.py --out data/abc --to-midi data/midi

Tuloksena data/abc/<genre>/*.abc ja genres.csv valmiina prepare_data.py:lle.
Lähde: github.com/adactio/TheSession-data (julkinen dumppi, ODbL).
"""

from __future__ import annotations

import argparse
import csv
import io
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

URL = "https://raw.githubusercontent.com/adactio/TheSession-data/main/csv/tunes.csv"

# The Sessionin tune type -> posetiivigenre. Muut tyypit ohitetaan.
TYPE_TO_GENRE = {
    "waltz": "valssi",
    "polka": "polkka",
    "mazurka": "masurkka",
    "march": "marssi",
}


def fetch(out: Path) -> Path:
    cache = out / "tunes.csv"
    if not cache.exists():
        print(f"Ladataan {URL} ...")
        out.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(URL, timeout=120) as r:
            cache.write_bytes(r.read())
    return cache


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--to-midi", type=Path, help="aja myös abc2midi tähän hakemistoon")
    ap.add_argument("--max-per-genre", type=int, default=0, help="0 = kaikki")
    args = ap.parse_args()

    csv.field_size_limit(10_000_000)
    counts: dict[str, int] = {}
    with fetch(args.out).open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            genre = TYPE_TO_GENRE.get(row.get("type", "").strip().lower())
            abc_body = row.get("abc", "").strip()
            if not genre or not abc_body:
                continue
            if args.max_per_genre and counts.get(genre, 0) >= args.max_per_genre:
                continue
            counts[genre] = counts.get(genre, 0) + 1
            d = args.out / genre
            d.mkdir(parents=True, exist_ok=True)
            tune_id = row.get("tune_id", str(counts[genre]))
            setting = row.get("setting_id", "0")
            meter = row.get("meter", "").strip() or "3/4"
            key = row.get("mode", "").strip() or "C"
            abc = (f"X:1\nT:tune {tune_id}\nM:{meter}\nL:1/8\nK:{key}\n{abc_body}\n")
            (d / f"{tune_id}_{setting}.abc").write_text(abc, encoding="utf-8")

    with (args.out / "genres.csv").open("w", newline="") as f:
        w = csv.writer(f)
        for genre in sorted(set(TYPE_TO_GENRE.values())):
            w.writerow([f"/{genre}/", genre])
    print("ABC-tiedostot:", dict(sorted(counts.items())))

    if args.to_midi:
        if not shutil.which("abc2midi"):
            sys.exit("abc2midi puuttuu: brew install abcmidi / sudo apt install abcmidi")
        n = 0
        for abc in args.out.rglob("*.abc"):
            dst = args.to_midi / abc.parent.name
            dst.mkdir(parents=True, exist_ok=True)
            r = subprocess.run(
                ["abc2midi", str(abc), "-o", str(dst / (abc.stem + ".mid")),
                 "-silent"],
                capture_output=True,
            )
            n += r.returncode == 0
        shutil.copy(args.out / "genres.csv", args.to_midi / "genres.csv")
        print(f"MIDIksi muunnettu {n} kpl -> {args.to_midi}")


if __name__ == "__main__":
    main()
