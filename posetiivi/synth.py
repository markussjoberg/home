"""FluidSynth-äänipää MIDI-koneistolle.

Kanava 0 = melodia, kanava 1 = säestys (basso + soinnut).
"""

from __future__ import annotations

import sys

from .config import MidiCfg


class Synth:
    def __init__(self, cfg: MidiCfg):
        import fluidsynth  # pip: pyFluidSynth; apt: libfluidsynth3 / brew: fluid-synth

        self.fs = fluidsynth.Synth(samplerate=48000, gain=0.8)
        driver = cfg.audio_driver or (
            "coreaudio" if sys.platform == "darwin" else "alsa"
        )
        self.fs.start(driver=driver)
        self.sfid = self.fs.sfload(cfg.soundfont)
        if self.sfid < 0:
            raise RuntimeError(f"SoundFontin lataus epäonnistui: {cfg.soundfont}")

    def set_programs(self, melody: int, accomp: int) -> None:
        self.fs.program_select(0, self.sfid, 0, melody)
        self.fs.program_select(1, self.sfid, 0, accomp)

    def set_volume(self, channel: int, value: int) -> None:
        """MIDI CC7 -äänenvoimakkuus 0-127 (melodia/säestys-tasapaino)."""
        self.fs.cc(channel, 7, min(max(value, 0), 127))

    def note_on(self, channel: int, pitch: int, velocity: int) -> None:
        self.fs.noteon(channel, pitch, velocity)

    def note_off(self, channel: int, pitch: int) -> None:
        self.fs.noteoff(channel, pitch)

    def all_notes_off(self) -> None:
        for ch in (0, 1):
            self.fs.all_notes_off(ch)


class NullSynth:
    """Kehitykseen ilman ääntä/fluidsynthiä: tulostaa nuotit."""

    def set_programs(self, melody: int, accomp: int) -> None:
        print(f"[synth] programs melody={melody} accomp={accomp}")

    def set_volume(self, channel: int, value: int) -> None:
        print(f"[synth] vol ch{channel} = {value}")

    def note_on(self, channel: int, pitch: int, velocity: int) -> None:
        print(f"[synth] on  ch{channel} p{pitch} v{velocity}")

    def note_off(self, channel: int, pitch: int) -> None:
        pass

    def all_notes_off(self) -> None:
        print("[synth] all off")
