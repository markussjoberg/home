"""config.toml:n lataus dataclasseiksi."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class PromptCfg:
    text: str
    weight: float = 1.0


@dataclass
class LyriaCfg:
    model: str = "models/lyria-realtime-exp"
    prompts: list[PromptCfg] = field(
        default_factory=lambda: [PromptCfg("street organ waltz")]
    )
    bpm: int | None = 110
    scale: str = ""
    temperature: float = 1.1
    guidance: float = 4.0


@dataclass
class MidiCfg:
    soundfont: str = "/usr/share/sounds/sf2/FluidR3_GM.sf2"
    accomp_program: int = 21  # GM-soundi säestykselle (21 = harmonikka)
    audio_driver: str = ""  # tyhjä = automaattinen (alsa / coreaudio)
    tempo_min_bpm: float = 50.0
    tempo_max_bpm: float = 170.0
    source: str = "algo"  # "algo" = WaltzComposer, "llm" = treenattu malli
    llm_checkpoint: str = "training/ckpt/best.pt"


@dataclass
class CrankCfg:
    device: str = ""
    full_speed_ticks_per_sec: float = 30.0
    stop_timeout_sec: float = 0.35


@dataclass
class MappingCfg:
    density_min: float = 0.2
    density_max: float = 0.9
    brightness_min: float = 0.3
    brightness_max: float = 0.8
    varispeed: bool = False
    varispeed_min_rate: float = 0.6
    varispeed_max_rate: float = 1.15


@dataclass
class AudioCfg:
    output_device: str = ""
    fade_sec: float = 0.6
    prebuffer_sec: float = 1.5


@dataclass
class Config:
    engine: str = "midi"  # "midi" (lokaali) tai "lyria" (pilvi)
    lyria: LyriaCfg = field(default_factory=LyriaCfg)
    midi: MidiCfg = field(default_factory=MidiCfg)
    crank: CrankCfg = field(default_factory=CrankCfg)
    mapping: MappingCfg = field(default_factory=MappingCfg)
    audio: AudioCfg = field(default_factory=AudioCfg)


def load(path: str | Path = "config.toml") -> Config:
    path = Path(path)
    if not path.exists():
        return Config()
    raw = tomllib.loads(path.read_text())

    lyria_raw = raw.get("lyria", {})
    gen = lyria_raw.get("generation", {})
    lyria = LyriaCfg(
        model=lyria_raw.get("model", LyriaCfg.model),
        prompts=[
            PromptCfg(p["text"], float(p.get("weight", 1.0)))
            for p in lyria_raw.get("prompts", [])
        ]
        or LyriaCfg().prompts,
        bpm=gen.get("bpm"),
        scale=gen.get("scale", ""),
        temperature=float(gen.get("temperature", 1.1)),
        guidance=float(gen.get("guidance", 4.0)),
    )
    crank = CrankCfg(**raw.get("crank", {}))
    mapping = MappingCfg(**raw.get("mapping", {}))
    audio = AudioCfg(**raw.get("audio", {}))
    midi = MidiCfg(**raw.get("midi", {}))
    return Config(
        engine=raw.get("engine", "midi"),
        lyria=lyria,
        midi=midi,
        crank=crank,
        mapping=mapping,
        audio=audio,
    )
