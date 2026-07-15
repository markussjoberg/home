"""Lokaali MIDI-koneisto: kampi pyörittää kelloa, säveltäjä täyttää rullaa.

Kello etenee iskuina vain kun kampea veivataan — tempo seuraa
veivausnopeutta välittömästi, kuten mekaanisessa posetiivissa. Suuntaa
ohjataan soiton aikana näppäimillä (LiveParams): sävellaji, duuri/molli,
temperature, rekisteri ja soundi.

Näppäimet:
  m        duuri/molli
  k / K    sävellaji kvinttiympyrää eteen/taakse
  t / T    temperature alas/ylös
  r / R    rekisteri alas/ylös
  p        vaihda soundia
  ?        näytä tila
"""

from __future__ import annotations

import asyncio
import contextlib
import heapq
import sys
import time

from .config import Config
from .crank import CrankSpeed
from .midigen import LiveParams, WaltzComposer

TICK = 0.005  # s: kellon resoluutio


class MidiEngine:
    def __init__(self, cfg: Config, speed: CrankSpeed, synth):
        self.cfg = cfg
        self.speed = speed
        self.synth = synth
        self.params = LiveParams()
        self.composer = WaltzComposer(self.params)
        self._events: list[tuple[float, int, str, int, int]] = []  # heap
        self._seq = 0
        self._composed_until = 0.0  # iskuina
        self._silenced = True

    def _push(self, beat: float, kind: str, channel: int, pitch: int, vel: int = 0):
        heapq.heappush(self._events, (beat, self._seq, kind, channel, pitch, vel))
        self._seq += 1

    def _compose_ahead(self, clock: float, density: float) -> None:
        """Pidä vähintään tahti sävellettyä materiaalia kellon edellä."""
        while self._composed_until < clock + WaltzComposer.BEATS_PER_BAR:
            bar_start = self._composed_until
            for n in self.composer.next_bar(density):
                self._push(bar_start + n.beat, "on", n.channel, n.pitch, n.velocity)
                self._push(bar_start + n.beat + n.duration, "off", n.channel, n.pitch)
            self._composed_until = bar_start + WaltzComposer.BEATS_PER_BAR

    async def run(self) -> None:
        m = self.cfg.mapping
        midi = self.cfg.midi
        self.synth.set_programs(self.params.program, midi.accomp_program)
        print(f"MIDI-koneisto: {self.params.describe()}")

        clock = 0.0  # iskuina
        prev_program = self.params.program
        last_wall = time.monotonic()
        stopped_since: float | None = None

        while True:
            await asyncio.sleep(TICK)
            now = time.monotonic()
            dt, last_wall = now - last_wall, now
            s = self.speed.normalized

            if self.params.program != prev_program:
                prev_program = self.params.program
                self.synth.set_programs(prev_program, midi.accomp_program)

            if s <= 0.0:
                # Kampi seis: kello jäätyy, nuotit vaiennetaan pienen
                # viiveen jälkeen (palkeet tyhjenevät).
                if stopped_since is None:
                    stopped_since = now
                elif not self._silenced and now - stopped_since > 0.15:
                    self.synth.all_notes_off()
                    self._silenced = True
                continue
            stopped_since, self._silenced = None, False

            bpm = midi.tempo_min_bpm + s * (midi.tempo_max_bpm - midi.tempo_min_bpm)
            clock += dt * bpm / 60.0
            density = m.density_min + s * (m.density_max - m.density_min)
            self._compose_ahead(clock, density)

            while self._events and self._events[0][0] <= clock:
                _, _, kind, channel, pitch, vel = heapq.heappop(self._events)
                if kind == "on":
                    self.synth.note_on(channel, pitch, vel)
                else:
                    self.synth.note_off(channel, pitch)


async def run_keyboard(params: LiveParams) -> None:
    """Lue ohjausnäppäimiä stdinistä (yksi merkki kerrallaan, ilman enteriä)."""
    if not sys.stdin.isatty():
        return  # esim. systemd-ajossa ei ohjausnäppäimiä
    import termios
    import tty

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[str] = asyncio.Queue()
    loop.add_reader(fd, lambda: queue.put_nowait(sys.stdin.read(1)))
    print("Ohjaus: [m]olli/duuri [k/K]sävellaji [t/T]temp [r/R]rekisteri [p]soundi")
    try:
        while True:
            ch = await queue.get()
            if ch == "m":
                params.minor = not params.minor
            elif ch == "k":
                params.key = (params.key + 7) % 12
            elif ch == "K":
                params.key = (params.key + 5) % 12
            elif ch == "t":
                params.temperature = max(0.0, round(params.temperature - 0.1, 1))
            elif ch == "T":
                params.temperature = min(1.0, round(params.temperature + 0.1, 1))
            elif ch == "r":
                params.register = max(-1, params.register - 1)
            elif ch == "R":
                params.register = min(2, params.register + 1)
            elif ch == "p":
                params.program_ix += 1
            elif ch != "?":
                continue
            print(f"  -> {params.describe()}")
    finally:
        loop.remove_reader(fd)
        with contextlib.suppress(Exception):
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
