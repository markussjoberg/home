"""Datahygienia: provenienssimanifesti + opt-out-tarkistus.

Jokainen fetch_*.py kutsuu näitä ennen noutoa ja sen jälkeen — kevyt,
alan käytännön mukainen kirjanpito (ks. docs/V5.md).

    from sources import check_opt_out, record
    reserved, why = check_opt_out("http://www.folkwiki.se/")
    if reserved: sys.exit(f"Louhinta varattu: {why}")
    ... nouda ...
    record(out/"..."/"SOURCES.md", source="FolkWiki", url=..., license="?",
           opt_out_checked=True, count=n)
"""

from __future__ import annotations

import datetime
import json
import urllib.request
from pathlib import Path
from urllib.parse import urljoin


def _get(url: str, timeout: int = 15) -> str | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.read(200_000).decode("utf-8", "replace")
    except Exception:
        return None


def check_opt_out(base_url: str) -> tuple[bool, str]:
    """(varattu?, selite). Tarkistaa TDM-varauksen (tdmrep.json), ai.txt:n ja
    robots.txt:n. Konservatiivinen: verkkovirhe EI tulkita varaukseksi
    (palautetaan (False, 'ei-tavoitettu') jotta nouto ei jää jumiin), mutta
    se kirjataan selitteeseen jotta ihminen näkee ettei tarkistus onnistunut.
    """
    # 1) TDM Reservations Protocol: /.well-known/tdmrep.json
    tdm = _get(urljoin(base_url, "/.well-known/tdmrep.json"))
    if tdm:
        try:
            data = json.loads(tdm)
            entries = data if isinstance(data, list) else [data]
            if any(str(e.get("tdm-reservation", 0)) == "1" for e in entries):
                return True, "tdmrep.json: tdm-reservation=1"
        except Exception:
            pass
    # 2) ai.txt (de facto): kokonaiskielto
    ai = _get(urljoin(base_url, "/ai.txt"))
    if ai and "disallow: /" in ai.lower():
        return True, "ai.txt: Disallow /"
    # 3) robots.txt: kokonaiskielto User-agent: * tai AI-boteille
    robots = _get(urljoin(base_url, "/robots.txt"))
    if robots:
        ua, blocked = None, False
        ai_bots = ("gptbot", "ccbot", "google-extended", "claudebot",
                   "anthropic-ai", "cohere-ai")
        for line in robots.splitlines():
            line = line.strip().lower()
            if line.startswith("user-agent:"):
                ua = line.split(":", 1)[1].strip()
            elif line.startswith("disallow:") and ua:
                path = line.split(":", 1)[1].strip()
                if path == "/" and (ua == "*" or ua in ai_bots):
                    blocked = True
        if blocked:
            return True, "robots.txt: Disallow / (* tai AI-botti)"
        return False, "robots.txt tarkistettu, ei varausta"
    return False, "ei robots/tdm-tiedostoa (ei estettä)"


_HEADER = ("| Lähde | URL | Lisenssi | Haettu | Opt-out | Kpl | Huom |\n"
           "|---|---|---|---|---|---|---|\n")


def record(sources_md: Path, *, source: str, url: str, license: str,
           opt_out_checked: bool, count: int, notes: str = "") -> None:
    """Liitä/päivitä rivi provenienssimanifestiin (yksi rivi per lähde)."""
    sources_md.parent.mkdir(parents=True, exist_ok=True)
    date = datetime.date.today().isoformat()
    oo = "kyllä" if opt_out_checked else "EI"
    row = (f"| {source} | {url} | {license} | {date} | {oo} | {count} | "
           f"{notes} |\n")
    existing = ""
    if sources_md.exists():
        existing = sources_md.read_text(encoding="utf-8")
    # Aloita otsikolla + taulun päällä jos manifestia ei vielä ole.
    if "| Lähde |" not in existing:
        existing = "# Datalähteet (provenienssi)\n\n" + _HEADER
    # Poista saman lähteen aiempi rivi (idempotentti päivitys), säilytä muut.
    kept = [ln for ln in existing.splitlines(keepends=True)
            if not ln.startswith(f"| {source} |")]
    text = "".join(kept)
    if not text.endswith("\n"):
        text += "\n"
    sources_md.write_text(text + row, encoding="utf-8")
