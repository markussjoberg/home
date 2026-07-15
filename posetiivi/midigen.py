"""Generatiivinen säveltäjä: loputon posetiivivalssi.

Säveltää tahdin kerrallaan (3/4). Ei neuroverkkoa — painotettu satunnaisuus
sointukulkujen Markov-ketjulla ja melodialla joka suosii sointusäveliä ja
pieniä askelia. Kaikki parametrit ovat säädettävissä kesken soiton:
uusi arvo vaikuttaa seuraavasta tahdista alkaen.
"""

from __future__ import annotations

import random
from dataclasses import dataclass

MAJOR = [0, 2, 4, 5, 7, 9, 11]
MINOR = [0, 2, 3, 5, 7, 8, 10]

# Sointukulku-Markov asteittain (0=I, 1=ii, ... 5=vi). Posetiivimainen:
# vahva paluu toonikalle, dominantti purkautuu aina.
CHORD_NEXT: dict[int, list[tuple[int, float]]] = {
    0: [(3, 3), (4, 3), (5, 2), (1, 1), (0, 1)],
    1: [(4, 4), (3, 1)],
    3: [(4, 3), (0, 2), (1, 1)],
    4: [(0, 5), (5, 1)],
    5: [(1, 2), (3, 2), (4, 1)],
}

KEY_NAMES = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

# GM-soundeja jotka sopivat posetiiviin: harmonikka, kirkkourut, harmoni,
# celesta, soittorasia(kellopeli), piano.
PROGRAMS = [21, 19, 20, 8, 10, 0]
PROGRAM_NAMES = {21: "harmonikka", 19: "kirkkourut", 20: "harmoni",
                 8: "celesta", 10: "soittorasia", 0: "piano"}


@dataclass
class LiveParams:
    """Soiton aikana säädettävät parametrit (näppäimistö/GPIO)."""

    key: int = 0  # 0 = C
    minor: bool = False
    temperature: float = 0.4  # 0..1: kuinka kauas sointusävelistä uskalletaan
    register: int = 0  # melodian oktaavisiirto -1..+2
    program_ix: int = 0  # indeksi PROGRAMS-listaan

    @property
    def program(self) -> int:
        return PROGRAMS[self.program_ix % len(PROGRAMS)]

    def describe(self) -> str:
        laji = "molli" if self.minor else "duuri"
        return (
            f"{KEY_NAMES[self.key % 12]}-{laji}  temp={self.temperature:.1f}  "
            f"rekisteri={self.register:+d}  soundi={PROGRAM_NAMES[self.program]}"
        )


@dataclass
class Note:
    beat: float  # aika tahdin alusta iskuina
    pitch: int
    velocity: int
    duration: float  # iskuina
    channel: int  # 0 = melodia, 1 = säestys


class WaltzComposer:
    """Tuottaa tahdin (3 iskua) kerrallaan Note-listoja."""

    BEATS_PER_BAR = 3

    def __init__(self, params: LiveParams, seed: int | None = None):
        self.params = params
        self.rng = random.Random(seed)
        self.degree = 0  # nykyinen sointuaste
        self.prev_pitch: int | None = None
        self.bars_on_degree = 0

    # --- musiikkiteoria-apurit -------------------------------------------

    def _scale(self) -> list[int]:
        return MINOR if self.params.minor else MAJOR

    def _chord_pitch_classes(self) -> list[int]:
        scale = self._scale()
        d = self.degree
        return [
            (self.params.key + scale[(d + i) % 7] + 12 * ((d + i) // 7)) % 12
            for i in (0, 2, 4)
        ]

    def _nearest(self, pitch_class: int, around: int) -> int:
        """Sävelluokkaa vastaava MIDI-sävel mahdollisimman läheltä `around`."""
        base = around - (around - pitch_class) % 12
        return base if around - base <= 6 else base + 12

    # --- sävellys ---------------------------------------------------------

    def _advance_chord(self) -> None:
        self.bars_on_degree += 1
        # Vaihda sointua 1-2 tahdin välein.
        if self.bars_on_degree >= self.rng.choice((1, 1, 2)):
            options = CHORD_NEXT[self.degree]
            degrees, weights = zip(*options)
            self.degree = self.rng.choices(degrees, weights)[0]
            self.bars_on_degree = 0

    def _bass_and_chords(self) -> list[Note]:
        """Humppakomppi: basso ykkösellä, soinnut kakkosella ja kolmosella."""
        pcs = self._chord_pitch_classes()
        root = self._nearest(pcs[0], 45)  # basso A2:n tienoille
        notes = [Note(0.0, root, 92, 0.9, channel=1)]
        chord = [self._nearest(pc, 57) for pc in pcs]
        for beat in (1.0, 2.0):
            for p in chord:
                notes.append(Note(beat, p, 68, 0.7, channel=1))
        return notes

    def _melody_rhythm(self, density: float) -> list[tuple[float, float]]:
        """(alku, kesto) -parit iskuina. Density säätää tiheyttä."""
        out: list[tuple[float, float]] = []
        beat = 0.0
        while beat < self.BEATS_PER_BAR:
            r = self.rng.random()
            if r < density * 0.25 and beat + 0.5 <= self.BEATS_PER_BAR:
                out += [(beat, 0.25), (beat + 0.25, 0.25)]  # kaksi 16-osaa
                beat += 0.5
            elif r < density:
                out.append((beat, 0.5))  # kahdeksasosa
                beat += 0.5
            elif r < density + 0.35 or beat % 1.0:
                out.append((beat, 1.0 - beat % 1.0))  # täytä isku
                beat = float(int(beat) + 1)
            else:
                out.append((beat, 2.0 if beat == 0.0 else 1.0))  # pitkä sävel
                beat += out[-1][1]
        return out

    def _melody_pitch(self) -> int:
        p = self.params
        chord_pcs = self._chord_pitch_classes()
        scale_pcs = [(p.key + s) % 12 for s in self._scale()]
        # Temperature: matala = pysytään sointusävelissä, korkea = koko
        # asteikko ja isommat hypyt käyvät.
        pool = chord_pcs if self.rng.random() > p.temperature else scale_pcs
        center = 72 + 12 * p.register
        prev = self.prev_pitch or center
        candidates = []
        for pc in pool:
            near = self._nearest(pc, prev)
            for cand in (near - 12, near, near + 12):
                dist = abs(cand - prev) + abs(cand - center) * 0.3
                candidates.append((cand, 1.0 / (1.0 + dist ** (2 - p.temperature))))
        pitches, weights = zip(*candidates)
        pitch = self.rng.choices(pitches, weights)[0]
        self.prev_pitch = pitch
        return max(36, min(103, pitch))

    def next_bar(self, density: float) -> list[Note]:
        """Sävellä seuraava tahti. density 0..1 tulee kammen nopeudesta."""
        self._advance_chord()
        notes = self._bass_and_chords()
        for start, dur in self._melody_rhythm(density):
            vel = 88 if start == 0.0 else 76 + self.rng.randint(-6, 6)
            notes.append(Note(start, self._melody_pitch(), vel, dur * 0.92, channel=0))
        return notes
