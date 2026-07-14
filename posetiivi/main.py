"""Posetiivin pääohjelma: kytkee kammen, Lyrian ja äänentoiston yhteen."""

from __future__ import annotations

import argparse
import asyncio
import sys

from . import config as config_mod
from .audio import Player
from .crank import CrankSpeed, run_crank, run_mock_crank
from .lyria import LyriaSession

CONTROL_INTERVAL = 0.1  # s: kuinka usein kammen tila luetaan ja mapataan


async def control_loop(speed: CrankSpeed, lyria: LyriaSession, player: Player) -> None:
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


async def run(cfg: config_mod.Config, mock: bool) -> None:
    speed = CrankSpeed(cfg.crank)
    player = Player(cfg.audio, cfg.mapping)
    lyria = LyriaSession(cfg.lyria, on_audio=player.feed)

    player.start()
    crank_task = run_mock_crank(speed) if mock else run_crank(speed)
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(lyria.run())
            tg.create_task(crank_task)
            tg.create_task(control_loop(speed, lyria, player))
    finally:
        player.stop()


def cli() -> None:
    parser = argparse.ArgumentParser(description="Digitaalinen Lyria-posetiivi")
    parser.add_argument("--config", default="config.toml", help="polku config.tomliin")
    parser.add_argument("--mock", action="store_true", help="simuloitu kampi (ei rautaa)")
    parser.add_argument(
        "--list-devices", action="store_true", help="listaa input-laitteet ja lopeta"
    )
    args = parser.parse_args()

    if args.list_devices:
        from .crank import list_devices

        list_devices()
        return

    cfg = config_mod.load(args.config)
    try:
        asyncio.run(run(cfg, mock=args.mock))
    except KeyboardInterrupt:
        print("\nPosetiivi sammutettu.")
        sys.exit(0)


if __name__ == "__main__":
    cli()
