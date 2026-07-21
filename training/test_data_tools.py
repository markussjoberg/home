"""Datankeräystyökalujen testit (clean_midi, fetch_folkwiki, sources).

Ajo ilman pytestiä:  python training/test_data_tools.py
pytest-yhteensopiva:  pytest training/test_data_tools.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import clean_midi as cm
import fetch_folkwiki as fw
import sources


def test_beats_per_bar_supported():
    assert cm._beats_per_bar(2, 4) == 2
    assert cm._beats_per_bar(3, 4) == 3
    assert cm._beats_per_bar(4, 4) == 4
    assert cm._beats_per_bar(5, 4) is None  # tukematon -> hylätään


def test_folkwiki_classify():
    assert fw.classify("X:1\nR:Polska\nK:D\n") == "polska"
    assert fw.classify("X:1\nR:Vals\nK:G\n") == "valssi"
    assert fw.classify("X:1\nR:Schottis\nK:A\n") == "jenkka"
    assert fw.classify("X:1\nR:Polka\nK:C\n") == "polkka"
    assert fw.classify("X:1\nR:Marsch\nK:D\n") == "marssi"
    assert fw.classify("X:1\nR:Hambo\nK:D\n") is None      # ei genressä
    assert fw.classify("X:1\nT:Ingen typ\nK:D\n") is None  # ei R-kenttää


def test_skyline_monophonic():
    class N:
        def __init__(self, time, dur, pitch):
            self.time, self.duration, self.pitch, self.velocity = time, dur, pitch, 80
    # Kolme päällekkäistä sointusäveltä + yksi myöhempi -> skyline pitää ylimmät
    notes = [N(0, 480, 60), N(0, 480, 64), N(0, 480, 67), N(480, 480, 72)]
    top = cm._skyline(notes)
    assert len(top) == 2                    # yksi per alkuhetki
    assert top[0].pitch == 67               # ylin soinnusta
    assert cm._monophonicity(top) == 1.0


def test_sources_idempotent(tmp_path=None):
    p = Path(tmp_path or "/tmp") / "SOURCES_pytest.md"
    p.unlink(missing_ok=True)
    for _ in range(3):  # sama lähde kolmesti
        sources.record(p, source="X", url="u", license="L",
                       opt_out_checked=True, count=5)
    sources.record(p, source="Y", url="u2", license="L2",
                   opt_out_checked=False, count=1)
    rows = [ln for ln in p.read_text().splitlines() if ln.startswith("| X |")]
    assert len(rows) == 1                   # idempotentti: ei duplikaattia
    assert "| Y |" in p.read_text()         # eri lähde säilyy
    p.unlink(missing_ok=True)


def _run():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    for t in tests:
        try:
            t()
            print(f"  PASS {t.__name__}")
            passed += 1
        except AssertionError as e:
            print(f"  FAIL {t.__name__}: {e}")
        except Exception as e:
            print(f"  ERROR {t.__name__}: {type(e).__name__}: {e}")
    print(f"{passed}/{len(tests)} läpi")
    return passed == len(tests)


if __name__ == "__main__":
    sys.exit(0 if _run() else 1)
