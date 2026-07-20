"""Posetiivin pääohjelma: kytkee kammen, Lyrian ja äänentoiston yhteen."""

from __future__ import annotations

import argparse
import asyncio
import sys

from . import config as config_mod
from .crank import CrankSpeed, run_crank, run_mock_crank

CONTROL_INTERVAL = 0.1  # s: kuinka usein kammen tila luetaan ja mapataan


async def control_loop(speed: CrankSpeed, lyria, player) -> None:
    """Mappaa veivausnopeus musiikkiin: play/pause, feidi, density/brightness."""
    m = player.map
    idle_since = 0.0
    while True:
        s = speed.normalized
        if s > 0.0:
            idle_since = 0.0
            player.target_gain = 1.0
            player.rate = m.varispeed_min_rate + s * (
                m.varispeed_max_rate - m.varispeed_min_rate
            )
            await lyria.play()
            await lyria.set_feel(
                density=m.density_min + s * (m.density_max - m.density_min),
                brightness=m.brightness_min + s * (m.brightness_max - m.brightness_min),
            )
        else:
            player.target_gain = 0.0
            # Pausetetaan striimi vasta feidin jälkeen + pieni marginaali,
            # jotta lyhyt veivaustauko ei katkaise generointia.
            idle_since += CONTROL_INTERVAL
            if idle_since > player.cfg.fade_sec + 2.0:
                await lyria.pause()
        await asyncio.sleep(CONTROL_INTERVAL)


async def run_lyria(cfg: config_mod.Config, speed: CrankSpeed, crank_task) -> None:
    from .audio import Player
    from .lyria import LyriaSession

    player = Player(cfg.audio, cfg.mapping)
    lyria = LyriaSession(cfg.lyria, on_audio=player.feed)
    player.start()
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(lyria.run())
            tg.create_task(crank_task)
            tg.create_task(control_loop(speed, lyria, player))
    finally:
        player.stop()


async def run_midi(cfg: config_mod.Config, speed: CrankSpeed, crank_task,
                   null_synth: bool, ui: bool = False) -> None:
    from .midi_engine import MidiEngine, run_keyboard
    from .synth import NullSynth, Synth

    synth = NullSynth() if null_synth else Synth(cfg.midi)
    engine = MidiEngine(cfg, speed, synth)
    if cfg.midi.source == "llm":
        from .llm_source import LLMComposer

        engine.composer = LLMComposer(cfg.midi.llm_checkpoint, engine.params)
        print(f"Melodialähde: LLM ({cfg.midi.llm_checkpoint})")
    if ui:
        from .webui import WebUI

        WebUI(speed, engine.params, synth).start()
    async with asyncio.TaskGroup() as tg:
        tg.create_task(engine.run())
        tg.create_task(crank_task)
        tg.create_task(run_keyboard(engine.params))


async def _idle_crank() -> None:
    """Veivi tulee webUI:sta HTTP:n yli — pidetään vain taski hengissä."""
    while True:
        await asyncio.sleep(3600)


async def run(cfg: config_mod.Config, engine: str, mock: bool, null_synth: bool,
              ui: bool = False) -> None:
    speed = CrankSpeed(cfg.crank)
    if mock:
        crank_task = run_mock_crank(speed)
    elif ui:
        crank_task = _idle_crank()
    elif sys.platform == "darwin":
        from .crank import run_pynput_crank

        crank_task = run_pynput_crank(speed)
    else:
        crank_task = run_crank(speed)
    if engine == "lyria":
        await run_lyria(cfg, speed, crank_task)
    else:
        await run_midi(cfg, speed, crank_task, null_synth, ui=ui)


def cli() -> None:
    parser = argparse.ArgumentParser(description="Digitaalinen posetiivi")
    parser.add_argument("--config", default="config.toml", help="polku config.tomliin")
    parser.add_argument(
        "--engine", choices=("midi", "lyria"), help="ohita configin engine-valinta"
    )
    parser.add_argument("--ui", action="store_true",
                        help="selainsimulaattori: scrollaus veivinä, liu'ut vipuina")
    parser.add_argument("--mock", action="store_true", help="simuloitu kampi (ei rautaa)")
    parser.add_argument(
        "--null-synth", action="store_true", help="MIDI-koneisto ilman ääntä (testaus)"
    )
    parser.add_argument(
        "--list-devices", action="store_true", help="listaa input-laitteet ja lopeta"
    )
    args = parser.parse_args()

    if args.list_devices:
        from .crank import list_devices

        list_devices()
        return

    cfg = config_mod.load(args.config)
    engine = args.engine or cfg.engine
    try:
        asyncio.run(run(cfg, engine, mock=args.mock, null_synth=args.null_synth,
                        ui=args.ui))
    except KeyboardInterrupt:
        print("\nPosetiivi sammutettu.")
        sys.exit(0)


if __name__ == "__main__":
    cli()
