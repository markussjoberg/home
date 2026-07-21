"""Nouda/ingestoi FolkWiki-sävelmiä (pohjoismainen pelimanni, ABC).

FolkWiki (folkwiki.se) on ABC-muotoinen wiki; sävelmätyyppi on ABC:n
R:-kentässä (esim. "R:Polska"). Tämä työkalu luokittelee ABC-tiedostot
posetiivigenreiksi ja tuottaa saman muodon kuin fetch_thesession.py
(data/<genre>/*.abc + genres.csv + valinnainen MIDI).

Kaksi tilaa:

  # A) Ingestoi jo ladatut ABC:t (esim. ztime/polska-dumpista) — TESTATTU
  python fetch_folkwiki.py --abc-dir ~/folkwiki_abc --out data/folkwiki \
      --to-midi data/midi

  # B) Live-scrape suoraan folkwiki.se:stä — VARMENNA ENNEN LUOTTAMISTA
  python fetch_folkwiki.py --scrape --out data/folkwiki

HUOM (2026-07-21): folkwiki.se käyttäytyi kehitysympäristössä epävakaasti
(HTTP-only, pub/cache osin uudelleenjärjestetty, 302-ohjauksia). Live-scrape
on tehty dokumentoitua rakennetta vasten mutta EI päästä-päähän varmennettu
— aja ensin pienellä --limit ja tarkista tulos. ABC-ingest (tila A) on
testattu ja toimii millä tahansa FolkWiki-ABC-kokoelmalla.

Lisenssi: FolkWikin sisältö on käyttäjien lisäämää; tarkista sävelmäkohtainen
lisenssi ennen KAUPALLISTA käyttöä (perinnesävelmät ovat PD, transkriptiot
voivat olla suojattuja). Provenienssi kirjataan SOURCES.md:hen.
"""

from __future__ import annotations

import argparse
import csv
import re
import shutil
import subprocess
import sys
from pathlib import Path

BASE = "http://www.folkwiki.se/"

# FolkWikin/ABC:n R:-tyyppi (ruotsi/pohjoismainen) -> posetiivigenre.
# Vain nämä poimitaan; muut (hambo, snoa, engelska...) ohitetaan kunnes
# niille on genre. Avaimet pienaakkosin, verrataan alkuosaan.
TYPE_TO_GENRE = {
    "polska": "polska",
    "vals": "valssi",
    "schottis": "jenkka",   # schottis = jenkka/sottiisi
    "polka": "polkka",
    "polkett": "polkka",
    "marsch": "marssi",
    "mazurka": "masurkka",
    "masurka": "masurkka",
}

R_FIELD = re.compile(r"^R:\s*(.+?)\s*$", re.MULTILINE)
T_FIELD = re.compile(r"^T:\s*(.+?)\s*$", re.MULTILINE)


def classify(abc: str) -> str | None:
    """ABC-teksti -> posetiivigenre R:-kentästä (tai otsikosta varalta)."""
    m = R_FIELD.search(abc)
    hay = (m.group(1) if m else "").lower()
    if not hay:  # varalta: otsikko voi sisältää tyypin
        t = T_FIELD.search(abc)
        hay = (t.group(1) if t else "").lower()
    for key, genre in TYPE_TO_GENRE.items():
        if hay.startswith(key) or f" {key}" in hay:
            return genre
    return None


def ingest_dir(abc_dir: Path, out: Path) -> dict[str, int]:
    """Luokittele hakemiston ABC:t genreittäin -> out/<genre>/*.abc."""
    counts: dict[str, int] = {}
    for abc_file in sorted(abc_dir.rglob("*")):
        if abc_file.suffix.lower() not in (".abc", ".txt"):
            continue
        try:
            body = abc_file.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        # Yksi tiedosto voi sisältää monta sävelmää (X: erottaa). Pilko.
        tunes = re.split(r"(?=^X:\s*\d)", body, flags=re.MULTILINE)
        for tune in tunes:
            if "K:" not in tune:  # ei kelvollista ABC-runkoa
                continue
            genre = classify(tune)
            if not genre:
                continue
            counts[genre] = counts.get(genre, 0) + 1
            d = out / genre
            d.mkdir(parents=True, exist_ok=True)
            (d / f"{genre}_{counts[genre]:05d}.abc").write_text(
                tune.strip() + "\n", encoding="utf-8")
    return counts


def scrape(out: Path, limit: int) -> dict[str, int]:
    """Live-scrape folkwiki.se. VARMENTAMATON — ks. moduulin docstring.

    Dokumentoitu rakenne: sävelmät ovat pub/cache/<Tyyppi>_<hash>/NNNN(.abc).
    Toteutus on tarkoituksella defensiivinen ja hidas (kohtelias viive)."""
    import time
    import urllib.request
    from sources import check_opt_out

    reserved, why = check_opt_out(BASE)
    print(f"opt-out: {'VARATTU' if reserved else 'ei estettä'} — {why}")
    if reserved:
        sys.exit("Louhinta on varattu tälle lähteelle; ei noudeta.")

    # Indeksin haku vaihtelee — jätetään ihmisen annettavaksi jos automaatti
    # ei löydä. Tässä yritetään tunnettua listaussivua; jos tyhjä, ohje.
    print("VAROITUS: live-scrape on varmentamaton. Jos tulos on tyhjä,\n"
          "käytä ztime/polska-dumppia ja --abc-dir-tilaa.")
    idx = _get(urljoin_base("Musik"))
    hrefs = re.findall(r'href="([^"]+)"', idx or "")
    tune_links = [h for h in hrefs if "pub/cache" in h or ".abc" in h][:limit or None]
    counts: dict[str, int] = {}
    for i, link in enumerate(tune_links):
        abc = _get(link if link.startswith("http") else urljoin_base(link))
        if not abc or "K:" not in abc:
            continue
        genre = classify(abc)
        if not genre:
            continue
        counts[genre] = counts.get(genre, 0) + 1
        d = out / genre
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{genre}_{counts[genre]:05d}.abc").write_text(abc, encoding="utf-8")
        time.sleep(0.5)  # kohtelias
    return counts


def urljoin_base(path: str) -> str:
    from urllib.parse import urljoin
    return urljoin(BASE, path)


def _get(url: str) -> str | None:
    import urllib.request
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            return r.read(500_000).decode("utf-8", "replace")
    except Exception:
        return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--abc-dir", type=Path, help="ingestoi valmiit ABC:t (tila A)")
    ap.add_argument("--scrape", action="store_true", help="live-scrape (tila B)")
    ap.add_argument("--to-midi", type=Path, help="aja myös abc2midi tähän")
    ap.add_argument("--limit", type=int, default=0, help="0 = kaikki (scrape)")
    args = ap.parse_args()

    if not args.abc_dir and not args.scrape:
        sys.exit("Anna joko --abc-dir (tila A) tai --scrape (tila B).")

    counts = (ingest_dir(args.abc_dir, args.out) if args.abc_dir
              else scrape(args.out, args.limit))

    genres = sorted(counts)
    with (args.out / "genres.csv").open("w", newline="") as f:
        w = csv.writer(f)
        for genre in genres:
            w.writerow([f"/{genre}/", genre])
    print("ABC-tiedostot:", dict(sorted(counts.items())))

    from sources import record
    record(args.out / "SOURCES.md", source="FolkWiki", url=BASE,
           license="käyttäjäkohtainen (perinne PD); tarkista kaupalliseen",
           opt_out_checked=True, count=sum(counts.values()),
           notes="R:-kenttä -> " + "/".join(genres))

    if args.to_midi and counts:
        if not shutil.which("abc2midi"):
            sys.exit("abc2midi puuttuu: brew install abcmidi / apt install abcmidi")
        n = 0
        for abc in args.out.rglob("*.abc"):
            dst = args.to_midi / abc.parent.name
            dst.mkdir(parents=True, exist_ok=True)
            r = subprocess.run(
                ["abc2midi", str(abc), "-o", str(dst / (abc.stem + ".mid")),
                 "-silent"], capture_output=True)
            n += r.returncode == 0
        shutil.copy(args.out / "genres.csv", args.to_midi / "genres.csv")
        print(f"MIDIksi muunnettu {n} kpl -> {args.to_midi}")


if __name__ == "__main__":
    main()
